# CI-only Core ML ownership backport

This job uses **CoreMLTools 9.0 plus the upstream owner-release fix** in
`a207b1a3452eafe02f2d870f486287834af2c82d`. It does not describe the patched library
as an unchanged official wheel, publish a wheel, or change a shipped app. The
existing required model set remains intact. No Python runtime or model weights
are bundled in the app, and this job does not publish a native binary.

The checked-in lock names every exact official wheel URL, byte count and SHA-256
for the 47-package conversion environment. The stable source archive is pinned
by commit, size, hash, expanded file count and byte count. Its one replaced
Objective-C++ file is checked before and after replacement. `owner-release.patch`
preserves the exact upstream delta. The derived CMake driver excludes unrelated
Python/Conda/kmeans configuration and preserves the native target and its links.
Native `protoc` and `enumgen` generation remains reachable; the optional bare
Python protobuf generation is disabled. The native build uses two jobs and a
shared 600-second configure/build deadline, within a 1,200-second setup deadline.

Use an explicit Python 3.14+ parent:

```sh
python3.14 tools/ci/coreml_backport.py setup --python313 /absolute/python3.13 \
  --work-dir /absolute/new-directory --cmake /absolute/cmake --ninja /absolute/ninja \
  --cc /absolute/clang --cxx /absolute/clang++ --sdk /absolute/MacOSX26.5.sdk
```

The **narrow Python 3.13.13 exception** is required for the stable 9.0 cp313 arm64
binary and the controlled native ownership comparison. Setup invokes this exact
interpreter only for standard-library identity/venv setup; pip's explicit
`--python` target also invokes it. It does not import CoreMLTools, Torch, NumPy,
Hugging Face, or models. Python 3.14 drives pip. Native validation is a separate
reviewed invocation using the created runtime. There is no bare Python fallback.

Host admission selects Xcode 26.6 build 17F113, its SDK26.5 and Apple clang,
CMake4.4.4 and Ninja1.13.2. Compiler paths must resolve within that Xcode bundle;
actual compiler text and executable hashes are retained. This hosted toolchain
is intentionally different from the earlier local comparison and is not claimed
to reproduce the earlier CI host exactly. Python/pip and host toolchain/SDK code
are trusted host tooling, not a complete hermetic byte inventory.

`provision_cmake.py` supplies CMake4.4.4 from its exact PyPI universal2 wheel
URL, size and SHA-256, using a fresh Python3.14.6 environment and offline,
dependency-free installation. It validates installed RECORD files and the native
binary's version before publishing its absolute path to host admission. The
180-second tool phase retains provenance and cleanup results; only JSON reports
are uploaded. Hosted CMake is neither modified nor accepted as a fallback. This
avoids the runner-image inventory's change to4.4.5 without widening the existing
CMake, Ninja, Xcode or SDK checks. A newly built native backport must still pass
the complete required Models job; tool provisioning alone is not qualification.

The runtime is created fresh with copied, byte-checked Python and no system site
packages. Every installed distribution version and every in-site/out-of-site
RECORD payload is validated; no inherited script exclusions are used. Only the
native extension and its single RECORD row change. The original RECORD is kept
in the job directory. `environment.json` explicitly labels the overlay, records
source/fix/toolchain identities, and inventories the resulting site files.

## Other bounded child phases

```sh
python3.14 tools/ci/coreml_backport.py run --seconds 120 \
  --log-dir /absolute/new-phase --cwd /absolute/repo \
  --model-python /absolute/job/venv/bin/python3.13 \
  -- /absolute/job/venv/bin/python3.13 -I -B /absolute/native-check.py ...
```

The runner preserves the existing HOME, excludes credentials, and sets two-thread
and offline model flags. Native phases do not inherit the installation-only
`SETUPTOOLS_USE_DISTUTILS=stdlib` setting. Only an explicit
`--allow-model-downloads --model-python ...` enables model fetching for the
existing restore script; it does not forward tokens. A fresh task-local HF cache
is used. The optional `--cwd` defaults to the caller's current directory.

Each phase retains `RESULT.json` and bounded-observation stdout/stderr logs.
Ordinary signal cancellation is deferred until child process-group ownership is
recorded; failure cleanup has a two-second budget plus a bounded final receipt.
The initial task-directory creation occurs before the alarm is installed and is
not covered by the active timer. SIGKILL, machine failure, or uninterruptible
kernel/filesystem work may prevent receipt/cleanup. The log cap is sampled while the process runs, not a hard disk
quota. Output directories are exclusive; failed attempts are never reused.

Only `environment.json`, `RESULT.json`, host admission and guard JSON receipts
should be uploaded as CI evidence. Raw logs, wheels, environment files, generated
models and native binaries are not included in that reporting allowlist.

Pure/fake tests (no network, installs, native imports or native execution):
`python3.14 -B -m unittest discover -s tools/ci/tests -p test_coreml_backport.py -v`.

## CPython copy-source and mode contract

The failed first hosted attempt stopped before installation because the original
full-metadata equality conflated source mode with destination mode. It retained
no per-predicate metadata, so that specific mismatch remains unproved.
[CPython3.13.13 venv](https://github.com/python/cpython/blob/v3.13.13/Lib/venv/__init__.py#L150)
copies `sys._base_executable` and explicitly sets POSIX copies to0755. The
[official installer](https://github.com/python/cpython/blob/v3.13.13/Mac/BuildScript/build-installer.py#L1166)
adds group-write permission to framework files. The corrected contract pins the
reported copy source within the already admitted base-version prefix before
creation; it checks target bytes/size against that source and mode0755, while
requiring both original source/base metadata to remain unchanged. It does not
self-attest whatever new binary is produced. Each check retains fixed safe
`copy-check-01.json` through `copy-check-04.json` metadata/predicates before
refusal; these contain no environment variables or arbitrary paths. Original
failed attempt and consumer are preserved separately.
