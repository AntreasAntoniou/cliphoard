import Foundation

/// Tier-2 tags: **metadata & behaviour** (spec §3.5–3.7).
///
/// These are the tags the audit says we can actually trust. Tier 4 (embedding
/// topics) coin-flipped on real clips — margins of 0.03–0.04 between the top two
/// candidates — because it asked a model to guess something the clip never
/// encoded. Tier 2 asks nothing: `sourceApp`, `createdAt`, `useCount` and
/// `pinned` are *recorded facts*, so a tag derived from them is exact, free, and
/// survives any model or vocabulary switch.
///
/// Three properties are deliberate and load-bearing:
///
/// 1. **Pure.** Every function here is a static function of a `ClipItem` (plus an
///    injectable `now`). No store, no model, no I/O, no UI, and — critically —
///    **zero embedding calls**. That is what makes them safe to evaluate at
///    render time for every visible row, and unit-testable without a store.
/// 2. **Derived, never persisted.** Nothing here needs a migration or a column.
///    A clip's lifecycle changes as it ages and gets pasted; recomputing is
///    cheaper and more honest than storing a stale answer (spec §5).
/// 3. **Confident-or-blank** (principle 2). `nil` is not a failure mode, it is the
///    *common, correct* outcome. The audit's lesson is that a forced label with a
///    0.04 margin is worse than no label, so the ambiguous middle stays empty.
///
/// Principle 4 gates the vocabulary: every value returned below maps to exactly
/// one glance-action, documented at its definition. Values with no action (the
/// old `prose`, `one-shot`, a standalone "today" chip) are not emitted — and must
/// not be added later without an action to justify them.
///
/// Concurrency: this is a caseless `enum` with no stored state. All tables are
/// immutable `let`s of value types, so the whole surface is trivially
/// `Sendable`-safe and callable from any isolation domain.
enum DerivedTags {

    // MARK: - Thresholds

    /// Every numeric knob in this file, in one place.
    ///
    /// The spec marks these explicitly as **placeholders to be calibrated**
    /// against the real `useCount`/age distribution — the 202-clip audit told us
    /// the *shape* of the signal (extremes are trustworthy, the middle is not)
    /// but not the exact cut points. Naming them here means calibration is a
    /// one-line edit plus a test update, not a hunt through predicates.
    struct Thresholds {
        /// Pastes at which a clip is treated as part of the working set.
        /// Rationale: a clip pasted three times is being *used*, not parked.
        static let stickyUseCount = 3

        /// Age beyond which an unused, unpinned clip is offerable for deletion.
        /// Spec suggests 7–14 days; we take the conservative end, because the
        /// action attached to `throwaway` is destructive.
        static let throwawayAge: TimeInterval = 14 * 24 * 60 * 60

        /// Age within which a never-pasted clip is still "the thing I just
        /// copied". Doubles as the link `to-open` window — spec §3.6 and §3.7
        /// use the same hour, so they share one constant on purpose.
        static let freshAge: TimeInterval = 60 * 60

        /// Hard cap on derived chips per clip (principle 6: ≤2–3 tags, ordered
        /// by certainty). Enforced in ``DerivedTags/all(_:now:)`` rather than
        /// left to the call site, so no view can accidentally render four.
        static let maxTags = 3

        private init() {}
    }

    // MARK: - 3.5 Source / Provenance

