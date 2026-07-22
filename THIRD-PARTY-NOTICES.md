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
- **Provenance:** distilled from `BAAI/bge-small-en-v1.5` (384-d head, the one
  bundled) and `BAAI/bge-large-en-v1.5` — both MIT-licensed — so the entire
  supply chain of the bundled weights is permissive. The CoreML conversions are
  bundled inside the distributed Cliphoard binary and may be used commercially.

### all-MiniLM-L6-v2 (sentence-transformers) — High tier
- **Repo:** https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2
- **License:** Apache-2.0. Bundled as a CoreML conversion.

### EmbeddingGemma (Google) — Max tier
- **Repo:** https://huggingface.co/google/embeddinggemma-300m
- **License:** [Gemma Terms of Use](https://ai.google.dev/gemma/terms). Bundled
  as an 8-bit-palettized CoreML conversion; use of the weights is subject to
  Google's Gemma terms and the [Gemma prohibited use policy](https://ai.google.dev/gemma/prohibited_use_policy).

### Tokenizers (swift-transformers)
- **Repo:** https://github.com/huggingface/swift-transformers — Apache-2.0.
  Used for the MiniLM/Gemma tokenizers; the ogma tokenizer remains an original
  implementation in this repo.

## System libraries

- **SQLite** (`libsqlite3`, linked from the system) — Public Domain.
- **AppKit, SwiftUI, CoreML, Carbon, ImageIO, Accelerate** — Apple system
  frameworks, used under the Apple SDK license.

## Tokenizer

The `OgmaTokenizer` (Unigram/SentencePiece) is an original implementation in this
repository (MIT), validated bit-for-bit against the reference Python tokenizer.
