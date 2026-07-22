"""Model shootout on the local clipboard-retrieval set (validate_models.py's
DOCS/QUERIES): the app's open-ogma models vs notable embedding models across
the ~300M / ~30M / ~10M / ~3M size brackets.

Models:
  ~300M  google/embeddinggemma-300m (gated), BAAI/bge-large-en-v1.5 (the
         proj_large teacher)
  ~30M   BAAI/bge-small-en-v1.5 (the proj_small teacher),
         sentence-transformers/all-MiniLM-L6-v2, minishlab/potion-base-32M
  ~10M   minishlab/potion-base-8M, axiotic/open-ogma-small (both heads)
  ~3M    minishlab/potion-base-4M, minishlab/potion-base-2M,
         axiotic/open-ogma-micro (both heads)

Run inside the cliphoard-tools env from tools/:  python compare_models.py
"""
import pathlib
import sys

import numpy as np
import torch
import torch.nn.functional as F

from validate_models import DOCS, QUERIES, TASK

HERE = pathlib.Path(__file__).parent
ROWS = []


def evaluate(name, params_m, dim, D, Q):
    D = D / np.linalg.norm(D, axis=1, keepdims=True)
    Q = Q / np.linalg.norm(Q, axis=1, keepdims=True)
    sims = Q @ D.T
    gold = np.array([g for _, g in QUERIES])
    order = np.argsort(-sims, axis=1)
    top1 = int((order[:, 0] == gold).sum())
    top3 = int(sum(g in order[i, :3] for i, g in enumerate(gold)))
    gmask = np.zeros_like(sims, bool)
    gmask[np.arange(len(gold)), gold] = True
    margin = sims[gmask].mean() - np.percentile(sims[~gmask], 95)
    ROWS.append((name, params_m, dim, top1, top3, margin))
    print(f"  ran {name}")


def count_params(model):
    return sum(p.numel() for p in model.parameters()) / 1e6


# ── sentence-transformers models ─────────────────────────────────────────────
def st_model(repo, query_prefix="", doc_prefix="", use_st_prompts=False):
    from sentence_transformers import SentenceTransformer
    m = SentenceTransformer(repo, device="cpu")
    qs = [q for q, _ in QUERIES]
    if use_st_prompts:  # embeddinggemma ships task prompts in its ST config
        Q = m.encode_query(qs)
        D = m.encode_document(DOCS)
    else:
        Q = m.encode([query_prefix + q for q in qs])
        D = m.encode([doc_prefix + d for d in DOCS])
    evaluate(repo.split("/")[-1], count_params(m), Q.shape[1], np.asarray(D), np.asarray(Q))


# ── model2vec (potion) static models ─────────────────────────────────────────
def potion(repo):
    from model2vec import StaticModel
    m = StaticModel.from_pretrained(repo)
    D = m.encode(DOCS)
    Q = m.encode([q for q, _ in QUERIES])
    params_m = m.embedding.size / 1e6  # static table IS the model
    evaluate(repo.split("/")[-1], params_m, D.shape[1], np.asarray(D), np.asarray(Q))


# ── open-ogma (both heads) + legacy ──────────────────────────────────────────
def ogma_libre(repo_name):
    P = HERE / f"models/{repo_name}"
    sys.path.insert(0, str(P))
    for mod in [k for k in list(sys.modules) if k == "ogma_libre" or k.startswith("ogma")]:
        del sys.modules[mod]
    from ogma_libre import OgmaLibre
    m = OgmaLibre.from_repo(str(P), device="cpu")
    trunk_m = count_params(m.base)

    def embed(texts, task, head):
        outs = []
        for t in texts:
            ids = m.tokenizer.encode(t, max_length=256)
            ti = torch.tensor([ids])
            tt = torch.tensor([TASK[task]])
            with torch.no_grad():
                b = m.base(ti, torch.ones_like(ti), tt)
                v = m.proj_small(b) if head == 384 else m.proj_large(b)
            outs.append(F.normalize(v, p=2, dim=1)[0].numpy())
        return np.stack(outs)

    for head, proj in ((1024, m.proj_large), (384, m.proj_small)):
        params_m = trunk_m + count_params(proj)
        evaluate(f"{repo_name} ({head})", params_m, head,
                 embed(DOCS, "doc", head), embed([q for q, _ in QUERIES], "qry", head))
    sys.path.remove(str(P))


def legacy_ogma():
    from transformers import AutoConfig
    from transformers.dynamic_module_utils import get_class_from_dynamic_module
    from safetensors.torch import load_file
    P = str(HERE / "models/ogma-small")
    cfg = AutoConfig.from_pretrained(P, trust_remote_code=True)
    m = get_class_from_dynamic_module("ogma_model.OgmaModel", P)(cfg).eval()
    m.load_state_dict(load_file(f"{P}/model.safetensors"), strict=False)

    def embed(texts, task):
        with torch.no_grad():
            return np.asarray(m.embed(texts, task=task))

    evaluate("legacy ogma-small", count_params(m), 256,
             embed(DOCS, "doc"), embed([q for q, _ in QUERIES], "qry"))


if __name__ == "__main__":
    BGE_Q = "Represent this sentence for searching relevant passages: "
    st_model("google/embeddinggemma-300m", use_st_prompts=True)
    st_model("BAAI/bge-large-en-v1.5", query_prefix=BGE_Q)
    st_model("BAAI/bge-small-en-v1.5", query_prefix=BGE_Q)
    st_model("sentence-transformers/all-MiniLM-L6-v2")
    for p in ("potion-base-32M", "potion-base-8M", "potion-base-4M", "potion-base-2M"):
        potion(f"minishlab/{p}")
    ogma_libre("open-ogma-small")
    ogma_libre("open-ogma-micro")
    legacy_ogma()

    n = len(QUERIES)
    print(f"\n{'model':30s} {'params':>8s} {'dim':>5s} {'top-1':>7s} {'top-3':>7s} {'margin':>7s}")
    for name, pm, dim, t1, t3, mg in sorted(ROWS, key=lambda r: (-r[3], -r[4])):
        print(f"{name:30s} {pm:7.1f}M {dim:5d} {t1:4d}/{n} {t3:4d}/{n} {mg:7.3f}")