    /// Bundle id → friendly app name.
    ///
    /// Kept as an exact-match table rather than a fuzzy rule because provenance
    /// is one of the few *certain* signals we have; guessing would throw that
    /// away. Unknown ids are not dropped — they degrade to a cleaned raw name
    /// (see ``cleanedName(from:)``), because the dissent recorded in §3.5 is
    /// that the raw origin must *always* be visible.
    private static let friendlyAppNames: [String: String] = [
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

    /// Bundle id → coarse role bucket.
    ///
    /// Convenience only. §3.5 carries an explicit dissent: *always show the raw
    /// app name*; the role is a secondary affordance for grouping ("everything I
    /// copied out of a terminal"), never a replacement for the origin. It is
    /// therefore deliberately **absent from** ``all(_:now:)`` — showing both
    /// "Safari" and "web" spends two of three chip slots on one fact.
    ///
    /// Apps with no honest bucket (Figma is neither web nor code nor notes) map
    /// to nothing rather than being forced into the nearest one — same
    /// confident-or-blank rule as everywhere else.
    private static let appRoles: [String: String] = [
        "com.apple.Safari": "web",
        "com.google.Chrome": "web",
        "company.thebrowser.Browser": "web",
        "com.apple.Terminal": "shell",
        "com.googlecode.iterm2": "shell",
        "dev.warp.Warp": "shell",
        "com.apple.dt.Xcode": "code",
        "com.microsoft.VSCode": "code",
        "com.tinyspeck.slackmacgap": "chat",
        "com.apple.MobileSMS": "chat",
        "com.apple.Notes": "notes",
        "md.obsidian": "notes",
        "com.apple.mail": "mail"
    ]

    /// The friendly name of the app a clip came from, or `nil` when the origin
    /// was never recorded (older clips, or a capture path that had no frontmost
    /// app).
    ///
    /// **Glance-action:** one tap filters history to that origin.
    ///
    /// Unknown bundle ids degrade gracefully instead of vanishing: the last
    /// dot-component is cleaned up and capitalised, so `com.acme.notepad`
    /// renders as "Notepad". A non-bundle-id string (some capture paths record a
    /// plain app name) passes through essentially unchanged.
    static func source(_ item: ClipItem) -> String? {
        guard let rawIn = item.sourceApp else { return nil }
        let raw = stripInvisibles(rawIn)
        guard !raw.isEmpty else { return nil }
        // Bundle-id table first (works if the monitor ever records one), then the
        // display name the monitor actually stores today.
        if let friendly = friendlyAppNames[raw] { return friendly }
        return cleanedName(from: raw)
    }

    /// The optional role bucket (`web`/`shell`/`code`/`chat`/`notes`/`mail`) for
    /// a clip's origin, or `nil` when the app is unknown or fits no bucket.
    ///
    /// **Glance-action:** filters history to a family of origins.
    ///
    /// Only exact, known bundle ids get a role. Inferring a role from an unknown
    /// id would be exactly the forced-argmax mistake the audit killed.
    /// Display-name → role, since `sourceApp` holds a localized name in practice.
    /// Exact (lowercased) match only — guessing a role from an unknown app would
    /// be the forced-argmax mistake the audit killed.
    private static let roleByDisplayName: [String: String] = [
        "safari": "web", "google chrome": "web", "chrome": "web", "arc": "web",
        "vivaldi": "web", "firefox": "web", "brave browser": "web",
        "terminal": "shell", "iterm2": "shell", "ghostty": "shell", "warp": "shell",
        "xcode": "code", "code": "code", "visual studio code": "code",
        "code - insiders": "code", "cursor": "code",
        "slack": "chat", "messages": "chat", "whatsapp": "chat",
        "telegram": "chat", "discord": "chat",
        "notes": "notes", "obsidian": "notes", "bear": "notes",
        "mail": "mail", "spark": "mail", "outlook": "mail",
    ]

    static func role(_ item: ClipItem) -> String? {
        guard let rawIn = item.sourceApp else { return nil }
        let raw = stripInvisibles(rawIn)
        guard !raw.isEmpty else { return nil }
        return appRoles[raw] ?? roleByDisplayName[raw.lowercased()]
    }

    /// Best-effort human name for an unrecognised app identifier.
    ///
    /// Takes the last non-empty dot-component (`com.acme.notepad` → `notepad`)
    /// and upper-cases the first character only — the rest is left alone so an
    /// already-camel-cased id (`com.acme.MyApp`) is not mangled into `Myapp`.
    /// Returns `nil` for degenerate input (all dots/whitespace) rather than an
    /// empty chip.
    /// Strip invisible bidi/format marks. Real clipboard data contains them —
    /// this store holds "\u{200E}WhatsApp" — and they render as a stray glyph and
    /// break exact matching.
    static func stripInvisibles(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !(0x200B...0x200F).contains($0.value) && $0.value != 0xFEFF
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turn a raw `sourceApp` into something displayable.
    ///
    /// `ClipboardMonitor` records `localizedName` — a DISPLAY name ("Google
    /// Chrome", "Code - Insiders", "iTerm2"), not a bundle id. Such a name is
    /// already correct and must be returned VERBATIM: the old dot-split +
    /// force-uppercase turned "iTerm2" into "ITerm2". Only a genuine
    /// bundle-id-looking string (dotted, no spaces) gets the last-component
    /// treatment, and even then its own capitalisation is preserved.
    private static func cleanedName(from identifier: String) -> String? {
        let raw = stripInvisibles(identifier)
        guard !raw.isEmpty else { return nil }
        let looksLikeBundleID = raw.contains(".") && !raw.contains(" ")
        guard looksLikeBundleID else { return raw }          // display name: verbatim
        // A dotted string with no usable component ("...") is degenerate, not a name.
        guard let last = raw.split(separator: ".", omittingEmptySubsequences: true).last,
              let first = last.first else { return nil }
        // Capitalising is safe HERE (bundle-id tail only) — it is what mangled
        // display names like "iTerm2" when it was applied to every input.
        return String(first).uppercased() + last.dropFirst()
    }

    // MARK: - 3.6 Reuse & Lifecycle

    /// A behavioural lifecycle tag, or `nil` — which is the usual answer.
    ///
    /// This replaces the semantic *Intent* axis outright. Intent scored a 0.04
    /// margin because intent is not in the text; it is in what the user
    /// subsequently *did*. Reuse and age measure that directly.
    ///
    /// Emits **at most one** of, in descending certainty:
    /// - `sticky` — pinned, or pasted ≥ ``Thresholds/stickyUseCount`` times.
    ///   **Glance-action:** keep/pin; never offer it for cleanup.
    /// - `throwaway` — older than ``Thresholds/throwawayAge``, never pasted, not
    ///   pinned. **Glance-action:** one-tap delete / bulk sweep candidate.
    /// - `fresh` — younger than ``Thresholds/freshAge`` and never pasted.
    ///   **Glance-action:** paste it; it is almost certainly what you are
    ///   reaching for.
    ///
    /// Everything else — the three-day-old clip pasted once, the week-old clip
    /// pasted twice — returns `nil` **on purpose**. That middle band is where a
    /// guess would be a coin flip, and a wrong `throwaway` badge next to a delete
    /// affordance is actively dangerous.
    ///
    /// - Parameter now: injected so age is testable without wall-clock.
    static func lifecycle(_ item: ClipItem, now: Date = Date()) -> String? {
        // `sticky` is checked first and is the only tag that can fire on a used
        // or pinned clip, so the three outcomes are mutually exclusive by
        // construction rather than by careful threshold arithmetic.
        if item.pinned || item.useCount >= Thresholds.stickyUseCount { return "sticky" }

        let age = age(of: item, now: now)
        if age > Thresholds.throwawayAge && item.useCount == 0 && !item.pinned { return "throwaway" }
        if age < Thresholds.freshAge && item.useCount == 0 { return "fresh" }
        return nil
    }

    // MARK: - 3.7 Link disposition

    /// Hosts whose content is a citable reference rather than something to read
    /// once and discard. Matched on the host label boundary (see
    /// ``hostMatchesReference(_:)``) so `evil-arxiv.org.example.com` cannot
    /// impersonate one.
    private static let referenceHosts: [String] = [
        "doi.org",
        "arxiv.org",
        "pubmed.gov",
        "ncbi.nlm.nih.gov"
    ]

    /// What to do with a link, or `nil`. **Only ever fires for `kind == .link`** —
    /// spec §3.7 is explicit, and §6 pins it as a test.
    ///
    /// In descending certainty:
    /// - `reference` — a scholarly host (doi.org, arXiv, PubMed/NCBI, Google
    ///   Scholar) or a DOI/ISBN in the text. **Glance-action:** cite / send to a
    ///   reference manager. This one is deterministic pattern-matching, so it
    ///   outranks the age heuristics and is checked first.
    /// - `to-open` — younger than ``Thresholds/freshAge``, never used.
    ///   **Glance-action:** open it now.
    /// - `read-later` — never used, older than ``Thresholds/freshAge``.
    ///   **Glance-action:** send to a read-later queue.
    ///
    /// `useCount == 1` returns `nil` by design: a link opened exactly once is
    /// neither pending nor a habit, and the spec calls that out as blank.
    ///
    /// - Parameter now: injected so age is testable without wall-clock.
    static func linkDisposition(_ item: ClipItem, now: Date = Date()) -> String? {
        guard item.kind == .link else { return nil }

        if isReference(item.text) { return "reference" }

        // Both remaining buckets require an untouched link. A link the user has
        // already acted on carries no pending action, so there is nothing to
        // glance at.
        guard item.useCount == 0 else { return nil }

        let age = age(of: item, now: now)
        if age < Thresholds.freshAge { return "to-open" }
        if age > Thresholds.freshAge { return "read-later" }
        return nil
    }

    // MARK: - Combined

    /// The derived chips for a clip, ordered by certainty and capped at
    /// ``Thresholds/maxTags``.
    ///
    /// Order is **certainty-descending**, matching principle 1 (cheapest and
    /// surest first) and principle 6 (ordered by certainty):
    ///
    /// 1. `source` — an exact recorded fact; margin is effectively 1.0.
    /// 2. `linkDisposition` — gated on a `kind` we already trust, and its
    ///    strongest value (`reference`) is deterministic pattern matching.
    /// 3. `lifecycle` — real behaviour, but read through thresholds the spec
    ///    still marks as uncalibrated placeholders, so it yields last.
    ///
    /// `role` is intentionally excluded — it is a convenience filter, and
    /// spending a chip slot restating "Safari ⇒ web" buys the user nothing.
    ///
    /// - Parameter now: injected so age is testable without wall-clock.
    static func all(_ item: ClipItem, now: Date = Date()) -> [String] {
        let ordered: [String?] = [
            source(item),
            linkDisposition(item, now: now),
            lifecycle(item, now: now)
        ]
        return Array(ordered.compactMap { $0 }.prefix(Thresholds.maxTags))
    }

    // MARK: - Helpers

    /// Seconds between a clip's capture and `now`.
    ///
    /// Clamped at zero: a clip whose `createdAt` is in the future (clock change,
    /// a restored backup, a migrated row) should read as brand new, never as
    /// negatively aged, and must never fall into the `throwaway` branch by
    /// arithmetic accident.
    private static func age(of item: ClipItem, now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(item.createdAt))
    }

    /// Whether a link's text looks like a scholarly reference.
    ///
    /// Three independent signals, any of which is sufficient:
    /// host match, an embedded DOI, or an ISBN. Text is checked as well as the
    /// parsed host because clips are frequently pasted with surrounding
    /// punctuation or markdown that defeats `URL` parsing, and losing the tag to
    /// a stray bracket would be a silly failure.
    /// A known reference host is decisive. Otherwise a DOI/ISBN in the text still
    /// counts — publishers legitimately serve DOIs from their own domains
    /// (`journals.example.com/doi/10.1016/…`) — EXCEPT when the host is
    /// impersonating a reference host (`doi.org.evil.com`). There the path is
    /// attacker-chosen bait, and a chip whose glance-action is "go cite this"
    /// must not vouch for it.
    private static func isReference(_ text: String) -> Bool {
        if let host = host(of: text) {
            if hostMatchesReference(host) { return true }
            if hostImpersonatesReference(host) { return false }
        }
        return containsDOI(text) || containsISBN(text)
    }

    /// A host that embeds a reference host as a non-suffix label — i.e. it reads
    /// like `doi.org…` or `arxiv.org…` but is registered under someone else.
    private static func hostImpersonatesReference(_ host: String) -> Bool {
        for reference in referenceHosts where host.contains(reference) && !host.hasSuffix(reference) {
            return true
        }
        return host.contains("pubmed") || host.contains("scholar.google")
    }

    /// Lower-cased host of the first URL-ish token in `text`, or `nil`.
    ///
    /// Scheme-less input (`arxiv.org/abs/2401.00001`) is given an `https://`
    /// prefix purely so `URL` will parse a host out of it; the prefix is never
    /// shown or stored.
    private static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmed.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let candidate = token.contains("://") ? String(token) : "https://\(token)"
        guard let host = URL(string: candidate)?.host else { return nil }
        return host.lowercased()
    }

