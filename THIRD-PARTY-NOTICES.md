# Third-Party Notices

Cliphoard itself is released under the [MIT License](LICENSE). It bundles and builds
on the following third-party components, each under its own license. **Note the
non-commercial model licenses below** — they govern the model weights shipped
inside the distributed `.app`, not Cliphoard's own source code.

## On-device embedding models

### ogma-micro, ogma-small (Axiotic)
- **License:** Creative Commons Attribution-NonCommercial 4.0 (CC-BY-NC-4.0):
  https://creativecommons.org/licenses/by-nc/4.0/
- **Required attribution (must be included in all uses, per CC-BY-NC-4.0 §3.a):**

  > This model was trained via knowledge distillation from
  > `jina-embeddings-v5-text-small` (https://huggingface.co/jinaai/jina-embeddings-v5-text-small)
  > by Jina AI, licensed under CC-BY-NC-4.0.

- **Implication:** The CoreML conversions of these models are bundled inside the
  distributed Cliphoard binary. Under CC-BY-NC-4.0 the **weights may not be used for
  commercial purposes**. Cliphoard's own code is MIT and unaffected; this restriction
  applies to the bundled weights. Axiotic owns these models and may grant other
  terms for its own products — contact the maintainer if you need commercial use.

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
