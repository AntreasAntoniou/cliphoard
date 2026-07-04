# Ditto model tools — ogma → CoreML

Converts the axiotic **ogma** embedding models (and, later, EmbeddingGemma) to
CoreML for on-device deep search. Both ogma models convert with **exact parity**
(CoreML vs PyTorch cosine = 1.00000).

## Models (HuggingFace)
| Tier   | Repo                  | Params | Dim | Tokenizer            |
|--------|-----------------------|--------|-----|----------------------|
| low    | `axiotic/ogma-micro`  | 2.3M   | 128 | Unigram/SP, 30k vocab |
| normal | `axiotic/ogma-small`  | 8.6M   | 256 | Unigram/SP, 30k vocab |
| high   | `google/embeddinggemma-300m` (gated) | 300M | 768 | — |

License: ogma models are CC-BY-NC-4.0 (attribution to Jina AI teacher model).

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
