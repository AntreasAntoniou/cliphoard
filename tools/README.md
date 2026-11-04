# Cliphoard model tools — ogma-libre / MiniLM / OpenVision → CoreML

Converts the axiotic **ogma** embedding models and **all-MiniLM-L6-v2** to
CoreML for on-device deep search. Both ogma models convert with **exact parity**
(CoreML vs PyTorch cosine = 1.00000).

## Models (HuggingFace)
| Tier   | Repo                        | Trunk | Out | Tokenizer            |
|--------|-----------------------------|-------|-----|----------------------|
| low    | `axiotic/open-ogma-micro`   | 128-d | 384 | raw SP, 30k + byte fallback |
| normal | `axiotic/open-ogma-small`   | 256-d | 384 | raw SP, 30k + byte fallback |
| high   | `sentence-transformers/all-MiniLM-L6-v2` (Apache-2.0, downloads on demand) | — | 384 | — |

Both open-ogma packages emit BOTH heads per prediction: `embedding` (384-d
proj_small, distilled from `BAAI/bge-small-en-v1.5`) and `embedding_large`
(1024-d proj_large, from `bge-large-en-v1.5`) — the app selects via Settings →
Vector detail (default: Full 1024-d). `validate_models.py` benchmarks legacy vs
open heads on a local retrieval set. License: MIT end-to-end (models AND teachers).
Legacy `axiotic/ogma-*` (CC-BY-NC, Jina teacher) still convert via
`convert_ogma.py` but are no longer bundled.

## Requirements and Python policy

Use Python **3.14+** for ordinary tooling, tests, funding tools and release validation.
The CoreML conversion environment is the one necessary exception: `coremltools==9.0`
publishes macOS wheels through CPython 3.13, with no cp314 wheel (verified against
[PyPI metadata](https://pypi.org/pypi/coremltools/9.0/json) on 2026-11-04). Use an
explicitly verified Python 3.13 interpreter in a separate environment for these
converters only. Do not change the system interpreter or downgrade other work.

```bash
/opt/homebrew/bin/python3.13 --version  # must be 3.13.x; conversion-only exception
/opt/homebrew/bin/python3.13 -m venv .venv-conversion
.venv-conversion/bin/python -m pip install 'pip==26.3'
.venv-conversion/bin/python -m pip install -r tools/requirements-openvision.txt
.venv-conversion/bin/python -m pip check
.venv-conversion/bin/python -m unittest discover -s tools -p test_coreml_numpy_compat.py -v
CLIPHOARD_MODEL_PYTHON="$PWD/.venv-conversion/bin/python" bash tools/restore-models.sh
```

The patched stack uses PyTorch 2.13.0 / torchvision 0.28.0, NumPy 2.5.4 and
Pillow 13.0.0. CoreML Tools still warns that its upstream-tested Torch version is
2.7; this repository qualifies its own converter paths rather than claiming
universal compatibility. `coreml_numpy_compat.py` temporarily corrects singleton
constant casts during OpenVision conversion, retains upstream handling of dynamic
values and invalid shapes, and restores the original converter even on failure.

Local 2026-11-04 validation: both Ogma heads for Micro and Small, and MiniLM,
reported cosine 1.00000; OpenVision passed 12 image / 6 text parity probes and
all 5 cross-tower ranking comparisons. Worst cosine was 0.999289 (vision) and
0.999681 (text). These are conversion checks, not new model quality claims.
The existing scikit-learn-conversion warning concerns an unused CoreML frontend.

## Run individual conversions

From `tools/`, use the explicit environment path, for example:

```bash
../.venv-conversion/bin/python _dl.py axiotic/open-ogma-small
../.venv-conversion/bin/python convert_ogma_libre.py models/open-ogma-small
../.venv-conversion/bin/python convert_minilm.py
../.venv-conversion/bin/python convert_openvision.py --out /absolute/scratch/openvision
```

Model weights are never bundled in the app. Production assets are separately
reviewed, pinned Hugging Face downloads prepared locally after user consent.
Conversion into a scratch directory does not publish assets or change existing
release pins. OpenVision's restore script uses the historical pinned asset ZIP
for maintainer checks; its converter also needs a reviewed centering manifest
before any new asset publication. None of this work republishes model assets.
