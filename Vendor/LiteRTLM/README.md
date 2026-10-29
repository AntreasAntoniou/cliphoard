# LiteRT-LM Swift wrapper

Unmodified production wrapper sources from Google LiteRT-LM v0.18.1, commit `bda624851d74be34d4e1f7fac1fc4155939539c7`, Apache-2.0 (LICENSE). Exact Git blob/SHA256 pins are in UPSTREAM-SOURCE-PINS.json. Binary runtime is fetched by SwiftPM from the official v0.18.1 macOS release with its pinned SHA256; binaries and caches are not committed. The binary contains arm64 and x86_64 macOS12+ slices. Compile/link on arm64 is verified; actual Intel execution remains a separate qualification.

Swift wrapper remains upstream Early Preview and is compiled in Swift5 package language mode. Upstream Sendable warnings are retained, not suppressed. App distribution must embed/sign the runtime dylib and retain applicable notices; linking alone does not package it.
