"""Convert an ogma-libre checkpoint (axiotic/open-ogma-*) to CoreML.

Unlike the legacy convert_ogma.py (HF trust_remote_code models), ogma-libre
repos are self-contained: a vendored `ogma/` package + `ogma_libre.py` loader +
raw SentencePiece tokenizer. We trace base-trunk → proj_small (the 384-d head
distilled from BAAI/bge-small-en-v1.5, the repo's default) → L2 normalize, with
the same (input_ids, attention_mask, task_token_ids) interface the app's
OgmaEmbedder feeds.

Also materialises the tokenizer folder build-app.sh bundles: a Unigram-style
tokenizer.json (pieces + scores dumped from ogma_sp.model, unk_id 0) plus a
config.json carrying n_special_tokens — the exact inputs the Swift
OgmaTokenizer's libre scheme reads.

Usage:  python convert_ogma_libre.py models/open-ogma-small
"""
import json
import pathlib
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import coremltools as ct

P = pathlib.Path(sys.argv[1])
name = P.name
sys.path.insert(0, str(P))
from ogma_libre import OgmaLibre  # noqa: E402  (vendored in the model repo)

model = OgmaLibre.from_repo(str(P), device="cpu")


class Wrap(nn.Module):
    """base trunk → proj_small head → L2 normalize, app-shaped inputs."""
    def __init__(s, m):
        super().__init__()
        s.base = m.base
        s.proj = m.proj_small

    def forward(s, input_ids, attention_mask, task_token_ids):
        v = s.base(input_ids, attention_mask, task_token_ids)
        return F.normalize(s.proj(v), p=2, dim=1)


wrap = Wrap(model).eval()
enc = model.tokenizer.batch_encode(["the quick brown fox"], max_length=64)
ids = torch.from_numpy(enc["input_ids"].astype("int64"))
mask = torch.from_numpy(enc["attention_mask"].astype("int64"))
task = torch.tensor([5], dtype=torch.long)  # DOC
with torch.no_grad():
    ref = wrap(ids, mask, task).numpy()

# torch.export instead of jit.trace: the trunk's SDPA/RoPE shape math traces
# aten::Int nodes that coremltools' TorchScript frontend rejects; the export
# frontend carries proper SymInts through the same graph.
seq = torch.export.Dim("seq", min=1, max=1024)
exported = torch.export.export(
    wrap, (ids, mask, task),
    dynamic_shapes=({1: seq}, {1: seq}, {0: torch.export.Dim.STATIC}))
exported = exported.run_decompositions({})  # → ATEN dialect, as ct requires
sl = ct.RangeDim(lower_bound=1, upper_bound=1024, default=16)
ml = ct.convert(
    exported,
    inputs=[ct.TensorType(name="input_ids", shape=(1, sl), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, sl), dtype=np.int32),
            ct.TensorType(name="task_token_ids", shape=(1,), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS13,
    compute_units=ct.ComputeUnit.ALL)
ml.save(f"models/{name}.mlpackage")

pred = ml.predict({"input_ids": ids.numpy().astype(np.int32),
                   "attention_mask": mask.numpy().astype(np.int32),
                   "task_token_ids": task.numpy().astype(np.int32)})
cl = np.asarray(pred["embedding"]).reshape(-1)
cos = float(np.dot(ref.reshape(-1), cl) / (np.linalg.norm(ref) * np.linalg.norm(cl)))
print(f"{name}: dim={cl.shape[0]} parity_cosine={cos:.5f}")

# ── tokenizer folder for the app bundle ──────────────────────────────────────
# Dump the sp Unigram pieces into the tokenizer.json shape the Swift tokenizer
# reads. No [CLS]/[SEP] pieces — their absence is what flips Swift into the
# libre scheme (raw bos=2/eos=3, +7 only on vocab ids, byte fallback, NFKC).
import sentencepiece as spm  # noqa: E402

sp = spm.SentencePieceProcessor()
sp.Load(str(P / "tokenizer" / "ogma_sp.model"))
vocab = [[sp.IdToPiece(i), float(sp.GetScore(i))] for i in range(sp.GetPieceSize())]
tok_json = {"model": {"type": "Unigram", "unk_id": 0, "vocab": vocab}}
(P / "tokenizer.json").write_text(json.dumps(tok_json))
(P / "tokenizer_config.json").write_text(json.dumps(
    {"tokenizer_class": "T5Tokenizer", "scheme": "ogma-libre"}))
# Surface n_special_tokens at the top level where the Swift tokenizer looks.
cfg = json.loads((P / "config.json").read_text())
cfg["n_special_tokens"] = cfg.get("architecture", {}).get("n_special_tokens", 7)
(P / "config.json").write_text(json.dumps(cfg, indent=2))
print(f"{name}: tokenizer.json ({len(vocab)} pieces) + config written")
