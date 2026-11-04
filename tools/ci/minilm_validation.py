"""Offline guard around the actual converter, followed by separate-process reopen.

Run with the bounded Python3.14 CI supervisor. Only this native child uses the
explicit CoreML9 Python3.13.13 compatibility exception. No model acquisition.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import socket
import sys

CONVERTER_SHA = '09f9ff8e4cd9ebd41ceb1124fb70dac1c1ca6c79ed3ef415c6564b3772777d7f'
NAME = 'all-MiniLM-L6-v2'
# -I excludes cwd and user site; permit this repository-owned pure helper only.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from embedding_parity import compare, vector


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, allow_nan=False, sort_keys=True, indent=2)
        stream.write('\n')


def inventory(root):
    require(root.is_dir() and not root.is_symlink(), 'regular_directory_required')
    result = {}
    for path in sorted(root.rglob('*')):
        require(not path.is_symlink(), 'symlink_rejected')
        if path.is_file():
            result[path.relative_to(root).as_posix()] = {'bytes': path.stat().st_size, 'sha256': digest(path)}
        else:
            require(path.is_dir(), 'nonregular_file')
    return result


def validate_model(root, manifest):
    expected = json.loads(manifest.read_text())['files']
    require(isinstance(expected, dict) and len(expected) == 10, 'ten_pinned_inputs_required')
    require('model.safetensors' in expected, 'safetensors_required')
    require(inventory(root) == expected, 'model_inventory_mismatch')


def network_guard(event, args):
    if event in ('socket.getaddrinfo', 'socket.gethostbyname', 'socket.gethostbyaddr'):
        raise RuntimeError('python_network_denied')
    if event in ('socket.connect', 'socket.bind', 'socket.sendto'):
        if not args or getattr(args[0], 'family', None) != socket.AF_UNIX:
            raise RuntimeError('python_network_denied')


def fixtures(tok):
    specs = [('query', 'the quick brown fox', None),
             ('padded16', 'the quick brown fox', 16),
             ('max511', ' '.join(['cat'] * 509), 511)]
    result = []
    for label, text, length in specs:
        kw = {'return_tensors': 'pt', 'truncation': True, 'max_length': length or 511}
        if length:
            kw['padding'] = 'max_length'
        enc = tok([text], **kw)
        ids, mask = enc['input_ids'], enc['attention_mask']
        require(ids.shape[0] == 1 and ids.shape == mask.shape and 2 <= ids.shape[1] <= 511, 'fixture_shape')
        require(not length or ids.shape[1] == length, 'fixture_length')
        active = int(mask.sum())
        require(active > 0 and (label != 'padded16' or active < 16) and
                (label != 'max511' or active == 511), 'fixture_mask')
        result.append((label, ids, mask))
    return result


def validate_spec(spec, int32):
    require([x.name for x in spec.description.input] == ['input_ids', 'attention_mask'], 'input_names')
    for inp in spec.description.input:
        require(inp.type.WhichOneof('Type') == 'multiArrayType', 'input_type')
        arr = inp.type.multiArrayType
        require(arr.dataType == int32, 'input_dtype_int32')
        require(list(arr.shape) == [1, 16], 'input_default_shape')
        require([(x.lowerBound, x.upperBound) for x in arr.shapeRange.sizeRanges] == [(1, 1), (2, 511)], 'input_ranges')
    require([x.name for x in spec.description.output] == ['embedding'], 'output_name')
    require(spec.description.output[0].type.WhichOneof('Type') == 'multiArrayType', 'output_type')


def local_loader(original, model):
    def load(name, **kwargs):
        require(name == f'sentence-transformers/{NAME}', 'unexpected_model_request')
        require(kwargs == {'device': 'cpu', 'model_kwargs': {'attn_implementation': 'eager'}}, 'converter_loader_changed')
        return original(str(model), device='cpu', local_files_only=True,
                        trust_remote_code=False, token=False,
                        model_kwargs={'attn_implementation': 'eager', 'use_safetensors': True},
                        processor_kwargs={'local_files_only': True})
    return load


def convert(args, np, torch):
    import sentence_transformers
    require(args.converter is not None and args.model is not None and args.model_manifest is not None, 'conversion_inputs_required')
    require(digest(args.converter) == CONVERTER_SHA, 'actual_converter_source_changed')
    validate_model(args.model, args.model_manifest)
    package = args.out / 'models' / f'{NAME}.mlpackage'
    tokenizer = args.out / 'models' / NAME
    require(not package.exists() and not tokenizer.exists(), 'fresh_model_outputs_required')
    args.report_dir.mkdir()  # exclusive, preserve prior attempts
    (args.out / 'models').mkdir(exist_ok=True)
    original = sentence_transformers.SentenceTransformer
    prior_cwd = Path.cwd()
    try:
        sentence_transformers.SentenceTransformer = local_loader(original, args.model)
        os.chdir(args.out)
        namespace = runpy.run_path(str(args.converter), run_name='__main__')
    finally:
        sentence_transformers.SentenceTransformer = original
        os.chdir(prior_cwd)
    vector(namespace['ref'].reshape(-1).tolist())
    vector(namespace['st_ref'].reshape(-1).tolist())
    wrapper_dot = float(np.dot(namespace['ref'][0], namespace['st_ref'][0]))
    require(wrapper_dot > .9999, 'wrapper_diverges_from_ST')
    rows = []
    for label, ids, mask in fixtures(namespace['tok']):
        with torch.no_grad():
            reference = namespace['wrap'](ids, mask).numpy().reshape(-1).tolist()
        prediction = namespace['ml'].predict({'input_ids': ids.numpy().astype(np.int32),
                                               'attention_mask': mask.numpy().astype(np.int32)})
        parity = compare(reference, np.asarray(prediction['embedding']).reshape(-1).tolist())
        rows.append({'name': label, 'sequenceLength': int(ids.shape[1]), 'activeMaskLength': int(mask.sum()),
                     'inputIDs': ids.tolist(), 'attentionMask': mask.tolist(), 'reference': reference, 'parity': parity})
    validate_model(args.model, args.model_manifest)
    save(args.report_dir / 'CONVERSION.json', {'converterSHA256': CONVERTER_SHA, 'wrapperSTDot': wrapper_dot,
         'fixtures': rows, 'compute': 'ALL', 'package': inventory(package), 'tokenizer': inventory(tokenizer),
         'normalInterpreterExitRequired': True})


def verify(args, np, ct):
    from transformers import AutoTokenizer
    prior = json.loads((args.report_dir / 'CONVERSION.json').read_text())
    package = args.out / 'models' / f'{NAME}.mlpackage'
    tokenizer = args.out / 'models' / NAME
    require(inventory(package) == prior['package'] and inventory(tokenizer) == prior['tokenizer'], 'artifact_changed')
    tok = AutoTokenizer.from_pretrained(str(tokenizer), local_files_only=True, token=False, trust_remote_code=False)
    cases = fixtures(tok)
    require([x[0] for x in cases] == [x['name'] for x in prior['fixtures']], 'fixture_names')
    for (_, ids, mask), old in zip(cases, prior['fixtures']):
        require(ids.tolist() == old['inputIDs'] and mask.tolist() == old['attentionMask'], 'tokenizer_roundtrip')
    ml = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
    int32 = ct.proto.FeatureTypes_pb2.ArrayFeatureType.INT32
    validate_spec(ml.get_spec(), int32)
    _, ids, mask = cases[0]
    prediction = ml.predict({'input_ids': ids.numpy().astype(np.int32), 'attention_mask': mask.numpy().astype(np.int32)})
    checked = compare(prior['fixtures'][0]['reference'], np.asarray(prediction['embedding']).reshape(-1).tolist())
    require(inventory(package) == prior['package'] and inventory(tokenizer) == prior['tokenizer'], 'artifact_changed_after_reopen')
    save(args.report_dir / 'VERIFICATION.json', {'specValidated': True, 'inputDataType': int(int32),
         'tokenizerFixturesMatched': 3, 'reopenedPrediction': checked, 'compute': 'ALL',
         'normalInterpreterExitRequired': True})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['convert', 'verify'])
    for name in ('out', 'report-dir', 'model', 'model-manifest', 'converter'):
        parser.add_argument('--' + name, type=Path, required=name in ('out', 'report-dir'))
    parser.add_argument('--allow-conversion-exception313', action='store_true')
    args = parser.parse_args()
    require(args.allow_conversion_exception313 and sys.version_info[:3] == (3, 13, 13), 'native_runtime_exception_scope')
    for name in ('out', 'report_dir', 'model', 'model_manifest', 'converter'):
        path = getattr(args, name)
        require(path is None or path.is_absolute(), 'absolute_paths_required')
    require(args.out.is_dir() and not args.out.is_symlink(), 'existing_output_root_required')
    require(os.environ.get('HF_HUB_OFFLINE') == '1' and os.environ.get('TRANSFORMERS_OFFLINE') == '1', 'offline_environment')
    sys.addaudithook(network_guard)
    import numpy as np
    import torch
    import coremltools as ct
    require(ct.__version__ == '9.0', 'coreml_version')
    torch.set_num_threads(2)
    torch.set_num_interop_threads(2)
    if args.phase == 'convert':
        convert(args, np, torch)
    else:
        verify(args, np, ct)
    print(json.dumps({'phase': args.phase, 'validated': True, 'normalExitStillRequired': True}), flush=True)


if __name__ == '__main__':
    main()  # normal interpreter teardown and child exit status are part of validation
