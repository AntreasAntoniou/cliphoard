# Ditto model tools — ogma → CoreML

Converts the axiotic **ogma** embedding models (and, later, EmbeddingGemma) to
CoreML for on-device deep search. Both ogma models convert with **exact parity**
(CoreML vs PyTorch cosine = 1.00000).

## Models (HuggingFace)
| Tier   | Repo                        | Trunk | Out | Tokenizer            |
|--------|-----------------------------|-------|-----|----------------------|
| low    | `axiotic/open-ogma-micro`   | 128-d | 384 | raw SP, 30k + byte fallback |
| normal | `axiotic/open-ogma-small`   | 256-d | 384 | raw SP, 30k + byte fallback |
| high   | `google/embeddinggemma-300m` (gated) | — | 768 | — |

Both open-ogma tiers ship the 384-d `proj_small` head (distilled from
`BAAI/bge-small-en-v1.5`). License: MIT end-to-end (models AND teachers).
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
python3 _dl.py axiotic/ogma-micro        # download → models/ogma-micro
python3 convert_ogma.py models/ogma-micro # → models/ogma-micro.mlpackage (+parity)
python3 _dl.py axiotic/ogma-small
python3 convert_ogma.py models/ogma-small
```

The model's `forward(input_ids, attention_mask)` already returns the pooled,
L2-normalised embedding. `build-app.sh` compiles any `tools/models/*.mlpackage`
to `.mlmodelc` and bundles them (plus `tokenizer.json`) into Ditto.app/Resources.
