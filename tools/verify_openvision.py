"""Parameter ground truth for the OpenVision candidates, by TWO independent routes.

Why this exists as its own step, before any conversion:

The 20M parameter figure that survived the whole selection process was read from
`rwightman/openvision-vit-tiny-patch16-224`'s SAFETENSORS HEADER — cheap, exact, and for
the wrong checkpoint. The model actually chosen is `UCSC-VLAA/…-patch8-224`, whose 17.098M
was derived by CONFIG ARITHMETIC on top of that header read:

    patch_embed.proj.weight   192*3*16*16 = 147,456  ->  192*3*8*8 = 36,864
    visual.positional_embedding  [197,192] =  37,824  ->  [785,192] = 150,720
    net                                                              +2,304

Arithmetic on top of a measurement of a different file is not a measurement. And patch8
ships only `open_clip_pytorch_model.bin` — no safetensors — so the header trick CANNOT be
run against it. The verification attached to the number was impossible as written.

So: sum tensor shapes from the loaded state_dict (works for .bin), and cross-check the
patch16 sibling against its safetensors header. Two routes to the number that gates the
whole project.
"""
from __future__ import annotations

import json
import struct
import sys
import urllib.request

import torch
from tqdm import tqdm

CAP = 20_000_000

CANDIDATES = [
    ("UCSC-VLAA/openvision-vit-tiny-patch8-224", "PRIMARY — the model we would ship"),
    ("UCSC-VLAA/openvision-vit-tiny-patch16-224", "sibling, for the patch-size delta"),
]
# Same weights as the UCSC-VLAA patch16, mirrored WITH safetensors, so the header can be
# read without downloading. This is the independent cross-check.
SAFETENSORS_MIRROR = "rwightman/openvision-vit-tiny-patch16-224"


def tower_of(key: str) -> str:
    if key.startswith(("visual", "vision")):
        return "vision"
    if key.startswith(("text", "token_embedding", "positional_embedding",
                       "transformer.", "ln_final", "text_projection")):
        return "text"
    return "other"


def sum_state_dict(repo: str) -> dict:
    """Route 1: load the real checkpoint and sum every tensor. Works for .bin."""
    import open_clip

    model, _, _ = open_clip.create_model_and_transforms(f"hf-hub:{repo}")
    sd = model.state_dict()
    by_tower: dict[str, int] = {}
    for key, tensor in sd.items():
        by_tower[tower_of(key)] = by_tower.get(tower_of(key), 0) + tensor.numel()
    return {
        "by_tower": by_tower,
        "total": sum(by_tower.values()),
        "n_tensors": len(sd),
        "model": model,
    }


def sum_safetensors_header(repo: str) -> int:
    """Route 2: read only the header over HTTP. ~32KB, no weights downloaded."""
    url = f"https://huggingface.co/{repo}/resolve/main/open_clip_model.safetensors"

    def rng(a: int, b: int) -> bytes:
        req = urllib.request.Request(url, headers={"Range": f"bytes={a}-{b}",
                                                   "User-Agent": "cliphoard-verify"})
        return urllib.request.urlopen(req).read()

    n = struct.unpack("<Q", rng(0, 7))[0]
    header = json.loads(rng(8, 8 + n - 1))
    total = 0
    for key, meta in header.items():
        if key == "__metadata__":
            continue
        count = 1
        for dim in meta["shape"]:
            count *= dim
        total += count
    return total


def main() -> int:
    print("=" * 74)
    print("ROUTE 1 — state_dict tensor-shape sum (the checkpoint we would actually load)")
    print("=" * 74)

    results = {}
    for repo, note in tqdm(CANDIDATES, desc="loading checkpoints", unit="model"):
        tqdm.write(f"\n  {repo}\n    {note}")
        info = sum_state_dict(repo)
        results[repo] = info
        for tower in ("vision", "text", "other"):
            if info["by_tower"].get(tower):
                tqdm.write(f"      {tower:<8} {info['by_tower'][tower]:>12,}")
        tqdm.write(f"      {'TOTAL':<8} {info['total']:>12,}   "
                   f"({info['n_tensors']} tensors)")

    print()
    print("=" * 74)
    print("ROUTE 2 — safetensors header, independent, no weights downloaded")
    print("=" * 74)
    mirror_total = sum_safetensors_header(SAFETENSORS_MIRROR)
    print(f"  {SAFETENSORS_MIRROR}: {mirror_total:,}")

    p16 = results["UCSC-VLAA/openvision-vit-tiny-patch16-224"]["total"]
    p8 = results["UCSC-VLAA/openvision-vit-tiny-patch8-224"]["total"]

    print()
    print("=" * 74)
    print("CROSS-CHECK")
    print("=" * 74)
    agree = p16 == mirror_total
    print(f"  patch16 via state_dict : {p16:,}")
    print(f"  patch16 via header     : {mirror_total:,}")
    print(f"  agreement              : {'YES' if agree else '*** NO — INVESTIGATE ***'}")
    print(f"  patch8 - patch16 delta : {p8 - p16:+,}   (predicted +2,304)")
    print(f"  delta as predicted     : {'YES' if p8 - p16 == 2304 else 'NO'}")

    print()
    print("=" * 74)
    print("THE GATE")
    print("=" * 74)
    print(f"  cap                    : {CAP:,}")
    print(f"  patch8 (shipping)      : {p8:,}")
    ok = p8 < CAP and agree
    print(f"  VERDICT                : {'UNDER CAP — proceed' if ok else '*** STOP ***'}")
    if not agree:
        print("  (the two routes disagree; the number gating this project is not established)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
