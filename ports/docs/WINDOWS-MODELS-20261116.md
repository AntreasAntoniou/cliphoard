# Windows model qualification — 16 November 2026

## Supported inventory

Windows exposes every downloadable model family currently supported by the Mac source, alongside built-in basic matching. `ports/tests/check-mac-model-catalog.py --check` extracts the shipping Mac inventory and checks the Windows qualification fixture. Both Ogma heads are selectable in Search settings.

| Family | Windows use | Dimensions or checkpoint |
| --- | --- | --- |
| Built-in hashing | Local basic text matching | 256 |
| Ogma Micro | Neural and Smart text search | 384 and 1024 |
| Ogma Small | Neural and Smart text search | 384 and 1024 |
| all-MiniLM-L6-v2 | Neural and Smart text search | 384 |
| EmbeddingGemma 2 740M | Text and image search, qualified audio embedding backend | 768 |
| OpenVision Tiny patch8 | Text-to-image search, both towers | 192 |
| Whisper Small | Explicit local WAV transcription | Full ggml Small |
| Whisper Large v3 | Explicit local WAV transcription | Full ggml Large v3 |
| Whisper Large v3 Turbo | Explicit local WAV transcription | Full ggml Turbo |

Whisper inference uses the CPU whisper.cpp backend through Whisper.net 1.9.1. The checkpoints preserve the full model weights. Mac uses its platform-specific runtime representations. Windows uses verified upstream tensor data, ONNX Runtime 1.23.2 and the official LiteRT-LM Windows CPU runtime as appropriate.

Model preparation requires an explicit Download action. Cached preparation verifies existing assets and works offline. Application startup never acquires missing weights. The release payload contains the compiled weight-free graphs, tokenizer table, calibration constant, runtime libraries and notices. Downloaded learned weights live in the user model cache. History, OCR and transcripts remain inside the encrypted history envelope.

## Reproducible references

Reference scripts require an explicit Python 3.13 or newer interpreter. This run used Python 3.14.3 and the pinned packages in `ports/tests/model-requirements.txt`. All inputs are generated text, solid-color pictures and generated speech. No owner clipboard content appears in the fixtures.

- `hashing-reference.py` compiles the actual shipping Swift hashing implementation as the golden oracle, including Unicode and FNV behavior.
- `export-windows-ogma.py` produces weight-free architecture graphs and independent upstream PyTorch token/vector references. The cases cover both models, both heads, all three task tokens, Unicode, byte fallback and truncation.
- `export-windows-openvision.py` produces both weight-free towers and upstream PyTorch references. Checkpoint extraction uses `torch.load(weights_only=True)` in the offline reference tool. The Windows app only reads pinned raw ZIP tensor storages.
- `gemma-reference.py` invokes the official macOS ARM64 CPU C API to generate text, image and audio references against the identical pinned model.
- `check-mac-model-catalog.py --check` compares the current Mac asset and speech catalogs to the Windows inventory fixture.

The Gemma reference runtime is LiteRT-LM 0.19.1 C API 1.0.0. The Mac app currently ships 0.18.1. These tests compare the pinned model through the independently executed 0.19.1 CPU implementations. A direct numeric comparison with the shipping Mac 0.18.1 binary remains unqualified. Minimum measured cosine is 0.9994186825 for text, 0.9985696447 for images and 0.9987231260 for audio. Acceptance floors are 0.999 for text and 0.995 for image/audio, reflecting measured cross-platform CPU variance.

## Automated qualification

Each architecture passed 620 checks across the final suite runs. ARM64 inference ran natively. x64 inference ran under Windows ARM64 emulation. All builds used warnings-as-errors and completed with zero warnings and errors.

| Suite | Checks per architecture |
| --- | --- |
| Shipping Swift hashing goldens | 9 |
| Ogma inventory, tokenizer, both heads and three task tokens | 163 |
| OpenVision tokenizer, both towers, PNG decoding and centered color retrieval | 17 |
| Gemma text/image/audio goldens, retrieval, canceled-query reuse and lifetime cancellation | 11 |
| Seven text profiles, cache/model switches, settings, transcript safety and archive retention | 27 |
| Actual worker parent death and job teardown | 1 |
| WAV malformed-input and duration boundaries | 9 |
| Full Whisper Small, Large v3 and Turbo generated-speech decoding | 3 |
| MiniLM tokenizer/vector/ranking/cancellation | 21 |
| OCR and protected-content refusal | 5 |
| Shared Mac archive format | 45 |
| Themes and preferences | 44 |
| History persistence and validation | 29 |
| Clipboard formats, labels and exclusions | 27 |
| Legacy Windows archives | 25 |
| Native clipboard/input fixtures | 12 |
| Paste policy | 150 |
| Deferred paste | 22 |

