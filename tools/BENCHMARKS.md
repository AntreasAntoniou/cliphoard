# Embedding-model benchmarks

Local clipboard-realistic retrieval set: 40 docs × 21 natural queries with one
gold doc each (defined in `validate_models.py`, run via `compare_models.py`).
**top-1/top-3**: retrieval accuracy. **margin**: mean gold cosine minus the 95th
percentile of non-gold cosines — how cleanly true hits separate from noise
(matters because the app thresholds on cosine; see `relevanceFloor`).

Measured 2026-07-22 on hestia (M-series, CPU, PyTorch fp32).

| model | params | dim | top-1 | top-3 | margin | license |
|---|---|---|---|---|---|---|
| embeddinggemma-300m | 307.6M | 768 | **20/21** | 21/21 | 0.223 | Gemma ToU |
| bge-large-en-v1.5 *(proj_large teacher)* | 335.1M | 1024 | 20/21 | 21/21 | 0.130 | MIT |
| bge-small-en-v1.5 *(proj_small teacher)* | 33.4M | 384 | 19/21 | 21/21 | 0.113 | MIT |
| all-MiniLM-L6-v2 | 22.7M | 384 | 19/21 | 21/21 | **0.295** | Apache-2.0 |
| **open-ogma-small (1024)** ← app default | **8.9M** | 1024 | 15/21 | 20/21 | 0.159 | MIT |
| legacy ogma-small (CC-BY-NC) | 8.6M | 256 | 15/21 | 20/21 | 0.154 | CC-BY-NC |
| open-ogma-small (384) | 8.7M | 384 | 15/21 | 19/21 | 0.118 | MIT |
| potion-base-32M | 32.3M | 512 | 14/21 | 21/21 | 0.148 | MIT |
| **open-ogma-micro (1024)** | **2.5M** | 1024 | 13/21 | 18/21 | 0.052 | MIT |
| open-ogma-micro (384) | 2.4M | 384 | 12/21 | 18/21 | 0.028 | MIT |
| potion-base-8M | 7.6M | 256 | 11/21 | 18/21 | 0.103 | MIT |
| potion-base-4M | 3.8M | 128 | 11/21 | 18/21 | 0.107 | MIT |
| potion-base-2M | 1.9M | 64 | 7/21 | 17/21 | 0.048 | MIT |

## Takeaways

- **The app's models win their size brackets.** open-ogma-small (8.9M) beats
  potion-base-32M at 3.6× fewer params; open-ogma-micro (2.5M) beats
  potion-8M/4M. Static-embedding models collapse on semantic query→doc
  retrieval; distilled trunks don't.
- **The 1024-d head fully recovers the legacy CC-BY-NC model** (equal top-1/
  top-3, better margin) — the MIT swap cost nothing.
- **EmbeddingGemma is the quality ceiling**; **all-MiniLM-L6-v2 is the value
  king** — 19/21 with the best margin of the whole table at 22.7M, Apache-2.0.
  These are the app's High/Max tiers.
- The gap to the teachers (15 vs 19–20 top-1) is trunk-limited, not head-limited
  — both ogma heads score identically at top-1.

Regenerate: `python compare_models.py` (cliphoard-tools env; EmbeddingGemma is
gated — needs an HF login with access).
