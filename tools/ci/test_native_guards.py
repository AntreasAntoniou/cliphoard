"""Pure tests: no Torch, CoreML, models, downloads or subprocesses."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import Mock

BASE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('minilm_validation', BASE / 'minilm_validation.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def multi(dtype=131104, shape=(1, 16), bounds=((1, 1), (2, 511))):
    return NS(WhichOneof=lambda _: 'multiArrayType', multiArrayType=NS(
        dataType=dtype, shape=list(shape), shapeRange=NS(sizeRanges=[NS(lowerBound=a, upperBound=b) for a,b in bounds])))


def model_spec():
    return NS(description=NS(input=[NS(name='input_ids', type=multi()), NS(name='attention_mask', type=multi())],
                            output=[NS(name='embedding', type=multi())]))


class NativeGuardTests(unittest.TestCase):
    def test_actual_converter_pin(self):
        self.assertEqual(hashlib.sha256((BASE.parent / 'convert_minilm.py').read_bytes()).hexdigest(), m.CONVERTER_SHA)
        source = (BASE / 'minilm_validation.py').read_text()
        self.assertIn('runpy.run_path(str(args.converter)', source)
        self.assertIn('ct.proto.FeatureTypes_pb2.ArrayFeatureType.INT32', source)
        self.assertNotIn('65568', source)

    def test_finite_parity_rejects_invalid_and_wrong_results(self):
        a = [1.0] + [0.0]*383
        self.assertAlmostEqual(m.compare(a, a)['cosine'], 1.0)
        for value in (a[:-1], [0.0]*384, [float('nan')]+a[1:], [float('inf')]+a[1:], [True]+a[1:]):
            with self.subTest(value=str(value[:1])):
                with self.assertRaises(ValueError): m.compare(a, value)
        with self.assertRaises(ValueError): m.compare(a, [-1.0]+a[1:])

    def test_spec_dtype_shape_ranges_and_names_independently(self):
        m.validate_spec(model_spec(), 131104)
        for mutation in ('dtype', 'shape', 'range', 'input', 'output'):
            s = model_spec()
            if mutation == 'dtype': s.description.input[0].type.multiArrayType.dataType = 65568
            if mutation == 'shape': s.description.input[0].type.multiArrayType.shape = [1, 6]
            if mutation == 'range': s.description.input[0].type.multiArrayType.shapeRange.sizeRanges[1].upperBound = 512
            if mutation == 'input': s.description.input[0].name = 'other'
            if mutation == 'output': s.description.output[0].name = 'other'
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError): m.validate_spec(s, 131104)

    def test_local_loader_forces_safe_offline_inputs(self):
        original = Mock(return_value='model')
        load = m.local_loader(original, Path('/approved/model'))
        self.assertEqual(load('sentence-transformers/all-MiniLM-L6-v2', device='cpu', model_kwargs={'attn_implementation':'eager'}), 'model')
        args, kwargs = original.call_args
        self.assertEqual(args, ('/approved/model',))
        self.assertIs(kwargs['token'], False)
        self.assertIs(kwargs['trust_remote_code'], False)
        self.assertIs(kwargs['local_files_only'], True)
        self.assertIs(kwargs['model_kwargs']['use_safetensors'], True)
        with self.assertRaises(ValueError): load('other', device='cpu', model_kwargs={'attn_implementation':'eager'})
        with self.assertRaises(ValueError): load('sentence-transformers/all-MiniLM-L6-v2', token='anything')

    def test_model_inventory_is_closed_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'model'; root.mkdir()
            for name in ['model.safetensors']+[f'config{i}.json' for i in range(9)]: (root/name).write_bytes(b'x')
            manifest = Path(tmp)/'manifest.json'
            manifest.write_text(json.dumps({'files':m.inventory(root)}))
            m.validate_model(root, manifest)
            extra=root/'unapproved.py';extra.write_bytes(b'x')
            with self.assertRaises(ValueError): m.validate_model(root, manifest)
            extra.unlink(); (root/'config0.json').write_bytes(b'y')
            with self.assertRaises(ValueError): m.validate_model(root, manifest)
            (root/'config0.json').unlink(); (root/'config0.json').symlink_to(manifest)
            with self.assertRaises(ValueError): m.validate_model(root, manifest)

    def test_receipts_are_exclusive(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'receipt.json';m.save(p, {'saved':True})
            with self.assertRaises(FileExistsError):m.save(p, {'saved':False})
            self.assertTrue(json.loads(p.read_text())['saved'])

    def test_python_network_guard_preserves_local_framework_socket_only(self):
        import socket
        m.network_guard('socket.connect', (NS(family=socket.AF_UNIX), '/local'))
        for event,args in [('socket.connect',(NS(family=socket.AF_INET),('example',443))), ('socket.getaddrinfo',('example',443))]:
            with self.assertRaises(RuntimeError):m.network_guard(event,args)

    def test_ownership_preserves_ordinary_teardown_and_original_case(self):
        source=(BASE/'native_ownership.py').read_text()
        self.assertIn('shape=(1, 4)',source)
        self.assertIn('releases != [True]',source)
        self.assertIn('np.allclose(output, [[2, 3, 4, 5]])',source)
        import ast
        tree=ast.parse(source)
        calls=[n for n in ast.walk(tree) if isinstance(n, ast.Call)]
        self.assertFalse(any(isinstance(n.func,ast.Attribute) and n.func.attr=='_exit' for n in calls))


if __name__ == '__main__': unittest.main()
