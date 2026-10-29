# Pinned Argmax audio production sources

Exact unmodified ArgmaxCore and WhisperKit files from upstream 1.1.1, revision `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`. See the per-file manifest and original MIT LICENSE. Embedded external sources retain their original copyright headers. The upstream selected Swift 6.2 manifest is retained for provenance.

Local targets preserve its language 6, upcoming concurrency and library-evolution settings under the verified Swift 6.4 compiler. Cliphoard itself retains language 5 and macOS 13. No production resources are declared by these upstream targets. Only the unused CLI/server dependency graph is omitted, avoiding its argument-parser version conflict with the existing text-search library. No source behavior edits or model downloads are part of this vendor copy.
