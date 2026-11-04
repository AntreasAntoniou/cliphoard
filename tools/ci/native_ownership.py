"""Small synthetic Core ML ownership probe, never pretrained weights.

Conceptual reference: apple/coremltools PR2829 (BSD-3-Clause upstream regression).
This separate probe preserves ordinary process exit and does not suppress crashes.
"""
import argparse
import ctypes
import gc
import importlib.metadata
import json
import platform
import sys
import time
import weakref
from pathlib import Path


def report(phase, **fields):
    print(json.dumps({"phase": phase, **fields}, sort_keys=True), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("build", "predict"))
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--compute", choices=("all", "cpu_only"), required=True)
    parser.add_argument("--allow-conversion-exception313", action="store_true")
    args = parser.parse_args()
    if not (args.allow_conversion_exception313 and sys.version_info[:3] == (3, 13, 13)):
        raise RuntimeError("Native CoreML9 exception requires explicit Python3.13.13")
    version = importlib.metadata.version("coremltools")
    if version != "9.0":
        raise RuntimeError("This baseline diagnostic is scoped to CoreML Tools9.0")
    report("runtime", python=sys.version, coremltools=version,
           numpy=importlib.metadata.version("numpy"), os=platform.mac_ver()[0], machine=platform.machine())
    import coremltools as ct
    import numpy as np
    unit = ct.ComputeUnit.ALL if args.compute == "all" else ct.ComputeUnit.CPU_ONLY
    if args.phase == "build":
        from coremltools.converters.mil import Builder as mb
        if args.package.exists():
            raise RuntimeError("Fresh synthetic output required")

        @mb.program(input_specs=[mb.TensorSpec(shape=(1, 4))], opset_version=ct.target.iOS16)
        def tiny(values):
            return mb.add(x=values, y=2.0)

        report("conversion_begin")
        result = ct.convert(tiny, convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                            compute_units=unit, skip_model_load=True)
        result.save(str(args.package))
        report("synthetic_package_saved")
        return

    report("load_begin")
    model = ct.models.MLModel(str(args.package), compute_units=unit)
    input_name = model.get_spec().description.input[0].name
    input_values = np.asarray([[0.0, 1.0, 2.0, 3.0]], dtype=np.float32)
    gil = ctypes.pythonapi.PyGILState_Check
    gil.restype = ctypes.c_int
    releases = []

    def released(_):
        releases.append(bool(gil()))

    owner = weakref.ref(input_values, released)
    report("prediction_begin")
    answer = model.predict({input_name: input_values})
    output = np.asarray(next(iter(answer.values())))
    if output.shape != (1, 4) or not np.isfinite(output).all() or not np.allclose(output, [[2, 3, 4, 5]]):
        raise RuntimeError("Synthetic numeric prediction failed")
    report("prediction_returned", finite=True)
    del input_values
    until = time.monotonic() + 5
    while owner() is not None and time.monotonic() < until:
        gc.collect()
        time.sleep(0.05)
    report("owner_release_observed", released=owner() is None, gil_states=releases)
    if owner() is not None or releases != [True]:
        raise RuntimeError("Owner release did not demonstrate the expected GIL discipline")
    report("normal_exit_pending")
    # Ordinary interpreter teardown is part of the test. No os._exit or signal masking.


if __name__ == "__main__":
    main()
