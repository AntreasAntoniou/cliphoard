# Third-party notices

Cliphoard is MIT-licensed (see LICENSE). It builds on the third-party components
below, each under its own licence.

**Only ONE model is bundled inside the distributed `.app`: OpenVision-Tiny.** The
others are downloaded after install. Each entry states which, because the
obligations differ: a bundled Apache-2.0 component must travel with its licence
text, which ships beside this file as `LICENSE-Apache-2.0.txt`.

> **Correction, 2026-09-01.** `LICENSE` previously stated that Cliphoard bundled
> CC-BY-NC-4.0 ogma models and that the MIT grant "including to sell" did not
> extend to them. Both halves were wrong: those models are MIT
> (`axiotic/open-ogma-micro`, `axiotic/open-ogma-small`) and were never bundled.
> **That restriction is withdrawn.** It was published in this repository's
> `LICENSE`; no application release ever carried it — the only published GitHub
> release is `models-v1`, which hosts model archives, not the app.
>
> `LICENSE` is now plain, unmodified MIT with nothing appended, so that automated
> licence detection resolves it correctly. Everything about third-party components
> lives here, in one place, pinned by `Tests/CliphoardTests/DistributionLicenceTests.swift`.

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
- **Weights:** https://huggingface.co/UCSC-VLAA/openvision-vit-tiny-patch8-224
  — the repo our converter actually reads (`tools/convert_openvision.py:55`).
- **Project:** https://github.com/UCSC-VLAA/OpenVision
- **License:** Apache-2.0 — full text in `LICENSE-Apache-2.0.txt`, shipped
  inside the `.app` and at the root of the DMG.
- **How it reaches you:** **BUNDLED.** Both towers (`openvision-tiny-p8-image`
  and `openvision-tiny-p8-text`, 34.6 MB together) ship inside the distributed
  `.app` — see `Scripts/deploy-local.sh`. It is the joint text-and-pixel space
  that lets you find a picture by describing it, including images carrying no
  recognisable text.
- **Attribution:** this is the only model shipped inside the binary, so it is the
  one whose Apache-2.0 attribution obligation this file discharges. It was
  omitted from these notices until 2026-09-01, while the two models named above
  were incorrectly described as bundled.

## Linked libraries (compiled into the Cliphoard binary)

These are not models. They are Swift packages statically linked into
`Cliphoard.app/Contents/MacOS/Cliphoard`, which makes every copy of the app a
redistribution of them. Their notices are reproduced verbatim below.

<!-- distribution-manifest — parsed by Tests/CliphoardTests/DistributionLicenceTests.swift.
     Every `linked:` line is checked against Package.resolved AND against the upstream
     LICENSE file in .build/checkouts. Adding a dependency turns the suite red until a
     human classifies it. Do NOT list models here: what is bundled is derived from
     BUNDLE_MODELS in the build scripts and stated once, in the prose above.
linked: https://github.com/huggingface/swift-transformers | licence: Apache-2.0 | copyright: Copyright 2022 Hugging Face SAS. | licence-file: LICENSE-Apache-2.0.txt
linked: https://github.com/johnmai-dev/Jinja | licence: MIT | copyright: Copyright (c) 2024 John Mai | licence-file: (reproduced inline below)
linked: https://github.com/apple/swift-collections.git | licence: Apache-2.0 with Runtime Library Exception | copyright: Copyright (c) 2021 - 2024 Apple Inc. and the Swift project authors | licence-file: LICENSE-Apache-2.0.txt
not-linked: https://github.com/apple/swift-argument-parser.git | reason: resolved transitively but used only by swift-transformers' TransformersCLI/HubCLI targets; the Transformers library product Cliphoard links does not depend on it
-->

### swift-transformers (Hugging Face) — Apache-2.0
- **Repo:** https://github.com/huggingface/swift-transformers
- Copyright 2022 Hugging Face SAS.
- Full licence text in `LICENSE-Apache-2.0.txt`, shipped inside the `.app` and at
  the DMG root. Used for the MiniLM tokenizer and by the OpenVision text tower
  (`CLIPEmbedder` constructs an `AutoTokenizer`); the ogma tokenizer remains an
  original implementation in this repository.

### Jinja (John Mai) — MIT
- **Repo:** https://github.com/johnmai-dev/Jinja
- Pulled in transitively by swift-transformers' `Tokenizers` target and compiled
  into the binary. MIT requires this notice travel with every copy:

```
MIT License

Copyright (c) 2024 John Mai

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### swift-collections (Apple) — Apache-2.0 with the Runtime Library Exception
- **Repo:** https://github.com/apple/swift-collections
- Copyright (c) 2021 - 2024 Apple Inc. and the Swift project authors
- `OrderedCollections` and `InternalCollectionsUtilities` are linked in via Jinja.
  The package's Runtime Library Exception expressly waives the §4(a), §4(b) and
  §4(d) attribution requirements for portions embedded into a compiled binary, so
  this entry is a record rather than a discharged obligation.

### swift-argument-parser (Apple) — resolved, NOT linked
- Appears in `Package.resolved` as a transitive resolution only. It is used by
  swift-transformers' `TransformersCLI`/`HubCLI` targets, which Cliphoard does not
  build. Recorded explicitly so its absence from the list above is a decision
  rather than an omission.

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
