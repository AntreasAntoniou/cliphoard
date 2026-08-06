import XCTest
@testable import Cliphoard

/// The card chip row (spec §3.1–§3.9 glance-actions + principle 6).
///
/// The assertions worth having here are mostly *negative*: the audit's finding
/// was that the old row always found two strings to show, so the tests that
/// matter are the ones pinning "shows nothing", "shows no more than three", and
/// "never invents a reassuring label". Every age-sensitive case injects `now`,
/// so nothing here depends on wall-clock.
final class ClipChipTests: XCTestCase {

    /// Fixed reference instant; fixtures are offsets from it.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private func clip(kind: ClipKind = .text,
                      text: String = "hello",
                      // Default age/useCount land squarely in the ambiguous
                      // lifecycle middle, so a fixture only gets a chip when the
                      // test deliberately gives it one.
                      ageSeconds: TimeInterval = 2 * day,
                      useCount: Int = 1,
                      pinned: Bool = false,
                      sourceApp: String? = nil,
                      flags: ClipFlags = [],
                      shape: String? = nil,
                      userTags: [String] = []) -> ClipItem {
        let item = ClipItem(kind: kind, text: text)
        item.createdAt = now.addingTimeInterval(-ageSeconds)
        item.lastUsedAt = item.createdAt
        item.useCount = useCount
        item.pinned = pinned
        item.sourceApp = sourceApp
        item.flags = flags
        item.shape = shape
        item.userTags = userTags
        return item
    }

    // MARK: - Protective chips

    func testSecretClipRendersAProtectiveChipFirst() {
        let item = clip(text: "ghp_0123456789abcdefghij", flags: [.secret])
        let row = ClipChips.row(for: item, now: now)
        XCTAssertEqual(row.shown.first, .flag(.secret))
        XCTAssertEqual(row.shown.first?.tier, .protective)
        // Not colour alone: there is a glyph and a spoken label saying "sensitive".
        XCTAssertFalse(row.shown[0].symbol.isEmpty)
        XCTAssertTrue(row.shown[0].spoken.lowercased().contains("sensitive"),
                      "a protective chip must say so in words: \(row.shown[0].spoken)")
    }

    func testEveryProtectiveFlagProducesAChip() {
        for (name, flag) in ClipFlags.allKnown {
            let item = clip(flags: flag)
            let chips = ClipChips.chips(for: item, now: now)
            XCTAssertEqual(chips.first, .flag(flag), "\(name) produced \(chips)")
            XCTAssertFalse(chips[0].title.isEmpty, "\(name) has no chip title")
            XCTAssertFalse(chips[0].spoken.isEmpty, "\(name) has no VoiceOver label")
        }
    }

    /// §3.3 splits email/phone out as informational precisely so it does not
    /// crowd out a real warning on a three-slot row.
    func testProtectiveFlagsOutrankTheInformationalPIIBadge() {
        let item = clip(flags: [.pii, .quarantined])
        let chips = ClipChips.chips(for: item, now: now)
        XCTAssertEqual(chips, [.flag(.quarantined), .flag(.pii)])
        XCTAssertEqual(chips[0].tier, .protective)
        XCTAssertEqual(chips[1].tier, .informational)
    }

    /// §3.1 keeps the low-confidence entropy heuristic on its own bit; it must
    /// never displace a Tier-1 verdict.
    func testEntropyHintYieldsToTierOneSignals() {
        let item = clip(flags: [.secretEntropy, .financial])
        XCTAssertEqual(ClipChips.chips(for: item, now: now),
                       [.flag(.financial), .flag(.secretEntropy)])
    }

    // MARK: - Blank is the correct, common outcome

    func testBenignClipWithNothingToSayRendersNoChips() {
        // No flags, no shape, no recorded origin, no user labels, and squarely in
        // the ambiguous lifecycle middle (older than fresh, younger than
        // throwaway, pasted once). There is nothing honest to show.
        let item = clip(ageSeconds: 2 * Self.day, useCount: 1)
        XCTAssertEqual(ClipChips.chips(for: item, now: now), [])
        let row = ClipChips.row(for: item, now: now)
        XCTAssertTrue(row.shown.isEmpty)
        XCTAssertEqual(row.overflow, 0)
    }

    func testNoPositiveSafeOrPublicLabelIsEverEmitted() {
        let forbidden = ["safe", "public", "clean", "benign", "ok", "trusted"]
        let fixtures: [ClipItem] = [
            clip(),
            clip(flags: [.secret]),
            clip(flags: [.pii, .financial, .otp]),
            clip(sourceApp: "Safari", shape: "json"),
            clip(kind: .link, text: "https://arxiv.org/abs/2401.00001", useCount: 0),
            clip(pinned: true, userTags: ["work"])
        ]
        for item in fixtures {
            for signal in ClipChips.chips(for: item, now: now) {
                let words = "\(signal.title) \(signal.menuTitle) \(signal.spoken)".lowercased()
                for word in forbidden {
                    XCTAssertFalse(words.split(whereSeparator: { !$0.isLetter }).contains(Substring(word)),
                                   "chip \(signal) claims '\(word)' — no detector can prove safety")
                }
            }
        }
        // Structurally, not just lexically: an empty flag set yields no flag chip.
        XCTAssertFalse(ClipChips.chips(for: clip(), now: now).contains { if case .flag = $0 { return true } else { return false } })
    }

    /// `OptionSet.contains([])` is vacuously true — an empty signal would
    /// otherwise match (and so label) every clip in the history.
    func testEmptyFlagSignalMatchesNothing() {
        XCTAssertFalse(ClipSignal.flag([]).matches(clip(flags: [.secret]), now: now))
        XCTAssertFalse(ClipSignal.flag([]).matches(clip(), now: now))
    }

    // MARK: - Principle 6: at most three

    func testRowNeverShowsMoreThanThreeElements() {
        XCTAssertEqual(ClipChips.maxChips, 3)
        let loaded = clip(kind: .link,
                          text: "https://arxiv.org/abs/2401.00001",
                          ageSeconds: 0,
                          useCount: 0,
                          pinned: true,
                          sourceApp: "Safari",
                          flags: [.secret, .financial, .pii, .otp],
                          shape: "url",
                          userTags: ["work", "invoice"])
        let row = ClipChips.row(for: loaded, now: now)
        XCTAssertGreaterThan(ClipChips.chips(for: loaded, now: now).count, 3)
        // Two chips plus the "+N" affordance — three elements on the row.
        XCTAssertEqual(row.shown.count, ClipChips.maxChips - 1)
        XCTAssertEqual(row.shown.count + 1, ClipChips.maxChips)
        XCTAssertEqual(row.overflow, ClipChips.chips(for: loaded, now: now).count - row.shown.count)
    }

    func testExactlyThreeChipsFitWithoutOverflow() {
        let item = clip(pinned: true, sourceApp: "Safari", shape: "json")
        let row = ClipChips.row(for: item, now: now)
        XCTAssertEqual(row.shown.count, 3)
        XCTAssertEqual(row.overflow, 0)
    }

    /// Whatever the clip carries, the rendered row stays within the cap.
    func testCapHoldsAcrossAMatrixOfClips() {
        for flags in [ClipFlags(), [.secret], [.pii, .financial], ClipFlags.allKnown.reduce(into: ClipFlags()) { $0.insert($1.flag) }] {
            for shape in [nil, "json"] as [String?] {
                for source in [nil, "Safari"] as [String?] {
                    for tags in [[], ["a", "b", "c"]] {
                        let item = clip(useCount: 0, pinned: true, sourceApp: source,
                                        flags: flags, shape: shape, userTags: tags)
                        let row = ClipChips.row(for: item, now: now)
                        XCTAssertLessThanOrEqual(row.shown.count + (row.overflow > 0 ? 1 : 0),
                                                 ClipChips.maxChips)
                    }
                }
            }
        }
    }

    // MARK: - Certainty ordering

    func testOrderFollowsFlagsThenStructureThenBehaviourThenUserTags() {
        let item = clip(useCount: 0,
                        pinned: true,
                        sourceApp: "Safari",
                        flags: [.secret],
                        shape: "json",
                        userTags: ["work"])
        XCTAssertEqual(ClipChips.chips(for: item, now: now),
                       [.flag(.secret), .shape("json"), .source("Safari"),
                        .lifecycle("sticky"), .userTag("work")])
    }

    func testLinkDispositionPrecedesLifecycle() {
        let item = clip(kind: .link,
                        text: "https://doi.org/10.1038/nature12373",
                        ageSeconds: 0,
                        useCount: 0,
                        pinned: true)
        XCTAssertEqual(ClipChips.chips(for: item, now: now),
                       [.lifecycle("reference"), .lifecycle("sticky")])
    }

    func testUserTagsYieldTheScarceSlotsToWhatTheUserDoesNotKnow() {
        let item = clip(sourceApp: "Safari", userTags: ["work"])
        XCTAssertEqual(ClipChips.chips(for: item, now: now),
                       [.source("Safari"), .userTag("work")])
    }

    // MARK: - Principle 4: what you see, you can filter by

    /// Every chip a card renders must select its own clip when used as a filter.
    /// This is the property that makes the chips actionable rather than
    /// decorative, and it is only true because both paths share `ClipSignal`.
    func testEveryRenderedChipMatchesTheClipItCameFrom() {
        let fixtures: [ClipItem] = [
            clip(sourceApp: "Terminal", flags: [.secret, .pii], shape: "code", userTags: ["ops"]),
            clip(kind: .link, text: "https://arxiv.org/abs/2401.00001", ageSeconds: 0, useCount: 0),
            clip(ageSeconds: 30 * Self.day, useCount: 0),
            clip(pinned: true, sourceApp: "com.apple.dt.Xcode")
        ]
        for item in fixtures {
            for signal in ClipChips.chips(for: item, now: now) {
                XCTAssertTrue(signal.matches(item, now: now),
                              "\(signal) is shown on a clip it does not match")
            }
        }
    }

    func testSignalsDoNotMatchUnrelatedClips() {
        let benign = clip()
        XCTAssertFalse(ClipSignal.flag(.secret).matches(benign, now: now))
        XCTAssertFalse(ClipSignal.shape("json").matches(benign, now: now))
        XCTAssertFalse(ClipSignal.source("Safari").matches(benign, now: now))
        XCTAssertFalse(ClipSignal.lifecycle("sticky").matches(benign, now: now))
        XCTAssertFalse(ClipSignal.userTag("work").matches(benign, now: now))
    }

    func testLifecycleSignalMatchesEitherBehaviouralAxis() {
        let sticky = clip(pinned: true)
        XCTAssertTrue(ClipSignal.lifecycle("sticky").matches(sticky, now: now))
        let toOpen = clip(kind: .link, text: "https://example.com/x", ageSeconds: 60, useCount: 0)
        XCTAssertTrue(ClipSignal.lifecycle("to-open").matches(toOpen, now: now))
    }

    /// Facet semantics, matching the tag-dimension menu: values in one group OR,
    /// groups AND.
    @MainActor
    func testFilterGroupsOrWithinAndAcrossGroups() {
        let filter = SignalFilterModel()
        let secretFromSafari = clip(sourceApp: "Safari", flags: [.secret])
        let financialFromSafari = clip(sourceApp: "Safari", flags: [.financial])
        let secretFromXcode = clip(sourceApp: "Xcode", flags: [.secret])

        // Empty filter shows everything.
        XCTAssertTrue(filter.matches(secretFromSafari, now: now))

        filter.toggle(.flag(.secret))
        filter.toggle(.flag(.financial))
        XCTAssertTrue(filter.matches(secretFromSafari, now: now))
        XCTAssertTrue(filter.matches(financialFromSafari, now: now))   // OR within a group
        XCTAssertFalse(filter.matches(clip(), now: now))

        filter.toggle(.source("Safari"))
        XCTAssertTrue(filter.matches(secretFromSafari, now: now))
        XCTAssertFalse(filter.matches(secretFromXcode, now: now))      // AND across groups

        filter.toggle(.source("Safari"))
        XCTAssertTrue(filter.matches(secretFromXcode, now: now))       // toggles off again
    }
}
