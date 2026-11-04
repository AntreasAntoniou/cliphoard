"""Narrow Core ML Tools 9.0 workaround for NumPy 2 scalar casts.

Upstream _cast accepts singleton tensors but calls int(array), which NumPy 2
rejects. Extract only an already-validated singleton constant. Dynamic values
and invalid shapes still use the upstream lowering. No site-packages edits.
Remove after upgrading Core ML Tools and running the conversion parity gates.
"""
from contextlib import contextmanager

import coremltools as ct
import numpy as np
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch import ops


@contextmanager
def numpy_scalar_cast_compat():
    """Apply only during this single-threaded conversion, restoring on errors."""
    if ct.__version__ != "9.0":
        raise RuntimeError("Revalidate the NumPy cast workaround for this Core ML Tools version")
    original = ops._cast

    def cast(context, node, dtype, dtype_name):
        (x,) = ops._get_inputs(context, node, expected=1)
        if (x.can_be_folded_to_const() and isinstance(x.val, np.ndarray)
                and x.val.ndim > 0 and all(d == 1 for d in x.shape)):
            context.add(mb.const(val=dtype(x.val.item()), name=node.name), node.name)
        else:
            original(context, node, dtype, dtype_name)

    ops._cast = cast
    try:
        yield
    finally:
        ops._cast = original
