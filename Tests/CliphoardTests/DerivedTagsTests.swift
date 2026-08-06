import XCTest
@testable import Cliphoard

/// Tier-2 derived tags (spec §3.5–3.7).
///
/// Every age-sensitive assertion injects `now` so the suite never touches
/// wall-clock — a test that sleeps or races midnight is a test that will
/// eventually lie. The important assertions here are the *negative* ones: the
/// spec's whole thesis is that a blank chip beats a coin-flip chip, so "returns
/// nil" is the behaviour most worth pinning.
final class DerivedTagsTests: XCTestCase {

    /// Fixed reference instant. All fixtures are expressed as an offset from it.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(kind: ClipKind = .text,
                      text: String = "hello",
                      ageSeconds: TimeInterval = 0,
                      useCount: Int = 0,
                      pinned: Bool = false,
                      sourceApp: String? = nil) -> ClipItem {
        let item = ClipItem(kind: kind, text: text)
        item.createdAt = now.addingTimeInterval(-ageSeconds)
        item.lastUsedAt = item.createdAt
        item.useCount = useCount
        item.pinned = pinned
        item.sourceApp = sourceApp
        return item
    }

    private let hour: TimeInterval = 60 * 60
    private let day: TimeInterval = 24 * 60 * 60

    // MARK: - 3.5 Source

    func testKnownBundleIdsMapToFriendlyNames() {
        let expected: [String: String] = [
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Chrome",
            "company.thebrowser.Browser": "Arc",
            "com.apple.dt.Xcode": "Xcode",
            "com.microsoft.VSCode": "VS Code",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.apple.MobileSMS": "Messages",
            "com.figma.Desktop": "Figma",
            "com.apple.Terminal": "Terminal",
            "com.googlecode.iterm2": "iTerm",
            "dev.warp.Warp": "Warp",
            "com.apple.Notes": "Notes",
            "md.obsidian": "Obsidian",
            "com.apple.mail": "Mail"
        ]
        for (bundleID, name) in expected {
            XCTAssertEqual(DerivedTags.source(clip(sourceApp: bundleID)), name, bundleID)
        }
    }

    /// Unknown ids must still show the origin — the §3.5 dissent is that the raw
    /// app name is always visible. They degrade, they do not disappear.
    func testUnknownBundleIdDegradesToCleanedName() {
        XCTAssertEqual(DerivedTags.source(clip(sourceApp: "com.acme.notepad")), "Notepad")
        XCTAssertEqual(DerivedTags.source(clip(sourceApp: "com.acme.MyApp")), "MyApp")
        XCTAssertEqual(DerivedTags.source(clip(sourceApp: "Preview")), "Preview")
    }

    func testMissingOrDegenerateSourceIsNil() {
        XCTAssertNil(DerivedTags.source(clip(sourceApp: nil)))
        XCTAssertNil(DerivedTags.source(clip(sourceApp: "   ")))
        XCTAssertNil(DerivedTags.source(clip(sourceApp: "...")))
    }

    /// `sourceApp` holds `NSWorkspace…localizedName`, so these — not bundle ids —
    /// are the real stored values (verified against the live store). A display
    /// name must survive VERBATIM: the old dot-split + force-uppercase rendered
    /// "iTerm2" as "ITerm2" on the one chip that shows for nearly every clip.
    func testDisplayNamesAreShownVerbatim() {
        for name in ["Google Chrome", "Code - Insiders", "iTerm2", "Ghostty", "ChatGPT"] {
            XCTAssertEqual(DerivedTags.source(clip(sourceApp: name)), name)
        }
        XCTAssertEqual(DerivedTags.source(clip(sourceApp: "\u{200E}WhatsApp")), "WhatsApp",
                       "invisible bidi marks are stripped, not rendered")
    }

    func testRolesResolveFromDisplayNamesToo() {
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "Ghostty")), "shell")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "Google Chrome")), "web")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "Code - Insiders")), "code")
        XCTAssertNil(DerivedTags.role(clip(sourceApp: "Some Unknown App")))
    }

    func testRoleBucketsAreConvenienceOnlyAndOptional() {
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "com.apple.Safari")), "web")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "com.googlecode.iterm2")), "shell")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "com.microsoft.VSCode")), "code")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "com.tinyspeck.slackmacgap")), "chat")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "md.obsidian")), "notes")
        XCTAssertEqual(DerivedTags.role(clip(sourceApp: "com.apple.mail")), "mail")

        // Figma fits no honest bucket, and an unknown app must not be guessed at.
        XCTAssertNil(DerivedTags.role(clip(sourceApp: "com.figma.Desktop")))
        XCTAssertNil(DerivedTags.role(clip(sourceApp: "com.acme.notepad")))
        XCTAssertNil(DerivedTags.role(clip(sourceApp: nil)))
    }

    // MARK: - 3.6 Lifecycle

    func testStickyOnPinnedOrRepeatedUse() {
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: 5 * day, pinned: true), now: now), "sticky")
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: 5 * day, useCount: 3), now: now), "sticky")
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: 5 * day, useCount: 40), now: now), "sticky")
    }

    /// A pinned but ancient, never-pasted clip is sticky, never throwaway — the
    /// destructive tag must not out-rank an explicit user signal.
    func testPinnedNeverBecomesThrowaway() {
        let ancient = clip(ageSeconds: 400 * day, useCount: 0, pinned: true)
        XCTAssertEqual(DerivedTags.lifecycle(ancient, now: now), "sticky")
    }

    func testThrowawayAndFreshExtremes() {
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: 30 * day), now: now), "throwaway")
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: 60), now: now), "fresh")
    }

    /// The headline behaviour: **blank the ambiguous middle**. A three-day-old
    /// clip pasted once is neither sticky nor throwaway nor fresh, and the spec
    /// says guessing there is worse than saying nothing.
    func testAmbiguousMiddleReturnsNil() {
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: 3 * day, useCount: 1), now: now))
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: 3 * day, useCount: 0), now: now))
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: 2 * hour, useCount: 1), now: now))
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: 30 * day, useCount: 1), now: now))
    }

    /// Boundaries are strict inequalities on both sides, so the exact threshold
    /// instant is blank rather than arbitrarily assigned.
    func testLifecycleBoundariesAreBlank() {
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: hour), now: now))
        XCTAssertNil(DerivedTags.lifecycle(clip(ageSeconds: 14 * day), now: now))
    }

    /// A clip whose `createdAt` is in the future (clock change, restored backup)
    /// must read as fresh, and above all must not fall into `throwaway`.
    func testFutureTimestampIsClampedNotThrowaway() {
        XCTAssertEqual(DerivedTags.lifecycle(clip(ageSeconds: -10 * day), now: now), "fresh")
    }

    func testLifecycleEmitsAtMostOneValue() {
        let values = [
            DerivedTags.lifecycle(clip(ageSeconds: 60), now: now),
            DerivedTags.lifecycle(clip(ageSeconds: 30 * day), now: now),
            DerivedTags.lifecycle(clip(pinned: true), now: now)
        ]
        // Each call yields a single optional; assert the vocabulary is closed so
        // no actionless value (the dropped "prose"/"one-shot"/"today") sneaks in.
        for value in values.compactMap({ $0 }) {
            XCTAssertTrue(["sticky", "throwaway", "fresh"].contains(value), value)
        }
    }

    // MARK: - 3.7 Link disposition

    func testDispositionOnlyEverFiresForLinks() {
        for kind in ClipKind.allCases where kind != .link {
            let item = clip(kind: kind, text: "https://arxiv.org/abs/2401.00001", ageSeconds: 60)
            XCTAssertNil(DerivedTags.linkDisposition(item, now: now), "\(kind) must have no disposition")
        }
    }

    func testReferenceHosts() {
        let hosts = [
            "https://doi.org/10.1038/nature12373",
            "https://arxiv.org/abs/2401.00001",
            "https://www.arxiv.org/abs/2401.00001",
            "https://pubmed.ncbi.nlm.nih.gov/31178118/",
            "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC1234567/",
            "https://scholar.google.com/citations?user=abc",
            "https://scholar.google.de/citations?user=abc",
            "arxiv.org/abs/2401.00001"
        ]
        for url in hosts {
            let item = clip(kind: .link, text: url, ageSeconds: 5 * day, useCount: 7)
            XCTAssertEqual(DerivedTags.linkDisposition(item, now: now), "reference", url)
        }
    }

    /// Label-boundary matching: a lookalike host must not inherit `reference`.
    func testReferenceHostLookalikeIsRejected() {
        let item = clip(kind: .link, text: "https://arxiv.org.phishing.example/paper", ageSeconds: 5 * day, useCount: 2)
        XCTAssertNil(DerivedTags.linkDisposition(item, now: now))
    }

    func testDOIAndISBNPatternsInText() {
        let doi = clip(kind: .link, text: "https://journals.example.com/doi/10.1016/j.cell.2020.01.021",
                       ageSeconds: 9 * day, useCount: 4)
        XCTAssertEqual(DerivedTags.linkDisposition(doi, now: now), "reference")

        let isbn13 = clip(kind: .link, text: "https://books.example.com/b?ISBN-13: 978-3-16-148410-0",
                          ageSeconds: 9 * day, useCount: 4)
        XCTAssertEqual(DerivedTags.linkDisposition(isbn13, now: now), "reference")

        let isbn10 = clip(kind: .link, text: "https://books.example.com/b?isbn 0-306-40615-2",
                          ageSeconds: 9 * day, useCount: 4)
        XCTAssertEqual(DerivedTags.linkDisposition(isbn10, now: now), "reference")
    }

    /// A version-ish "10.xxxx/" fragment without a word boundary, and a bare
    /// 13-digit run with no ISBN marker, must not manufacture a `reference`.
    func testReferencePatternsDoNotOverfire() {
        let versionish = clip(kind: .link, text: "https://cdn.example.com/v3210.1234/bundle.js",
                              ageSeconds: 9 * day, useCount: 2)
        XCTAssertNil(DerivedTags.linkDisposition(versionish, now: now))

        let orderNumber = clip(kind: .link, text: "https://shop.example.com/order/9783161484100",
                               ageSeconds: 9 * day, useCount: 2)
        XCTAssertNil(DerivedTags.linkDisposition(orderNumber, now: now))
    }

    func testToOpenAndReadLater() {
        let fresh = clip(kind: .link, text: "https://example.com/post", ageSeconds: 10 * 60)
        XCTAssertEqual(DerivedTags.linkDisposition(fresh, now: now), "to-open")

        let stale = clip(kind: .link, text: "https://example.com/post", ageSeconds: 3 * day)
        XCTAssertEqual(DerivedTags.linkDisposition(stale, now: now), "read-later")
    }

    /// Spec §3.7, explicitly: `useCount == 1` is blank. Once-opened is neither a
    /// pending action nor a habit.
    func testUseCountOneLinkIsBlank() {
        for age in [10 * 60, Int(3 * day), Int(30 * day)] {
            let item = clip(kind: .link, text: "https://example.com/post",
                            ageSeconds: TimeInterval(age), useCount: 1)
            XCTAssertNil(DerivedTags.linkDisposition(item, now: now), "age \(age)")
        }
    }

    func testDispositionVocabularyIsClosed() {
        let samples = [
            clip(kind: .link, text: "https://doi.org/10.1038/nature12373", ageSeconds: 60),
            clip(kind: .link, text: "https://example.com/a", ageSeconds: 60),
            clip(kind: .link, text: "https://example.com/b", ageSeconds: 5 * day)
        ]
        for item in samples {
            guard let value = DerivedTags.linkDisposition(item, now: now) else {
                return XCTFail("expected a disposition for \(item.text)")
            }
            XCTAssertTrue(["reference", "to-open", "read-later"].contains(value), value)
        }
    }

    // MARK: - Combined

    func testAllIsCertaintyOrdered() {
        let item = clip(kind: .link, text: "https://doi.org/10.1038/nature12373",
                        ageSeconds: 30 * day, useCount: 0, pinned: false,
                        sourceApp: "com.apple.Safari")
        XCTAssertEqual(DerivedTags.all(item, now: now), ["Safari", "reference", "throwaway"])
    }

    /// Principle 6: never more than three chips, even when every derived source
    /// has an opinion.
    func testAllCapsAtThree() {
        let item = clip(kind: .link, text: "https://arxiv.org/abs/2401.00001",
                        ageSeconds: 60, useCount: 0, pinned: true,
                        sourceApp: "com.google.Chrome")
        let tags = DerivedTags.all(item, now: now)
        XCTAssertLessThanOrEqual(tags.count, DerivedTags.Thresholds.maxTags)
        XCTAssertEqual(tags, ["Chrome", "reference", "sticky"])
    }

    /// The common case: a clip in the ambiguous middle from an unrecorded app
    /// gets no chips at all. Blank is a valid, expected outcome.
    func testAllCanBeEmpty() {
        let item = clip(kind: .text, text: "some notes", ageSeconds: 3 * day, useCount: 1)
        XCTAssertEqual(DerivedTags.all(item, now: now), [])
    }

    func testAllOmitsRoleToAvoidRestatingSource() {
        let item = clip(kind: .text, text: "x", ageSeconds: 3 * day, useCount: 1,
                        sourceApp: "com.apple.Safari")
        XCTAssertEqual(DerivedTags.all(item, now: now), ["Safari"])
        XCTAssertFalse(DerivedTags.all(item, now: now).contains("web"))
    }
}
