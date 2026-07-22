"""Sanity-validate the open-ogma models against the legacy CC-BY-NC ogma-small
on a small local clipboard-realistic retrieval set.

For each model/head, embeds a ~40-doc corpus (task=doc) and 20 queries
(task=qry), ranks by cosine, and reports top-1 / top-3 accuracy plus the mean
cosine of the correct hit (separation sanity). Run inside the cliphoard-tools
env from tools/:  python validate_models.py
"""
import json
import pathlib
import sys

import numpy as np
import torch
import torch.nn.functional as F

HERE = pathlib.Path(__file__).parent

# ── local eval set: clipboard-shaped docs + natural queries ──────────────────
DOCS = [
    "git reset --soft HEAD~1",
    "git rebase -i origin/main",
    "kubectl rollout restart deployment/web",
    "docker compose up -d --build",
    "docker system prune -af --volumes",
    "SELECT * FROM users WHERE created_at > now() - interval '7 days'",
    "CREATE INDEX idx_orders_user ON orders(user_id);",
    "def quicksort(a): return a if len(a) < 2 else quicksort([x for x in a[1:] if x < a[0]]) + [a[0]] + quicksort([x for x in a[1:] if x >= a[0]])",
    "async function fetchJSON(url) { const r = await fetch(url); return r.json(); }",
    "Traceback (most recent call last):\n  File \"train.py\", line 42\nValueError: shapes (32,128) and (64,10) not aligned",
    "error[E0382]: borrow of moved value: `config`",
    "npm install --save-dev typescript",
    "pip install torch --index-url https://download.pytorch.org/whl/cu121",
    "brew install --cask ghostty",
    "https://github.com/AntreasAntoniou/cliphoard",
    "https://news.ycombinator.com/item?id=39471234",
    "https://en.wikipedia.org/wiki/Rotary_embedding",
    "Grandma's banana bread: 3 ripe bananas, 2 cups flour, bake at 350F for 55 minutes",
    "Slow-roast the lamb shoulder at 140C for 4 hours with rosemary and garlic",
    "225 Baker Street, London NW1 6XE, United Kingdom",
    "Leof. Kifisias 44, Marousi 151 25, Greece",
    "The mitochondrion is the powerhouse of the cell",
    "Photosynthesis converts light energy into chemical energy in chloroplasts",
    "Meet Sarah 3pm Thursday to review the Q3 roadmap",
    "Dentist appointment Tuesday 09:30, remember insurance card",
    "Invoice #2024-117: consulting services, EUR 4,800, due within 30 days",
    "Your one-time verification code is 493 221",
    "rgba(63, 214, 200, 1.0)",
    "#FF8800",
    "TODO: refactor the auth middleware before Friday's release",
    "The quarterly OKR review moved to the first Monday of October",
    "ssh -L 8080:localhost:8080 antreas@192.168.50.158",
    "chmod 600 ~/.ssh/id_ed25519",
    "Dear hiring team, I am writing to express my interest in the ML engineer role",
    "Best regards,\nAntreas Antoniou\nSenior Research Scientist",
    "flight LH1753 ATH→MUC departs 07:40 gate B23, seat 14C",
    "tracking number 1Z999AA10123456784, expected delivery Thursday",
    "λ = 0.001, batch_size = 256, warmup_steps = 1000",
    "The Stoics taught that virtue alone is sufficient for happiness",
    "WiFi: CozyCafe_Guest, password: espresso2024",
]

QUERIES = [  # (query, index of the single correct doc)
    ("undo my last commit", 0),
    ("restart a kubernetes pod", 2),
    ("spin up my containers", 3),
    ("free disk space used by docker", 4),
    ("find people who signed up recently", 5),
    ("speed up database lookups on orders", 6),
    ("algorithm to sort a list of numbers", 7),
    ("javascript to download json from an api", 8),
    ("python error about matrix shapes", 9),
    ("rust compiler complains about ownership", 10),
    ("add the typescript compiler to my project", 11),
    ("a sweet treat baked with fruit", 17),
    ("how long to cook lamb in the oven", 18),
    ("sherlock holmes street address", 19),
    ("which organelle makes energy", 21),
    ("calendar reminder to meet a coworker", 23),
    ("how much money does the client owe", 25),
    ("the 2fa code from my texts", 26),
    ("note about cleaning up authentication code", 29),
    ("port forwarding to my home server", 31),
    ("coffee shop internet login", 39),
]

TASK = {"qry": 4, "doc": 5}


def eval_model(name, embed_docs, embed_qrys):
    D = embed_docs(DOCS)                       # (n_docs, d), L2-normalised
    Q = embed_qrys([q for q, _ in QUERIES])    # (n_q, d)
    sims = Q @ D.T
    top1 = top3 = 0
    hit_cos = []
    for i, (_, gold) in enumerate(QUERIES):
        order = np.argsort(-sims[i])
        top1 += int(order[0] == gold)
        top3 += int(gold in order[:3])
        hit_cos.append(sims[i, gold])
    n = len(QUERIES)
    print(f"{name:28s} top-1 {top1:2d}/{n}  top-3 {top3:2d}/{n}  "
          f"gold-cos μ={np.mean(hit_cos):.3f}")


def norm(x):
    return x / np.linalg.norm(x, axis=1, keepdims=True)


# ── legacy ogma-small (CC-BY-NC), via its own HF remote code ────────────────
def legacy():
    from transformers import AutoConfig
    from transformers.dynamic_module_utils import get_class_from_dynamic_module
    from safetensors.torch import load_file
    P = str(HERE / "models/ogma-small")
    cfg = AutoConfig.from_pretrained(P, trust_remote_code=True)
    m = get_class_from_dynamic_module("ogma_model.OgmaModel", P)(cfg).eval()
    m.load_state_dict(load_file(f"{P}/model.safetensors"), strict=False)

    def embed(texts, task):
        with torch.no_grad():
            v = m.embed(texts, task=task)
        return norm(np.asarray(v))

    eval_model("legacy ogma-small (256)",
               lambda d: embed(d, "doc"), lambda q: embed(q, "qry"))


# ── open-ogma (libre), both heads ───────────────────────────────────────────
def libre(repo_name):
    P = HERE / f"models/{repo_name}"
    sys.path.insert(0, str(P))
    for mod in [k for k in list(sys.modules) if k == "ogma_libre" or k.startswith("ogma")]:
        del sys.modules[mod]  # the two repos vendor identically-named packages
    from ogma_libre import OgmaLibre
    m = OgmaLibre.from_repo(str(P), device="cpu")

    def embed(texts, task, head):
        outs = []
        for t in texts:
            ids = m.tokenizer.encode(t, max_length=256)
            t_ids = torch.tensor([ids], dtype=torch.long)
            t_mask = torch.ones_like(t_ids)
            t_task = torch.tensor([TASK[task]], dtype=torch.long)
            with torch.no_grad():
                base = m.base(t_ids, t_mask, t_task)
                v = m.proj_small(base) if head == 384 else m.proj_large(base)
                outs.append(F.normalize(v, p=2, dim=1)[0].numpy())
        return np.stack(outs)

    for head in (384, 1024):
        eval_model(f"{repo_name} ({head})",
                   lambda d, h=head: embed(d, "doc", h),
                   lambda q, h=head: embed(q, "qry", h))
    sys.path.remove(str(P))


if __name__ == "__main__":
    legacy()
    libre("open-ogma-small")
    libre("open-ogma-micro")
