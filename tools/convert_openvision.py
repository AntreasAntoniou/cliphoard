"""Convert OpenVision-Tiny (patch8/224) to two CoreML packages, with parity gates.

Run inside the pinned env (tools/requirements-openvision.txt on top of tools/requirements.txt):
    python tools/convert_openvision.py [--out DIR] [--check]

WHAT IS DELIBERATE HERE, because each one is a silent failure if got wrong:

1. NORMALISATION IS BAKED INTO THE GRAPH, not expressed as ImageType scale/bias.
   OpenVision uses IMAGENET stats (mean .485/.456/.406, std .229/.224/.225) — NOT CLIP's
   usual .481/.457/.408. Worse, the three std values differ per channel, and CoreML's
   ImageType takes a single scalar `scale` with a per-channel `bias`. Expressing a
   per-channel DIVISOR through a scalar scale is not possible, so the usual
   `scale=1/(255*std)` idiom silently applies one channel's std to all three. A wrapper
   module doing `(x - mean) / std` in the graph is exact and self-documenting.
   ImageType therefore only has to map 0-255 -> 0-1, which a scalar scale does exactly.

2. RESIZE IS SQUASH + BILINEAR. `Resize(size=(224,224))` with BOTH dims given is a squash,
   not a shortest-side-then-centre-crop. This is lucky for a clipboard: a wide screenshot
   is distorted rather than having its edges cropped away. The app must resize the same
   way; a centre crop here would silently lose the half of a screenshot the user searched
   for. Recorded in the manifest so the Swift side cannot drift.

3. TEXT LENGTH IS FIXED AT 80, NOT RangeDim. Dynamic sequence length is the usual cause of
   ANE -> CPU fallback. 80 tokens of padding costs nothing; the tokenizer already pads to
   exactly this.

4. WE TRACE THE REAL open_clip MODULES. Pooling details (pool_type, causal masking,
   sep-token stripping) are model config, not conversion config. Reimplementing the towers
   to "make tracing easier" is how those get silently dropped — and a dropped pooling rule
   still produces a well-formed 192-d vector that is simply wrong.

5. L2 NORM IS BAKED IN (`normalize=True`), matching HFEmbedder's existing contract so the
   Swift side never has to remember. Cosine then reduces to a dot product.

THE PARITY GATE THAT PER-TOWER CHECKS CANNOT PROVIDE: each tower can match its own PyTorch
reference perfectly while the two land in DIFFERENT 192-d spaces — a transposed projection
or an L2 applied to one tower only preserves per-tower parity and destroys the joint space,
which is the entire feature. So `--check` also does a CROSS-TOWER retrieval test with both
sides in CoreML.
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import open_clip
import torch
from tqdm import tqdm

REPO = "UCSC-VLAA/openvision-vit-tiny-patch8-224"
HUB = f"hf-hub:{REPO}"
DEFAULT_OUT = Path(__file__).resolve().parent / "models"
OUT = DEFAULT_OUT   # rebound by --out; convert()/check()/the size report all read this global
SIGNATURE = "openvision-tiny-p8"
CONTEXT = 80
EMBED = 192
# Upstream revision the shipped towers were converted from (HF HEAD, Apache-2.0).
REVISION = "a25ea3a2427415c197fedd2b52af390bbb3ead81"
# The text tower's tokenizer folder, at the path Scripts/build-app.sh reads
# (tools/models/<text tower name>/). Four files are upstream's own, copied byte for byte;
# the hashes are the shipped ones and a mismatch fails the conversion.
TOKENIZER_FILES = {
    "tokenizer.json":          "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66",
    "tokenizer_config.json":   "1f92c93d2e31974acffab86d48e80a9357acb18c68346c5472ef1d12c72d5d77",
    "special_tokens_map.json": "b6d346be366a7d1d48332dbc9fdf3bf8960b5d879522b7799ddba59e76237ee3",
    "vocab.txt":               "07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3",
}
# The ONE hand-written file. swift-transformers' AutoTokenizer.from(modelFolder:) reads BOTH
# tokenizer_config.json AND config.json and throws if either is absent; without it the embedder
# loaded as nil and image search was silently dark. ensure_ascii=False is load-bearing: the
# shipped file (sha256 below) contains an em dash, and the default escaping changes the bytes.
TOKENIZER_CONFIG = {
    "model_type": "bert",
    "_comment": "Minimal config for swift-transformers' AutoTokenizer.from(modelFolder:), which reads BOTH tokenizer_config.json AND config.json and throws if either is absent. Without this file the embedder loaded as nil and logged 'clip: embedder unavailable' — the two towers were present and correct in the bundle, and the whole feature was dark because a 30-byte JSON file was missing. OpenVision's text tower uses the bert-base-uncased WordPiece vocabulary ([CLS]=101, [PAD]=0), which is what model_type names here.",
    # KNOWN WRONG, DEFERRED: the WordPiece vocab has 30,522 entries. swift-transformers 0.1.24
    # never reads this field (DistributionLicenceTests.testSwiftTransformersNeverReadsVocabSize
    # keeps it so). Changing it changes TOKENIZER_CONFIG_SHA256, the zip and OPENVISION_ZIP_SHA256
    # — fix at the next re-conversion done for a real reason, in the same re-pin; never alone.
    "vocab_size": 32000,
    "max_position_embeddings": CONTEXT,
}
TOKENIZER_CONFIG_SHA256 = "34052afeafc09f0c7dcf7aa3a8f13c80a0e41ad3501ae21178bfda41006b032a"


def sha256_of(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()
SIDE = 224
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD = [0.229, 0.224, 0.225]


class VisionTower(torch.nn.Module):
    """0-1 RGB in, L2-normalised 192-d out. Normalisation inside the graph (see note 1)."""

    def __init__(self, clip: torch.nn.Module) -> None:
        super().__init__()
        self.clip = clip
        self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))

    def forward(self, pixels: torch.Tensor) -> torch.Tensor:
        return self.clip.encode_image((pixels - self.mean) / self.std, normalize=True)


class TextTower(torch.nn.Module):
    """Token ids in, L2-normalised 192-d out. Real module traced (see note 4)."""

    def __init__(self, clip: torch.nn.Module) -> None:
        super().__init__()
        self.clip = clip

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        return self.clip.encode_text(input_ids, normalize=True)


def convert() -> dict:
    OUT.mkdir(parents=True, exist_ok=True)
    steps = tqdm(total=7, desc="converting", unit="step")

    steps.set_description("loading checkpoint")
    model, _, preprocess = open_clip.create_model_and_transforms(HUB)
    model.eval()
    tokenizer = open_clip.get_tokenizer(HUB)
    steps.update(1)

    # Assert the preprocessing we baked in is the preprocessing the model expects. If
    # upstream ever changes stats or interpolation, fail here rather than ship a model
    # that is quietly 5-10 points worse.
    steps.set_description("asserting preprocess")
    found = {t.__class__.__name__: t for t in preprocess.transforms}
    norm = found["Normalize"]
    assert list(norm.mean) == IMAGENET_MEAN, f"mean drifted: {norm.mean}"
    assert list(norm.std) == IMAGENET_STD, f"std drifted: {norm.std}"
    resize = found["Resize"]
    assert tuple(resize.size) == (SIDE, SIDE), f"not a squash resize: {resize.size}"
    assert "bilinear" in str(resize.interpolation).lower(), f"interp drifted: {resize.interpolation}"
    steps.update(1)

    steps.set_description("tracing vision")
    vision = VisionTower(model).eval()
    px = torch.rand(1, 3, SIDE, SIDE)
    with torch.no_grad():
        traced_v = torch.jit.trace(vision, px)
    steps.update(1)

    steps.set_description("converting vision")
    mlv = ct.convert(
        traced_v,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIDE, SIDE),
                             scale=1.0 / 255.0, bias=[0.0, 0.0, 0.0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlv.save(str(OUT / f"{SIGNATURE}-image.mlpackage"))
    steps.update(1)

    steps.set_description("tracing text")
    text = TextTower(model).eval()
    ids = tokenizer(["a photo of a dog"])
    with torch.no_grad():
        traced_t = torch.jit.trace(text, ids)
    steps.update(1)

    steps.set_description("converting text")
    mlt = ct.convert(
        traced_t,
        inputs=[ct.TensorType(name="input_ids", shape=(1, CONTEXT), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
    )
    mlt.save(str(OUT / f"{SIGNATURE}-text.mlpackage"))
    steps.update(1)

    steps.set_description("tokenizer folder")
    from huggingface_hub import hf_hub_download
    tok_dir = OUT / f"{SIGNATURE}-text"
    tok_dir.mkdir(parents=True, exist_ok=True)
    for fname, want in TOKENIZER_FILES.items():
        shutil.copyfile(hf_hub_download(REPO, fname, revision=REVISION), tok_dir / fname)
        got = sha256_of(tok_dir / fname)
        assert got == want, f"{fname} from {REPO}@{REVISION} is {got}, expected {want}"
    (tok_dir / "config.json").write_text(
        json.dumps(TOKENIZER_CONFIG, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    got = sha256_of(tok_dir / "config.json")
    assert got == TOKENIZER_CONFIG_SHA256, f"config.json is {got}, expected {TOKENIZER_CONFIG_SHA256}"
    steps.update(1)
    steps.close()

    manifest = {
        "repo": REPO,
        "upstream_revision": REVISION,
        "licence": "apache-2.0",
        "signature": f"{SIGNATURE}-img-{EMBED}-v1",
        "embed_dim": EMBED,
        "context_length": CONTEXT,
        "image_side": SIDE,
        "resize": "squash-bilinear",
        "normalize_mean": IMAGENET_MEAN,
        "normalize_std": IMAGENET_STD,
        "l2_normalised_in_graph": True,
        "tokenizer": "bert-base-uncased wordpiece; [CLS]=101 pad=0",
        "tokenizer_sha256": dict(TOKENIZER_FILES, **{"config.json": TOKENIZER_CONFIG_SHA256}),
        "weight_sha256": {
            "image": sha256_of(OUT / f"{SIGNATURE}-image.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
            "text": sha256_of(OUT / f"{SIGNATURE}-text.mlpackage/Data/com.apple.CoreML/weights/weight.bin"),
        },
    }
    # text_mean is CARRIED OVER, never recomputed: the 90-noun x 5-template generator that
    # produced it was never committed (CLIPTextMean.swift's "regenerate with this script" is
    # wrong until it is). Overwriting the manifest without it would silently drop the field.
    for prior in (OUT / f"{SIGNATURE}-manifest.json", DEFAULT_OUT / f"{SIGNATURE}-manifest.json"):
        if prior.exists():
            old = json.loads(prior.read_text())
            if "text_mean" in old:
                manifest["text_mean"] = old["text_mean"]
                manifest["text_mean_note"] = old.get("text_mean_note", "")
                break
    else:
        print("WARNING: no prior manifest with text_mean found — the manifest will lack it", file=sys.stderr)
    if "text_mean" not in manifest:
        print("WARNING: text_mean absent from the written manifest", file=sys.stderr)
    (OUT / f"{SIGNATURE}-manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def check() -> int:
    """Parity gates. Per-tower first, then the cross-tower gate they cannot provide."""
    model, _, preprocess = open_clip.create_model_and_transforms(HUB)
    model.eval()
    tokenizer = open_clip.get_tokenizer(HUB)
    mlv = ct.models.MLModel(str(OUT / f"{SIGNATURE}-image.mlpackage"))
    mlt = ct.models.MLModel(str(OUT / f"{SIGNATURE}-text.mlpackage"))

    from PIL import Image

    rng = np.random.default_rng(0)
    worst_v, worst_t = 1.0, 1.0

    print("\n=== gate (b): per-tower numerical parity vs PyTorch ===")
    for _ in tqdm(range(12), desc="vision pairs", unit="img"):
        arr = rng.integers(0, 256, (SIDE, SIDE, 3), dtype=np.uint8)
        pil = Image.fromarray(arr)
        with torch.no_grad():
            ref = model.encode_image(
                preprocess(pil).unsqueeze(0), normalize=True).numpy()[0]
        got = mlv.predict({"image": pil})["embedding"].reshape(-1)
        worst_v = min(worst_v, float(np.dot(ref, got)))

    queries = ["a photo of a dog", "a screenshot of a terminal", "a receipt",
               "handwriting on paper", "a chart with red bars", "a person smiling"]
    for q in tqdm(queries, desc="text pairs", unit="q"):
        ids = tokenizer([q])
        with torch.no_grad():
            ref = model.encode_text(ids, normalize=True).numpy()[0]
        got = mlt.predict({"input_ids": ids.to(torch.int32).numpy()})["embedding"].reshape(-1)
        worst_t = min(worst_t, float(np.dot(ref, got)))

    print(f"  worst vision cosine : {worst_v:.6f}")
    print(f"  worst text   cosine : {worst_t:.6f}")

    print("\n=== gate (c): CROSS-TOWER alignment — CoreML joint space vs PyTorch joint space ===")
    print("  (per-tower parity CANNOT prove this: each tower can match its own reference")
    print("   perfectly while the two land in different spaces. A transposed projection or")
    print("   an L2 applied to one tower only survives (b) and destroys the feature.)")
    #
    # THIS GATE ASKS: did conversion PRESERVE the joint space? It does NOT ask whether the
    # model is any good — that is step 6's job, measured against the real baseline.
    #
    # The first version of this gate conflated the two and failed for the wrong reason. It
    # embedded solid colour fields and asserted "a solid red image" retrieves the red one.
    # CoreML scored 1/3 and it looked like a broken conversion. Running the IDENTICAL test
    # in pure PyTorch also scored 1/3: solid colour fields are far outside CLIP's training
    # distribution, every similarity sat at ~0.05, and the ordering was noise. The gate was
    # measuring a model weakness and calling it a conversion defect — which would have sent
    # us to the B-prime fallback over nothing.
    #
    # So the reference is PyTorch's own cross-tower ranking on the same inputs. Any input
    # works, including ones the model handles badly, because agreement is the property
    # under test.
    probes = ["a solid red image", "a solid green image", "a solid blue image",
              "a photo of a dog", "a screenshot of a terminal"]
    pil_set = [Image.new("RGB", (SIDE, SIDE), c)
               for c in [(220, 30, 30), (30, 200, 60), (40, 60, 220)]]
    ml_imgs = [mlv.predict({"image": p})["embedding"].reshape(-1) for p in pil_set]
    with torch.no_grad():
        pt_imgs = [model.encode_image(preprocess(p).unsqueeze(0),
                                      normalize=True).numpy()[0] for p in pil_set]
    agree, worst_x = 0, 1.0
    for probe in probes:
        ids = tokenizer([probe])
        ml_q = mlt.predict({"input_ids": ids.to(torch.int32).numpy()})["embedding"].reshape(-1)
        with torch.no_grad():
            pt_q = model.encode_text(ids, normalize=True).numpy()[0]
        worst_x = min(worst_x, float(np.dot(ml_q, pt_q)))
        rank_ml = list(np.argsort([-float(np.dot(ml_q, v)) for v in ml_imgs]))
        rank_pt = list(np.argsort([-float(np.dot(pt_q, v)) for v in pt_imgs]))
        same = rank_ml == rank_pt
        agree += same
        print(f"  {'SAME' if same else 'DIFF'} '{probe}': coreml={rank_ml} pytorch={rank_pt}")
    print(f"  cross-tower ranking agreement : {agree}/{len(probes)}")
    print(f"  worst text  cos(coreml,torch) : {worst_x:.6f}")

    ok = worst_v >= 0.999 and worst_t >= 0.999 and agree == len(probes) and worst_x >= 0.999
    print("\n  VERDICT:", "PARITY OK" if ok else "*** PARITY FAILED — do not ship ***")
    return 0 if ok else 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="run parity gates only")
    ap.add_argument("--out", default=str(DEFAULT_OUT),
                    help="output directory (default tools/models). Use a scratch dir to prove a run without touching the deployed set")
    args = ap.parse_args()
    OUT = Path(args.out).resolve()
    if args.check:
        sys.exit(check())
    manifest = convert()
    print("\n=== measured sizes (never quote the arithmetic) ===")
    total = 0
    for p in sorted(OUT.glob(f"{SIGNATURE}-*")):
        size = sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) if p.is_dir() else p.stat().st_size
        total += size
        print(f"  {p.name:<40} {size/1e6:>8.1f} MB")
    print(f"  {'TOTAL':<40} {total/1e6:>8.1f} MB")
    print(json.dumps(manifest, indent=2))
    sys.exit(check())