Ogma minimum reference cosine exceeded 0.99999999999 for both architectures. OpenVision minimum exceeded 0.99999999999, including actual Windows PNG decoding and centered red/blue retrieval. MiniLM minimum was 0.9999999584. All three Whisper models returned the same 67-character synthetic phrase on both architectures. The Gemma values and acceptance tolerances are recorded above.

Guest evidence is retained under `C:\CliphoardDev\evidence`, including `all-models-arm64-*`, `all-models-x64-*`, `image-decode-arm64*`, `image-decode-x64*`, `speech-models*` and `models-policy-x64*`. Intermediate policy counters of 9 and 23 are included in the cumulative 150 and are counted once.

## Acquisition and attribution

Immutable revisions, exact byte sizes and SHA-256 hashes are compiled into the model asset declarations. The following primary sources identify the reviewed assets and runtimes.

| Asset | Immutable revision or runtime version | Source |
| --- | --- | --- |
| Ogma Micro | `acb318a6f4411a42085838e674ebc2aed1219310` | [Axiotic model](https://huggingface.co/axiotic/open-ogma-micro/tree/acb318a6f4411a42085838e674ebc2aed1219310) |
| Ogma Small | `3f4cd68f43719ca494772fcc80005c115d8d91ff` | [Axiotic model](https://huggingface.co/axiotic/open-ogma-small/tree/3f4cd68f43719ca494772fcc80005c115d8d91ff) |
| MiniLM | `1110a243fdf4706b3f48f1d95db1a4f5529b4d41` | [Sentence Transformers model](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/tree/1110a243fdf4706b3f48f1d95db1a4f5529b4d41) |
| OpenVision | `a25ea3a2427415c197fedd2b52af390bbb3ead81` | [UCSC-VLAA model](https://huggingface.co/UCSC-VLAA/openvision-vit-tiny-patch8-224/tree/a25ea3a2427415c197fedd2b52af390bbb3ead81) |
| Gemma 2 | `94408f31843f8bd0adb11c262292627287f5fda4` | [LiteRT community conversion](https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm/tree/94408f31843f8bd0adb11c262292627287f5fda4) |
| LiteRT-LM | 0.19.1, C API 1.0.0 | [Official Google release](https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.19.1) |
| Whisper checkpoints | `5359861c739e955e79d9a303bcbc70fb988958b1` | [whisper.cpp full checkpoints](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1) |
| Whisper.net | 1.9.1 | [Runtime implementation](https://github.com/sandrohanea/whisper.net) |

The official LiteRT archive provides a Windows x64 library. Windows ARM64 uses an adjacent private x64 helper under system emulation. This can make cold image indexing slow. The helper is owned by a kill-on-close Windows job, uses bounded anonymous stdio, holds verified model/runtime read leases and exposes no listener. Model/session revocation ends it immediately. Ordinary canceled queries drain their complete bounded response before discarding it, preserving a usable engine for the next query.

## Live UI qualification

The normal Windows Search settings expose every text model, both Ogma heads, both image models and all three Whisper choices. Ogma Small 1024 returned only the generated restaurant clip for the meaning-only query `something to eat`. Whisper Small transcribed a generated WAV through the Files inspector. Copy transcript and native paste produced the exact recognized 67-character sentence. The transcript persisted in encrypted history.

Gemma image mode ranked the generated red picture first for `red picture`, then ranked the blue picture first after replacing the query with `blue picture`. This also exercised superseded-query cancellation without losing the prepared worker. OpenVision preparation completed through the normal settings surface. The packaged x64 frontend returned only the red picture for `a red picture`. Its calibrated relevance floor can exclude all images for other queries in the current collection. The packaged x64 Ogma search also retrieved the restaurant clip and the speech file containing the relevant transcript for `something to eat`.

The existing shortcut, original paste target, session revocation, exact HWND/process admission, held-modifier refusal and partial SendInput safeguards remain in force. No host shortcut, sharing, account, security or VM integration setting was changed. Parallels automated input remains intermittent. Explicit held keys and focus traversal allowed live qualification.

## Scope and remaining qualification

The speech inspector accepts fully qualified local PCM16 mono 16 kHz WAV files, up to ten minutes and 20 MB. The three full speech models are selectable and qualified. Other media formats, the complete Mac media-library workflow and a raw-audio semantic-search UI remain pending. Gemma audio embeddings are qualified at the backend boundary with a thirty-second input limit.

Specialist generated tag baskets/facets and the complete Mac content detector suite remain separate parity work. Successful Windows Hello reveal, native x64 hardware and signed distribution remain unqualified. x64 tests execute under Windows ARM64 emulation. Packages remain unsigned private builds.

## Packaging

Version 1.1.0.0 has self-contained ARM64 and x64 ZIP, per-user MSI and unsigned MSIX outputs. Normal `dotnet build` creates the adjacent private ModelWorker automatically. Normal publish includes its complete private runtime. Fresh-output testing removed the development worker directory before building and verified it was recreated.

The compiled packager requires locked application/worker dependencies, compiled WinUI PRI/XBF resources and the private worker. It rejects test binaries and learned model weights, retains model/runtime notices, inventories payload hashes, runs full WiX MSI ICE validation and structurally validates MSIX with the Windows SDK. The first weight-exclusion rule also matched `ggml-*.dll` runtime libraries. The corrected rule restricts that checkpoint pattern to `.bin` files. Both final packages passed.

Guest artifacts reside in `C:\CliphoardDev\qualified-1.1.0-arm64-focus` and `C:\CliphoardDev\qualified-1.1.0-x64-focus`. Verified MSI copies are available in `ports/artifacts/1.1.0.0` on the host. Artifact files are ignored by Git. No release was published.

| Artifact | SHA-256 |
| --- | --- |
| ARM64 MSI | `D331209B1B3E61E7F378C38AE3AF3FD8980D4CC12EBDF4CB91799E91F807299F` |
| x64 MSI | `783CAF44B66603DC07D95DC3E8E8C823A0F2286CD4742781E5362F5FBF6D8298` |
| ARM64 ZIP | `ECAAF04399E1F16C3F7E87D325E5A44088AE9D58DCE1F9940BA0B044E5789A73` |
| x64 ZIP | `BEAB1A97CCFC150813368D1BB2E317BE7EF13B16E264D12D6DE9AAAFF2E22B1D` |
| ARM64 MSIX | `C7270C3B958C2322B658A757E58246B19643A3ED14ABA423D16097C467E646FC` |
| x64 MSIX | `14E4C74FBA40FBA47C4F4FBF981E15D160F9BFF8AB5566755549C2F72BD85FC2` |

## Final installed application

The final ARM64 MSI passed same-version upgrade, repair, uninstall and reinstall with exit0 for every operation. The encrypted history SHA-256 stayed unchanged through each operation. The installed executable matched the final ARM64 payload. Every inventoried file verified, covering 727 ARM64 and 731 x64 payload entries. The per-user Desktop shortcut targets the installed executable and its adjacent private worker is present. The final MSI transfers to the host matched the hashes above.

A final live pass exposed search focus moving when asynchronous model preparation rebuilt the toolbar. `BuildChrome` now preserves an already focused search field while the bar remains the foreground window. The installed app accepted typing after image-model preparation, retained search across Settings, and completed live Gemma image retrieval through its installed helper. Actual Windows focus/paste also passed again. From the synthetic editor, the global shortcut opened the bar, `something to eat` found the restaurant clip and relevant speech transcript, and Enter pasted the full restaurant sentence back into the original editor.

The app is left running from the per-user ARM64 installation, with the bar visible and its query empty. The chosen test preferences are Smart mode, Ogma Small 1024, OpenVision for image mode and Whisper Small for speech. All supported model files are cached and verified. Startup remains off. The nine retained clips are generated qualification data. Full downloaded model weights remain outside the installer payload.

The earlier package hashes were superseded by the final focus repair before delivery. The table above identifies the final artifacts. The x64 model suites and live frontend search ran under ARM64 emulation. The final shared focus repair was visually checked on the installed native ARM64 app.
