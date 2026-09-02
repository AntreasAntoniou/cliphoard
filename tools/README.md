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

## Requirements
`pip install -r requirements.txt` (torch, transformers, coremltools, sentencepiece,
safetensors, huggingface_hub)
Python 3.10 needs the `_compat.py` StrEnum shim (ogma's remote code uses 3.11's
`enum.StrEnum`). If HF downloads hit a brotli decode error, use `_dl.py` which
disables brotli content-encoding.

## Run
```bash
python3 _dl.py axiotic/open-ogma-micro                 # download → models/open-ogma-micro
python3 convert_ogma_libre.py models/open-ogma-micro   # → models/open-ogma-micro.mlpackage (+parity)
python3 _dl.py axiotic/open-ogma-small
python3 convert_ogma_libre.py models/open-ogma-small
bash restore-models.sh          # everything at once, incl. the pinned OpenVision zip (what CI runs)
```

The model's `forward(input_ids, attention_mask)` already returns the pooled, L2-normalised embedding. `Scripts/build-app.sh` compiles only the packages named in `BUNDLE_MODELS` (default: the two OpenVision towers) to `.mlmodelc` and bundles them, plus each text model's `<name>-tokenizer/` folder, into `Cliphoard.app/Contents/Resources`; `Scripts/verify-bundle.sh` then proves they landed. The other tiers download on demand.