    /// Host matching on label boundaries, never bare substring containment.
    ///
    /// `arxiv.org` matches `arxiv.org` and `www.arxiv.org` but not
    /// `arxiv.org.phishing.example`. Google Scholar is handled separately
    /// because it exists under every ccTLD (`scholar.google.de`), so it is
    /// identified by its leading labels instead of a fixed suffix. PubMed is
    /// likewise matched as a label so both `pubmed.ncbi.nlm.nih.gov` and
    /// `pubmed.gov` are covered.
    private static func hostMatchesReference(_ host: String) -> Bool {
        for reference in referenceHosts where host == reference || host.hasSuffix("." + reference) {
            return true
        }
        if host == "scholar.google" || host.hasPrefix("scholar.google.") { return true }
        // Suffix match on label boundaries only. A bare `split.contains("pubmed")`
        // accepts `pubmed.evil.com` — a lookalike host must never earn a
        // "reference" chip whose glance-action is "cite this".
        return host == "pubmed.ncbi.nlm.nih.gov" || host.hasSuffix(".pubmed.ncbi.nlm.nih.gov")
            || host == "pubmed.gov" || host.hasSuffix(".pubmed.gov")
    }

    /// Detects a DOI: literal `10.`, at least four digits, a slash, then at least
    /// one non-space character (`10.1038/nature12373`).
    ///
    /// Hand-rolled rather than a regex so there is no shared `NSRegularExpression`
    /// instance to reason about across isolation domains, and no per-call pattern
    /// compilation on a render-time path.
    private static func containsDOI(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.count >= 8 else { return false }
        // Never read a DOI out of a URL QUERY STRING: a cache-buster like
        // "app.min.js?v=10.1234/x" satisfies every structural rule below, and
        // mislabelling a minified asset as a citable reference is exactly the
        // decorative-tag failure this design exists to avoid.
        let queryStart = chars.firstIndex(of: "?") ?? chars.count

        for start in 0..<(chars.count - 3) {
            guard start < queryStart else { break }
            guard chars[start] == "1", chars[start + 1] == "0", chars[start + 2] == "." else { continue }
            // Require a word boundary so "3210.1234/x" (a version string, a
            // truncated hash) does not read as a DOI. `=` and `&` are excluded
            // too — they only precede a value in a parameter list.
            if start > 0 {
                let previous = chars[start - 1]
                if previous.isNumber || previous.isLetter || previous == "=" || previous == "&" { continue }
            }

            var index = start + 3
            var digits = 0
            while index < chars.count, chars[index].isNumber {
                digits += 1
                index += 1
            }
            guard digits >= 4, index < chars.count, chars[index] == "/" else { continue }

            let suffix = index + 1
            if suffix < chars.count, !chars[suffix].isWhitespace { return true }
        }
        return false
    }

