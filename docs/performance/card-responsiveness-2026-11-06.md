# Card responsiveness and large histories

Local implementation based on `2a51f2e27d8aa7d4d04a5c51c0a1a6e53eed3cb8`.

Repeated UI reads were rerunning sensitive-content detection across unchanged text,
OCR, paths, source labels and user tags. Cache the verdict and authentication
fingerprint on each ClipItem and invalidate on every contributing field mutation.
Caches are ephemeral and follow the existing mutable ClipItem ownership contract;
no mutable item crosses the new detached-worker boundary. Detection rules,
authentication expiry and stored clipboard content are unchanged.

Pin/use/dedup moves now reposition one item and its affected ordered tag buckets.
They no longer sort the entire history or normalize/rebuild every user-tag bucket.
DisplayedClips shares the model array and produces rows on demand, retaining the
original indices used by keyboard shortcuts. Card text layout receives at most
2,048 characters plus an ellipsis; full text remains available for Inspect, search,
copy and export. The inspect button's entire existing 22x14 label is clickable.

Inspector similarity scoring uses immutable feature snapshots on a cancellable
worker and a stable top-eight list. Current membership and protection are checked
before displaying results. Image reads and downsampling run outside initial
window layout; decryption remains on the owning actor. Each view retains only its
display-sized image. No persistent thumbnail cache or database migration is added.

## Measurements

Debug XCTest, Apple Swift 6.4.2 on this Mac, synthetic ordinary clips, no real
clipboard history. One before run and final after run; these are component timings,
not end-to-end click latency or cold-start timings.

| Work | Clips | Before | After |
| --- | ---: | ---: | ---: |
| Repeated sensitivity pass | 8,000 | 815.27 ms | 0.52 ms |
| Repeated sensitivity pass | 32,000 | 3,286.48 ms | 2.28 ms |
| Full sort vs single-item reposition | 8,000 | 0.98 ms | 0.18 ms |
| Full sort vs single-item reposition | 32,000 | 4.16 ms | 0.69 ms |

The first sensitivity pass remains approximately 814 ms / 3,232 ms for these
fixtures. Pin timings compare only ordering, excluding database writes and the
removed user-tag rebuild. Histories still reside in memory; this is not database
pagination or an unbounded-history scalability claim. SQL contention, startup,
large rich-text inspector layout and full semantic-search latency were not measured.

## Validation

`swift test --filter 'CardResponsivenessTests|IncrementalIndexTests|SensitiveClipRevealTests|InspectorWindowTests|ImageUnderstandingWiringTests|ReferenceImageSearchTests|ImageUnderstandingTests|UserTagStorageTests|PanelHeightTests|PanelModalDismissalTests'`

77 tests selected: 74 passed, 3 skipped because CLIP towers are absent, 0 failures.
Includes 1,000 deterministic ordering mutations with ties; tag bucket parity after
pin/use/dedup; protected-field cache invalidation; authentication/revocation;
full Unicode text preservation; filtered shortcut identities; top-k parity and
cancelled async search. All are local synthetic or temporary-store tests.

Separately, ClipCardChromeTests had five passes and one failure:
`testTheCropStaysCentredOnThePicture` measured 0.045 red fraction for landscape
16:9 against a <0.02 expectation. Restoring the exact baseline ClipCardView source
and rerunning that test produced the identical failure. Neither the expectation
nor the crop implementation was changed. Preserve this pre-existing result; do
not describe the whole visual suite as passing.

No signed app, release upload, notarization, installation, App Store submission or
provider state changed. Native click-to-frame timing with a new build remains an
integration check before claiming measured improvements to the installed app.
