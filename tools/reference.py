"""Regenerate tools/reference.json — the golden tokenizer-ids + embedding-head
values EmbedderParityTests checks the Swift pipeline against.

Now targets open-ogma-small (ogma-libre): ids are bos=2 + (sp + 7) + eos=3, and
the vector is the 1024-d proj_large head (the app default), L2-normalised — exactly what the
converted CoreML model emits and the app computes.
"""
import json
import pathlib
import sys

import numpy as np
import torch
import torch.nn.functional as F

P = pathlib.Path("models/open-ogma-small")
sys.path.insert(0, str(P))
from ogma_libre import OgmaLibre  # noqa: E402

model = OgmaLibre.from_repo(str(P), device="cpu")
TASK = {"qry": 4, "doc": 5, "sym": 6}

samples = [("the quick brown fox", "doc"), ("hello world", "qry"),
           ("python ValueError stack trace", "doc")]
out = []
for text, task in samples:
    ids = model.tokenizer.encode(text, max_length=256)
    t_ids = torch.tensor([ids], dtype=torch.long)
    t_mask = torch.ones_like(t_ids)
    t_task = torch.tensor([TASK[task]], dtype=torch.long)
    with torch.no_grad():
        v = F.normalize(model.proj_large(model.base(t_ids, t_mask, t_task)), p=2, dim=1)
    v = v[0].numpy().reshape(-1)
    out.append({"text": text, "task": task, "ids": ids,
                "vec_head": [round(float(x), 5) for x in v[:6]],
                "norm": round(float(np.linalg.norm(v)), 5)})
json.dump(out, open("reference.json", "w"), indent=1)
for o in out:
    print(o["text"], "| task", o["task"], "| ids", o["ids"], "| head", o["vec_head"], "| norm", o["norm"])