    /// Detects an ISBN: the marker `ISBN` (optionally `ISBN-10`/`ISBN-13`),
    /// then a hyphen/space-separated run of exactly 10 or 13 digits, with a
    /// trailing `X` permitted as the ISBN-10 check character.
    ///
    /// The marker is required. A bare 13-digit run is indistinguishable from an
    /// order number or a phone number, and guessing there would manufacture the
    /// same false confidence the audit condemned.
    private static func containsISBN(_ text: String) -> Bool {
        let lowered = Array(text.lowercased())
        let marker: [Character] = ["i", "s", "b", "n"]
        guard lowered.count > marker.count else { return false }

        for start in 0...(lowered.count - marker.count) {
            guard Array(lowered[start..<(start + marker.count)]) == marker else { continue }
            var index = start + marker.count

            // Optional "-10" / "-13" / " 13" variant label after the marker.
            var probe = index
            while probe < lowered.count, lowered[probe] == "-" || lowered[probe] == " " { probe += 1 }
            if probe + 1 < lowered.count,
               lowered[probe] == "1",
               lowered[probe + 1] == "0" || lowered[probe + 1] == "3" {
                index = probe + 2
            }

            // Separators between the marker and the number itself.
            while index < lowered.count,
                  lowered[index] == "-" || lowered[index] == " " || lowered[index] == ":" {
                index += 1
            }

            var digits = 0
            var sawTerminalX = false
            loop: while index < lowered.count {
                let character = lowered[index]
                switch character {
                case "0"..."9":
                    digits += 1
                    index += 1
                case "-", " ":
                    index += 1
                case "x":
                    // Only valid as the tenth (check) character of an ISBN-10.
                    if digits == 9 {
                        digits += 1
                        sawTerminalX = true
                    }
                    break loop
                default:
                    break loop
                }
                if digits > 13 { break loop }
            }

            if digits == 10 || (digits == 13 && !sawTerminalX) { return true }
        }
        return false
    }
}
