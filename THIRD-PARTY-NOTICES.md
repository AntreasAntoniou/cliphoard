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

### EmbeddingGemma (Google) — optional, not bundled by default
- **License:** [Gemma Terms of Use](https://ai.google.dev/gemma/terms).
- Only relevant if the optional high tier is ever bundled.

## System libraries

- **SQLite** (`libsqlite3`, linked from the system) — Public Domain.
- **AppKit, SwiftUI, CoreML, Carbon, ImageIO, Accelerate** — Apple system
  frameworks, used under the Apple SDK license.

## Tokenizer

The `OgmaTokenizer` (Unigram/SentencePiece) is an original implementation in this
repository (MIT), validated bit-for-bit against the reference Python tokenizer.
