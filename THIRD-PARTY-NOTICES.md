# Third-Party Notices

Cliphoard itself is released under the [MIT License](LICENSE). It bundles and builds
on the following third-party components, each under its own license. **Note the
model licenses below** — they govern the model weights shipped
inside the distributed `.app`, not Cliphoard's own source code.

## On-device embedding models

### open-ogma-micro, open-ogma-small (Axiotic, "ogma-libre")
- **Repos:** https://huggingface.co/axiotic/open-ogma-micro ·
  https://huggingface.co/axiotic/open-ogma-small
- **License:** MIT.
- **Provenance:** distilled from `BAAI/bge-small-en-v1.5` (the 384-d head) and
  `BAAI/bge-large-en-v1.5` (the 1024-d head, which the app uses by default) —
  both MIT-licensed — so the entire supply chain is permissive.
- **How it reaches you:** NOT bundled. Downloaded from the repos above on first
  use and verified against a pinned SHA-256. Serving them from HuggingFace is
  deliberate: it is what makes real adoption of a model we released visible.

### all-MiniLM-L6-v2 (sentence-transformers) — High tier
- **Repo:** https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- **License:** Apache-2.0.
- **How it reaches you:** NOT bundled. Our CoreML conversion is fetched on demand
  from our GitHub release by `ModelAssets.ensure`, which verifies it against a
  pinned SHA-256 and refuses to install on mismatch.

### OpenVision-Tiny (UCSC-VLAA) — image understanding
- **Repo:** https://github.com/UCSC-VLAA/OpenVision
- **License:** Apache-2.0.
- **How it reaches you:** **BUNDLED.** Both towers (`openvision-tiny-p8-image`
  and `openvision-tiny-p8-text`, 34.6 MB together) ship inside the distributed
  `.app` — see `Scripts/deploy-local.sh`. It is the joint text-and-pixel space
  that lets you find a picture by describing it, including images carrying no
  recognisable text.
- **Attribution:** this is the only model shipped inside the binary, so it is the
  one whose Apache-2.0 attribution obligation this file discharges. It was
  omitted from these notices until 2026-09-01, while the two models named above
  were incorrectly described as bundled.

### Tokenizers (swift-transformers)
- **Repo:** https://github.com/huggingface/swift-transformers — Apache-2.0.
  Used for the MiniLM tokenizer and by the OpenVision text tower
  (`CLIPEmbedder` constructs an `AutoTokenizer`); the ogma tokenizer remains an
  original implementation in this repo.

## Removed: EmbeddingGemma

A `max` tier backed by [google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m)
was removed before release. It was the only component not under a permissive
license: the [Gemma Terms of Use](https://ai.google.dev/gemma/terms) carry a
prohibited-use policy and a flow-down obligation, so a recipient of an app
labelled MIT would have received something materially more restricted. Hosting
the converted weights for download also made this project their redistributor.
Removing the tier — rather than merely unbundling it — is what resolves both.

## System libraries

- **SQLite** (`libsqlite3`, linked from the system) — Public Domain.
- **AppKit, SwiftUI, CoreML, Carbon, ImageIO, Accelerate** — Apple system
  frameworks, used under the Apple SDK license.

## Tokenizer

The `OgmaTokenizer` (Unigram/SentencePiece) is an original implementation in this
repository (MIT), validated bit-for-bit against the reference Python tokenizer.
