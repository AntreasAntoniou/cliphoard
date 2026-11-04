# Native CoreML CI guards

These scripts are CI checks, not app resources. The supervisor and pure tests use
Python 3.14+. CoreML 9's reviewed native dependency closure requires the explicit
Python 3.13.13 exception, limited to the child commands below. The setup helper
binds that environment; these scripts do not install packages or acquire models.

Use `coreml_backport.py run` with an absolute child executable and script, a fresh
log directory, and a bounded deadline. Child output indicating completion is not
success until the supervisor observes ordinary exit 0 and group cleanup. Do not
run these native checks locally as a side effect of running the pure tests.

```
python3.14 tools/ci/coreml_backport.py run --seconds 60 --log-dir "$WORK/ownership-build" -- "$NATIVE" -I -B "$REPO/tools/ci/native_ownership.py" build --package "$WORK/tiny.mlpackage" --compute all --allow-conversion-exception313
python3.14 tools/ci/coreml_backport.py run --seconds 60 --log-dir "$WORK/ownership-predict" -- "$NATIVE" -I -B "$REPO/tools/ci/native_ownership.py" predict --package "$WORK/tiny.mlpackage" --compute all --allow-conversion-exception313
python3.14 tools/ci/coreml_backport.py run --seconds 600 --log-dir "$WORK/minilm-convert" -- "$NATIVE" -I -B "$REPO/tools/ci/minilm_validation.py" convert --model "$WORK/model" --model-manifest "$REPO/tools/ci/minilm-inputs.json" --converter "$REPO/tools/convert_minilm.py" --out "$REPO/tools" --report-dir "$WORK/minilm-report" --allow-conversion-exception313
python3.14 tools/ci/coreml_backport.py run --seconds 120 --log-dir "$WORK/minilm-reopen" -- "$NATIVE" -I -B "$REPO/tools/ci/minilm_validation.py" verify --out "$REPO/tools" --report-dir "$WORK/minilm-report" --allow-conversion-exception313
```

The runner must supply `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`, bound CPU
threads to two, preserve HOME, and exclude credentials. Native scripts require
absolute paths. Python `-I` excludes arbitrary current-directory and user-site
imports; the MiniLM script explicitly adds only its own repository directory for
its pure parity helper. The provisioner's metadata-only distutils override should
not be inherited: native phases use the pinned environment's normal setuptools
hook, matching the intended converter semantics.

The ownership case is the prior four-float add-two model, ALL compute, with an
input-owner weakref and `PyGILState_Check`. Values are checked with NumPy's
`allclose` tolerance. A release callback must be observed exactly once with the
GIL held. This covers the tested ownership case; it does not instrument every
native queue or prove the original CI crash's cause.

The MiniLM guard runs the actual SHA-pinned `tools/convert_minilm.py` via `runpy`.
It replaces only its SentenceTransformer constructor with the approved local
safetensors loader (`local_files_only`, `token=False`, `trust_remote_code=False`).
Graph, Wrap, new_ones lowering, ALL compute, fixed batch one, and sequence range
2..511 remain in the actual converter. It requires exactly the ten pinned model
files, rejects extra files and symlinks, and never calls the Hub. Python socket
network attempts are denied; this is not OS-level isolation of native frameworks.

Output paths are `tools/models/all-MiniLM-L6-v2.mlpackage` and the corresponding
tokenizer directory; both must be absent before conversion. Other model outputs
may coexist. The report directory is exclusive. Three fixture checks enforce
finite 384-element, nonzero vectors and cosine at least .999; the original
wrapper-versus-SentenceTransformer dot product must exceed .9999. Receipts retain
actual token and attention-mask lengths, including padded16 and max511 cases.

A separate ordinary process checks unchanged output inventories, symbolic
`ArrayFeatureType.INT32`, default shape [1,16], fixed batch/range2..511, all three
saved-tokenizer fixtures and a reopened query prediction. It writes an exclusive
VERIFICATION.json. The original full model restore can then consume these fresh,
validated MiniLM outputs while continuing its remaining models. No cache hit
substitutes for these checks.

Pure validation (no native imports, models, downloads or subprocesses):
`/opt/homebrew/bin/python3.14 -B -m unittest discover -s tools/ci -p test_native_guards.py -v`.
