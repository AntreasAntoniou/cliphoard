"""Convert sentence-transformers/all-MiniLM-L6-v2 to CoreML for the High tier.

Wrapper bakes the full ST pipeline (BERT → masked mean-pool → L2 normalize)
into one graph with the app-standard (input_ids, attention_mask) interface —
MiniLM is symmetric, so there's no task token and no prompt prefixes. Also
materialises tools/models/all-MiniLM-L6-v2/ with the tokenizer files
swift-transformers' AutoTokenizer reads (WordPiece via tokenizer.json).
"""
import pathlib
import shutil

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct
from sentence_transformers import SentenceTransformer

# coremltools has no converter for `new_ones` (emitted by transformers' BERT
# mask preparation). It's just a shaped fill — register the trivial lowering.
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import (
    _TORCH_OPS_REGISTRY, register_torch_op)

if "new_ones" not in _TORCH_OPS_REGISTRY:
    @register_torch_op
    def new_ones(context, node):
        inputs = _get_inputs(context, node)
        shape = mb.cast(x=inputs[1], dtype="int32")   # shape lists arrive as fp32
        context.add(mb.fill(shape=shape, value=1.0, name=node.name))

NAME = "all-MiniLM-L6-v2"
# eager attention: the sdpa mask path emits `new_ones`, which coremltools
# has no conversion for; the eager mask path converts cleanly.
st = SentenceTransformer(f"sentence-transformers/{NAME}", device="cpu",
                         model_kwargs={"attn_implementation": "eager"})
bert = st[0].auto_model.eval()
tok = st.tokenizer


class Wrap(nn.Module):
    """Bypasses BertModel.forward's mask preparation (its new_ones/bitwise ops
    have no CoreML lowering) and feeds the encoder the additive mask directly —
    numerically identical to get_extended_attention_mask for a 2-D mask."""
    def __init__(s, m):
        super().__init__()
        s.embeddings = m.embeddings
        s.encoder = m.encoder

    def forward(s, input_ids, attention_mask):
        emb = s.embeddings(input_ids=input_ids,
                           token_type_ids=torch.zeros_like(input_ids))
        # -1e4, not finfo.min: CoreML runs fp16, where finfo(fp32).min → -inf and 0·(-inf) = NaN.
        ext = (1.0 - attention_mask[:, None, None, :].to(emb.dtype)) * -10000.0
        h = s.encoder(emb, attention_mask=ext).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(h.dtype)
        pooled = (h * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return F.normalize(pooled, p=2, dim=1)


wrap = Wrap(bert).eval()
enc = tok(["the quick brown fox"], return_tensors="pt")
ids, mask = enc["input_ids"], enc["attention_mask"]
with torch.no_grad():
    ref = wrap(ids, mask).numpy()
# Reference sanity vs the ST pipeline itself.
st_ref = st.encode(["the quick brown fox"], normalize_embeddings=True)
assert float(np.dot(ref[0], st_ref[0])) > 0.9999, "wrapper diverges from ST pipeline"

# jit.trace, not torch.export: BERT's `new_ones` internals aren't supported by
# coremltools' EXIR frontend, while plain BERT is the TorchScript frontend's
# best-tested path (the opposite trade-off from the ogma trunk).
traced = torch.jit.trace(wrap, (ids, mask), strict=False)
sl = ct.RangeDim(lower_bound=2, upper_bound=511, default=16)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, sl), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, sl), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS13,
    compute_units=ct.ComputeUnit.ALL)
ml.save(f"models/{NAME}.mlpackage")

pred = ml.predict({"input_ids": ids.numpy().astype(np.int32),
                   "attention_mask": mask.numpy().astype(np.int32)})
cl = np.asarray(pred["embedding"]).reshape(-1)
cos = float(np.dot(ref.reshape(-1), cl) / (np.linalg.norm(ref) * np.linalg.norm(cl)))
print(f"{NAME}: dim={cl.shape[0]} parity_cosine={cos:.5f}")

# Tokenizer folder for the bundle (swift-transformers reads these directly).
dst = pathlib.Path(f"models/{NAME}")
dst.mkdir(exist_ok=True)
src = pathlib.Path(st[0].auto_model.config._name_or_path)
cache = pathlib.Path(tok.name_or_path)
tok.save_pretrained(str(dst))
# config.json (model config) is also read by AutoTokenizer.from(modelFolder:).
st[0].auto_model.config.to_json_file(str(dst / "config.json"))
print(f"{NAME}: tokenizer folder written → {dst}")
