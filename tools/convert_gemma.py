"""Convert google/embeddinggemma-300m to CoreML for the Max tier.

Wrapper bakes the ST pipeline (Gemma3TextModel → mean-pool → Dense 768→3072 →
Dense 3072→768 → L2 normalize) into one graph with (input_ids, attention_mask)
inputs. Task prompts are STRING PREFIXES ("task: search result | query: " /
"title: none | text: ") applied by the app before tokenizing — they're part of
the text, not the graph. Weights are 8-bit palettized (~300M params would be
~600MB fp16 — quantization halves it; parity is checked below).

Gated model: requires an HF login with access. Also materialises the tokenizer
folder swift-transformers' AutoTokenizer reads.
"""
import pathlib

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
import coremltools.optimize.coreml as cto
from sentence_transformers import SentenceTransformer

NAME = "embeddinggemma-300m"
st = SentenceTransformer(f"google/{NAME}", device="cpu")
gemma = st[0].auto_model.eval()
dense1, dense2 = st[2].linear, st[3].linear
tok = st.tokenizer


class Wrap(nn.Module):
    def __init__(s):
        super().__init__()
        s.m = gemma
        s.d1 = dense1
        s.d2 = dense2

    def forward(s, input_ids, attention_mask):
        # Hand the model a prebuilt 4-D additive mask: transformers' masking
        # utils early-out on 4-D input, skipping their vmap/.item() mask builder
        # that torch.export can't trace. -1e4 (not -inf/finfo.min): CoreML runs
        # fp16, where 0·(-inf) = NaN. use_cache=False: DynamicCache construction
        # is untraceable and useless for embedding. Correctness vs the real ST
        # pipeline is asserted below (cos > 0.999).
        ext = (1.0 - attention_mask[:, None, None, :].float()) * -10000.0
        h = s.m(input_ids=input_ids, attention_mask=ext,
                use_cache=False).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return F.normalize(s.d2(s.d1(pooled)), p=2, dim=1)


wrap = Wrap().eval()
probe = "task: search result | query: the quick brown fox"
enc = tok([probe], return_tensors="pt")
ids, mask = enc["input_ids"], enc["attention_mask"]
with torch.no_grad():
    ref = wrap(ids, mask).numpy()
st_ref = st.encode([probe], prompt="", normalize_embeddings=True)
assert float(np.dot(ref[0], st_ref[0])) > 0.999, "wrapper diverges from ST pipeline"

seq = torch.export.Dim("seq", min=2, max=511)
exported = torch.export.export(wrap, (ids, mask), dynamic_shapes=({1: seq}, {1: seq}))
exported = exported.run_decompositions({})
sl = ct.RangeDim(lower_bound=2, upper_bound=511, default=16)
ml = ct.convert(
    exported,
    inputs=[ct.TensorType(name="input_ids", shape=(1, sl), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, sl), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS13,
    # fp32 compute: Gemma activations overflow fp16 (NaN embeddings) — weights
    # are still 8-bit palettized below, so the size win is kept; runs CPU/GPU.
    compute_precision=ct.precision.FLOAT32,
    compute_units=ct.ComputeUnit.CPU_AND_GPU)

# 8-bit weight palettization: halves the bundle vs fp16 with negligible quality
# loss (parity verified against the fp32 PyTorch reference below).
ml = cto.palettize_weights(ml, cto.OptimizationConfig(
    global_config=cto.OpPalettizerConfig(nbits=8)))
ml.save(f"models/{NAME}.mlpackage")

pred = ml.predict({"input_ids": ids.numpy().astype(np.int32),
                   "attention_mask": mask.numpy().astype(np.int32)})
cl = np.asarray(pred["embedding"]).reshape(-1)
cos = float(np.dot(ref.reshape(-1), cl) / (np.linalg.norm(ref) * np.linalg.norm(cl)))
print(f"{NAME}: dim={cl.shape[0]} parity_cosine={cos:.5f} (8-bit palettized)")

dst = pathlib.Path(f"models/{NAME}")
dst.mkdir(exist_ok=True)
tok.save_pretrained(str(dst))
gemma.config.to_json_file(str(dst / "config.json"))
print(f"{NAME}: tokenizer folder written → {dst}")
