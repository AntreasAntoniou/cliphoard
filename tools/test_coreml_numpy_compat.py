"""Run in the documented Python 3.13 CoreML conversion environment."""
import unittest
from types import SimpleNamespace

import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops
from coremltools.converters.mil.frontend.torch.converter import TranscriptionContext

from coreml_numpy_compat import numpy_scalar_cast_compat


def lower(value, dynamic=False):
    @mb.program(input_specs=[mb.TensorSpec(shape=(1,))])
    def program(runtime_value):
        context = TranscriptionContext()
        context.add(runtime_value if dynamic else mb.const(val=value), "input")
        node = SimpleNamespace(inputs=["input"], name="result", kind="int")
        ops._int(context, node)
        return context["result"]
    return program.functions["main"].outputs[0]


class ScalarCastTests(unittest.TestCase):
    def test_upstream_reproduction(self):
        with self.assertRaises(TypeError):
            lower(np.array([3], dtype=np.int32))

    def test_singleton_constant_shapes(self):
        with numpy_scalar_cast_compat():
            for shape in [(), (1,), (1, 1), (1, 1, 1)]:
                with self.subTest(shape=shape):
                    out = lower(np.full(shape, 3.75, dtype=np.float32))
                    self.assertEqual(out.shape, ())
                    self.assertEqual(int(out.val), 3)

    def test_rejects_non_scalar_arrays(self):
        with numpy_scalar_cast_compat():
            for value in [np.array([1, 2]), np.zeros((1, 2))]:
                with self.subTest(shape=value.shape), self.assertRaises(ValueError):
                    lower(value)

    def test_dynamic_lowering_kept(self):
        with numpy_scalar_cast_compat():
            out = lower(None, dynamic=True)
            self.assertEqual(out.shape, ())
            self.assertIsNone(out.val)
            self.assertEqual(out.op.op_type, "cast")

    def test_restores_upstream_after_error(self):
        original = ops._cast
        with self.assertRaisesRegex(RuntimeError, "conversion failed"):
            with numpy_scalar_cast_compat():
                raise RuntimeError("conversion failed")
        self.assertIs(ops._cast, original)


if __name__ == "__main__":
    unittest.main()
