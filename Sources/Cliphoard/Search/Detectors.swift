import Foundation
import CryptoKit

// MARK: - Flags

/// The Tier-1 detector verdict for one clip, persisted as a single INTEGER
/// column (see design §5: "a compact flag set on the clip … persisted as an
/// INTEGER column").
///
/// **Presence-only, fail-closed (design principle 3).** Every member of this set
/// is a *protective* signal. There is deliberately **no** `safe`, `public`,
/// `clean` or `benign` member and no way to synthesise one: an empty set means
/// "nothing fired", which is *not* the same claim as "this is safe". No detector
/// can prove safety, so the API refuses to let a caller say it. `DetectorTests`
/// asserts this invariant so a future edit cannot quietly add a positive label.
///
/// **Bit stability contract.** These raw bits go to disk. A bit's meaning may
/// never be reused or renumbered — retiring a flag means retiring its bit
/// forever and appending the replacement at the next free position. Unknown
/// (future) bits decoded from an older build must be preserved, not stripped,
/// which is why the underlying storage is the full `Int` rather than an enum.
///
/// | bit | value | member          | meaning                                        |
/// |----:|------:|-----------------|------------------------------------------------|
/// |   0 |     1 | `secret`        | Tier-1 zero-FP credential signature (§3.1)     |
/// |   1 |     2 | `secretEntropy` | Tier-2 generic high-entropy blob — *low confidence* (§3.1) |
/// |   2 |     4 | `financial`     | Card / IBAN / routing / crypto address (§3.2)  |
/// |   3 |     8 | `pii`           | Email or phone — *informational only* (§3.3)   |
/// |   4 |    16 | `piiSensitive`  | National-id or postal address (§3.3)           |
/// |   5 |    32 | `otp`           | One-time code / magic link (§3.8)              |
/// |   6 |    64 | `quarantined`   | Copied from a denylisted password app (§3.9)   |
struct ClipFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// A credential matched a Tier-1 *zero-false-positive* signature (a PEM
    /// private-key header, a vendor-prefixed token, or a JWT). High confidence:
    /// a caller may take destructive action (mask, refuse to index, drop).
    static let secret = ClipFlags(rawValue: 1 << 0)

    /// A single token cleared the Tier-2 *generic entropy* gate. Deliberately a
    /// **separate bit** from `secret` because design §3.1 requires that until the
    /// heuristic clears an FP audit on the real corpus "it may flag but must not
    /// drive a destructive action". Render it as a soft hint; never auto-delete,
    /// auto-mask-forever, or veto persistence on this bit alone.
    static let secretEntropy = ClipFlags(rawValue: 1 << 1)

    /// A validated financial identifier: card (Luhn **and** IIN), IBAN (mod-97),
    /// ABA routing (3-7-1 mod-10), or a crypto address (bech32/base58check/EIP-55).
    static let financial = ClipFlags(rawValue: 1 << 2)

    /// Email address or phone number. **Informational badge only** (§3.3): these
    /// are copied precisely in order to be pasted, so they get no mask, no TTL
    /// and no index exclusion. Splitting them from `piiSensitive` is what stops
    /// tap-through alarm fatigue.
    static let pii = ClipFlags(rawValue: 1 << 3)

    /// National-identifier-shaped value or a postal address. Rare by design, and
    /// the only PII tier that earns protective treatment (mask + caution).
    static let piiSensitive = ClipFlags(rawValue: 1 << 4)

    /// A one-time passcode or a login/verify/magic link (§3.8).
    static let otp = ClipFlags(rawValue: 1 << 5)

    /// The clip came from a sensitive source (§3.9) — a password manager on the
    /// exact-match denylist. Origin-based, never probabilistic.
    static let quarantined = ClipFlags(rawValue: 1 << 6)

    /// Every flag this build knows about, with its stable wire name.
    ///
    /// Exposed (rather than hidden) so tests can enumerate the vocabulary and
    /// assert the no-positive-label invariant — Swift has no reflection over
    /// static members, so the inventory has to be explicit.
    static let allKnown: [(name: String, flag: ClipFlags)] = [
        ("secret", .secret),
        ("secret-entropy", .secretEntropy),
        ("financial", .financial),
        ("pii", .pii),
        ("pii-sensitive", .piiSensitive),
        ("otp", .otp),
        ("quarantined", .quarantined),
    ]

    /// The wire names of the flags actually set, in bit order. Empty set → `[]`,
    /// which renders as *no badge* — never as a reassuring one.
    var names: [String] { Self.allKnown.filter { contains($0.flag) }.map(\.name) }

    /// True when any *protective* signal fired. Note the deliberate absence of an
    /// `isSafe` counterpart: `!isSensitive` means "nothing fired", not "safe".
    var isSensitive: Bool { !isEmpty }
}

// MARK: - Detectors

/// Tier-1 of the tag pipeline (design §3.1–3.4, §3.8, §3.9): a **pure**,
/// synchronous, sub-millisecond pass over a clip's text.
///
/// Purity is the point. There is no store, no model, no I/O and no UI here, so
/// `ClipStore.add` can run this *before* the CoreML embed and *before* the
/// SQLite write (§5) — which is what lets a detector veto indexing or
/// persistence of a secret, and what makes every rule unit-testable without a
/// database.
///
/// **Precedence (§2.1: cheapest-and-surest first).** `scan` evaluates in this
/// fixed order, and every stage only ever *adds* bits:
///
/// 1. `quarantined` — origin (free, exact, cannot be fooled by content)
/// 2. `secret` — Tier-1 signatures
/// 3. `secretEntropy` — Tier-2 generic entropy (low confidence, own bit)
/// 4. `financial` — checksum-validated identifiers
/// 5. `pii` / `piiSensitive` — severity-split identity
/// 6. `otp` — one-time codes
/// 7. `shape` — structure, **`kind == .text` only**
///
/// Shape runs **last, after every sensitive detector**, because it is cosmetic:
/// a secret that also happens to look like a `value` is a secret first. The
/// ordering is one-directional — shape never clears a flag, and a flag never
/// suppresses a shape, so the UI is free to render the badge and the shape chip
/// together with the badge taking visual precedence.
///
/// All state is `let`; there is no shared mutable state, so the type is trivially
/// concurrency-safe and every entry point is a pure static function.
enum Detectors {

    // MARK: Entry point

    /// Run the whole Tier-1 pass.
    ///
    /// - Parameters:
    ///   - text: the clip's plaintext. Untrusted; may be empty, huge, or
    ///     non-ASCII. Nothing here force-unwraps or indexes without bounds.
    ///   - kind: the clip kind. Only `.text` is eligible for a shape (§3.4).
    ///   - sourceApp: the frontmost app's **bundle identifier** at copy time,
    ///     matched exactly against the denylist (§3.9). Pass `nil` when unknown.
    /// - Returns: the accumulated flags and an optional shape value. A `nil`
    ///   shape is the common, expected outcome (§2.2 "blank is a valid result";
    ///   §3.4 "default/prose → BLANK").
    static func scan(text: String, kind: ClipKind, sourceApp: String?) -> (flags: ClipFlags, shape: String?) {
        var flags: ClipFlags = []

        // 1. Origin. Cheapest and surest: a byte-perfect bundle-id match.
        if isSensitiveSource(sourceApp) { flags.insert(.quarantined) }

        // Everything below is content-driven. Bail out early on empty input so a
        // blank clip cannot trip a boundary condition in any scanner.
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return (flags, nil) }

        let lowered = asciiLowercased(bytes)
        let tokens = whitespaceTokens(bytes)

        // 2 & 3. Credentials.
        let secrets = scanSecrets(bytes: bytes, lowered: lowered, tokens: tokens)
        flags.formUnion(secrets)

        // 4. Financial. Returns the byte ranges it consumed so the phone rule
        //    below cannot re-count a card or an IBAN as a phone number.
        let financial = scanFinancial(bytes: bytes, tokens: tokens)
        flags.formUnion(financial.flags)

        // 5. Identity, severity-split.
        flags.formUnion(scanPII(bytes: bytes, lowered: lowered, tokens: tokens,
                                consumed: financial.consumed))

        // 6. One-time codes.
        if detectOTP(bytes: bytes, lowered: lowered) { flags.insert(.otp) }

        // 7. Structure — last, and text-only.
        let shapeValue = shape(of: text, kind: kind)

        return (flags, shapeValue)
    }

    // MARK: - 3.9 Sensitive-source quarantine

    /// Bundle identifiers whose clipboard output is treated as sensitive on sight.
    ///
    /// Bundle ids only, and matched **exactly** — never a prefix, never a fuzzy
    /// or case-insensitive comparison (§3.9: "Exact match, never probabilistic").
    /// A fuzzy rule here would be a trivial spoof target: any app could name
    /// itself `1Password Helper` to *avoid* the net, or a legitimate app could be
    /// quarantined forever because its name contains "keychain".
    ///
    /// The list is intentionally short and user-editable; callers pass their own
    /// via `denylist:` once the setting exists.
    static let defaultSensitiveSourceDenylist: Set<String> = [
        // 1Password (v7 legacy, v8 desktop, browser helper)
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.1password.browser-support",
        // Bitwarden
        "com.bitwarden.desktop",
        // KeePassXC
        "org.keepassxc.keepassxc",
        // Apple Passwords / Keychain Access
        "com.apple.Passwords",
        "com.apple.PasswordManager",
        "com.apple.keychainaccess",
    ]

    /// Display names of the same denylisted apps.
    ///
    /// `ClipboardMonitor` records `NSWorkspace.frontmostApplication?.localizedName`
    /// — a DISPLAY NAME ("1Password", "Google Chrome"), never a bundle id. Matching
    /// bundle ids alone therefore never fired in production, silently disabling the
    /// §3.9 quarantine: exactly the kind of dead safety net that looks implemented.
    /// Both forms are accepted so the rule works today and keeps working when the
    /// monitor also records a bundle id.
    static let defaultSensitiveSourceNames: Set<String> = [
        "1password", "1password 7", "1password 8",
        "bitwarden", "keepassxc", "keepass", "dashlane", "lastpass",
        "passwords", "keychain access", "secretive", "enpass", "strongbox",
    ]

    /// Fold an app identifier for comparison: strip invisible bidi/format marks
    /// (real clipboard data contains e.g. "\u{200E}WhatsApp"), trim, lowercase.
    static func normalizedAppIdentifier(_ raw: String) -> String {
        raw.unicodeScalars
            .filter { !(0x200B...0x200F).contains($0.value) && $0.value != 0xFEFF }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Whether a clip's originating app is on the sensitive-source denylist.
    ///
    /// Accepts EITHER a bundle identifier or a localized display name — see
    /// `defaultSensitiveSourceNames`. Exact (normalized) match only, never fuzzy:
    /// an origin rule that guessed would be worse than none.
    static func isSensitiveSource(_ appIdentifier: String?,
                                  denylist: Set<String> = defaultSensitiveSourceDenylist,
                                  nameDenylist: Set<String> = defaultSensitiveSourceNames) -> Bool {
        guard let appIdentifier, !appIdentifier.isEmpty else { return false }
        if denylist.contains(appIdentifier) { return true }
        let folded = normalizedAppIdentifier(appIdentifier)
        return denylist.contains(where: { $0.lowercased() == folded }) || nameDenylist.contains(folded)
    }

    // MARK: - 3.1 Secret / credential

    /// Tier-1 vendor signatures. Each is `(prefix, minimum trailing length,
    /// allowed trailing charset)` and only ever matches at a **token start**, so
    /// `sk-` cannot fire on `ask-me-later`.
    private struct VendorSignature {
        let prefix: [UInt8]
        let minTail: Int
        let tail: CharsetMask
    }

    private static let vendorSignatures: [VendorSignature] = [
        // AWS access key id: AKIA + 16 uppercase alnum.
        VendorSignature(prefix: Array("AKIA".utf8), minTail: 16, tail: .upperDigit),
        // GitHub tokens: ghp_ / gho_ / ghu_ / ghs_ / ghr_ + >=20 alnum.
        VendorSignature(prefix: Array("ghp_".utf8), minTail: 20, tail: .alnumUnderscore),
        VendorSignature(prefix: Array("gho_".utf8), minTail: 20, tail: .alnumUnderscore),
        VendorSignature(prefix: Array("ghu_".utf8), minTail: 20, tail: .alnumUnderscore),
        VendorSignature(prefix: Array("ghs_".utf8), minTail: 20, tail: .alnumUnderscore),
        VendorSignature(prefix: Array("ghr_".utf8), minTail: 20, tail: .alnumUnderscore),
        // Slack tokens: xoxb-/xoxa-/xoxp-/xoxr-/xoxs- + >=10 of [0-9A-Za-z-].
        VendorSignature(prefix: Array("xoxb-".utf8), minTail: 10, tail: .alnumDash),
        VendorSignature(prefix: Array("xoxa-".utf8), minTail: 10, tail: .alnumDash),
        VendorSignature(prefix: Array("xoxp-".utf8), minTail: 10, tail: .alnumDash),
        VendorSignature(prefix: Array("xoxr-".utf8), minTail: 10, tail: .alnumDash),
        VendorSignature(prefix: Array("xoxs-".utf8), minTail: 10, tail: .alnumDash),
        // Stripe live secret key.
        VendorSignature(prefix: Array("sk_live_".utf8), minTail: 16, tail: .alnumUnderscore),
        // Google API key: AIza + 35 of [0-9A-Za-z_-].
        VendorSignature(prefix: Array("AIza".utf8), minTail: 35, tail: .alnumDashUnderscore),
        // OpenAI-style key: sk- + >=20. Listed last so the longer `sk_live_`
        // never has to fight it; the two prefixes are disjoint anyway.
        VendorSignature(prefix: Array("sk-".utf8), minTail: 20, tail: .alnumDashUnderscore),
    ]

    /// Characters a credential is *allowed* to contain. Anything outside this set
    /// in a Tier-2 candidate (braces, semicolons, quotes, commas) means the token
    /// is code or punctuation, not a key.
    private static let credentialCharset: CharsetMask = .credential

    /// §3.1 — credential detection.
    ///
    /// Returns `.secret` for Tier-1 signatures (zero false positives by
    /// construction: each one is a registered vendor prefix, a PEM armour header,
    /// or a structurally complete JWT) and the *separate* `.secretEntropy` bit
    /// for the hard-gated generic heuristic.
    static func scanSecrets(bytes: [UInt8], lowered: [UInt8], tokens: [Range<Int>]) -> ClipFlags {
        var flags: ClipFlags = []

        // -- PEM armour. The header alone is decisive; no key material needed.
        if contains(lowered, pattern: Array("-----begin".utf8)),
           contains(lowered, pattern: Array("private key-----".utf8)) {
            flags.insert(.secret)
        }

        var tier1Tokens = Set<Int>()

        for (index, range) in tokens.enumerated() {
            let token = bytes[range]

            if matchesVendorSignature(token) || isJWT(token) {
                flags.insert(.secret)
                tier1Tokens.insert(index)
            }
        }

        // -- Tier-2: generic entropy. Only consulted for tokens that did NOT
        //    already match Tier-1, so the low-confidence bit never piggybacks on
        //    a high-confidence hit and muddles what a caller is allowed to do.
        for (index, range) in tokens.enumerated() where !tier1Tokens.contains(index) {
            if isHighEntropySecretCandidate(bytes[range]) {
                flags.insert(.secretEntropy)
                break
            }
        }

        return flags
    }

    /// First bytes of every registered prefix. Almost every prose word fails
    /// this single lookup, which keeps the signature table off the hot path.
    private static let vendorFirstBytes = CharsetMask(bytes: vendorSignatures.compactMap(\.prefix.first))

    /// True when the token begins with a registered vendor prefix followed by
    /// enough trailing characters of the right alphabet.
    private static func matchesVendorSignature(_ token: ArraySlice<UInt8>) -> Bool {
        guard let first = token.first, vendorFirstBytes.contains(first) else { return false }
        for sig in vendorSignatures {
            guard token.count >= sig.prefix.count + sig.minTail else { continue }
            guard hasPrefix(token, sig.prefix) else { continue }
            let tail = token.dropFirst(sig.prefix.count)
            // The tail must be *entirely* in the signature's alphabet for at
            // least `minTail` characters. Trailing punctuation (a comma at the
            // end of a JSON line, a closing quote) is tolerated by measuring the
            // run rather than the whole tail.
            var run = 0
            for byte in tail {
                guard sig.tail.contains(byte) else { break }
                run += 1
            }
            if run >= sig.minTail { return true }
        }
        return false
    }

    /// A JWT: `eyJ`-prefixed base64url header, then two more base64url segments.
    ///
    /// The `eyJ` prefix is not decoration — it is base64url for `{"`, so any
    /// token starting with it *is* a base64url-encoded JSON object. Combined with
    /// the mandatory three-segment structure this has no realistic FP.
    private static func isJWT(_ token: ArraySlice<UInt8>) -> Bool {
        guard hasPrefix(token, Array("eyJ".utf8)) else { return false }
        var segments: [Int] = [0]
        for byte in token {
            if byte == UInt8(ascii: ".") {
                segments.append(0)
                if segments.count > 3 { return false }
            } else if CharsetMask.base64URL.contains(byte) {
                segments[segments.count - 1] += 1
            } else {
                return false
            }
        }
        guard segments.count == 3 else { return false }
        // Header and payload must be real base64 payloads; the signature may be
        // short (or absent for `alg: none`, which we still treat as a token).
        return segments[0] >= 8 && segments[1] >= 8
    }

    /// Tier-2 generic entropy gate (§3.1), deliberately over-tight.
    ///
    /// Every clause below exists because of a concrete false positive found in
    /// real clipboard corpora:
    ///
    /// - **single token, no whitespace** — a secret is copied alone.
    /// - **length ≥ 24, Shannon ≥ 3.5 b/char, ≥ 2 charset classes** — the spec floor.
    /// - **credential alphabet only** — kills minified code (`for(i=0;i<n;i++){…}`
    ///   is one whitespace-free 3.9-bit token; the braces and semicolons give it away).
    /// - **not hex-only ≥ 16** — kills 40-hex git SHAs, MD5 and SHA-256 digests.
    /// - **not UUID-shaped** — kills `550e8400-e29b-41d4-a716-446655440000`.
    /// - **contains a digit** — kills long camelCase identifiers
    ///   (`getElementByIdAndCacheIt` is 24 chars, two classes, 3.9 bits).
    /// - **does not base64-decode to printable text** — kills ordinary base64 of
    ///   English prose, whose plaintext is ~100% printable while a real key's is ~37%.
    /// - **no `://` or `@`** — kills long URLs and email addresses.
    /// - **not path- or filename-shaped** — kills
    ///   `/Users/me/2024/report_v2.pdf`, which is 27 whitespace-free characters
    ///   of ~4.0-bit "entropy" made entirely of credential-legal bytes.
    static func isHighEntropySecretCandidate(_ token: ArraySlice<UInt8>) -> Bool {
        guard token.count >= 24 else { return false }
        guard !isPathOrFilenameShaped(token) else { return false }

        var classes = 0
        var hasLower = false, hasUpper = false, hasDigit = false, hasSymbol = false
        var hexOnly = true
        var hasAt = false

        for byte in token {
            guard credentialCharset.contains(byte) else { return false }  // punctuation ⇒ code
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"):
                hasLower = true
                if byte > UInt8(ascii: "f") { hexOnly = false }
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                hasUpper = true
                if byte > UInt8(ascii: "F") { hexOnly = false }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                hasDigit = true
            case UInt8(ascii: "@"):
                hasAt = true
                hexOnly = false
            default:
                hasSymbol = true
                hexOnly = false
            }
        }
        if hasAt { return false }
        if hasLower { classes += 1 }
        if hasUpper { classes += 1 }
        if hasDigit { classes += 1 }
        if hasSymbol { classes += 1 }
        guard classes >= 2, hasDigit else { return false }
        guard !(hexOnly && token.count >= 16) else { return false }
        guard !isUUIDShaped(token) else { return false }
        guard !contains(token, pattern: Array("://".utf8)) else { return false }
        guard shannonEntropy(token) >= 3.5 else { return false }
        guard !decodesToPrintableText(token) else { return false }
        return true
    }

    /// A filesystem path (`/…`, `~/…`, `./…`) or a filename with an extension
    /// (`…​.pdf`, `…​.swift`). Both are made only of credential-legal bytes and
    /// both are extremely common on a clipboard, so they are excluded explicitly
    /// rather than left to the entropy threshold to (fail to) reject.
    static func isPathOrFilenameShaped(_ token: ArraySlice<UInt8>) -> Bool {
        guard let first = token.first else { return false }
        if first == UInt8(ascii: "/") || first == UInt8(ascii: "~") || first == UInt8(ascii: ".") { return true }
        // Trailing `.ext` where ext is 1–5 letters.
        var letters = 0
        for byte in token.reversed() {
            if CharsetMask.letter.contains(byte) {
                letters += 1
                if letters > 5 { return false }
            } else {
                return byte == UInt8(ascii: ".") && letters >= 1
            }
        }
        return false
    }

    /// `8-4-4-4-12` hex with dashes. UUIDs are structured identifiers, not keys —
    /// leaking one is not a credential incident, and they are everywhere.
    static func isUUIDShaped(_ token: ArraySlice<UInt8>) -> Bool {
        let groups = [8, 4, 4, 4, 12]
        var groupIndex = 0
        var run = 0
        for byte in token {
            if byte == UInt8(ascii: "-") {
                guard groupIndex < groups.count, run == groups[groupIndex] else { return false }
                groupIndex += 1
                run = 0
            } else if CharsetMask.hex.contains(byte) {
                run += 1
                if groupIndex >= groups.count || run > groups[groupIndex] { return false }
            } else {
                return false
            }
        }
        return groupIndex == groups.count - 1 && run == groups[groupIndex]
    }

    /// True when the token is valid base64 **and** its plaintext is essentially
    /// all printable ASCII — i.e. it is base64 of *text*, not of key material.
    ///
    /// A 32-byte random key base64-decodes to ~37% printable bytes; a sentence
    /// decodes to 100%. The 0.95 threshold sits in the enormous gap between them.
    static func decodesToPrintableText(_ token: ArraySlice<UInt8>) -> Bool {
        var normalized = String(decoding: token, as: UTF8.self)
        // Accept base64url too, and re-pad — many corpora strip `=`.
        normalized = normalized.replacingOccurrences(of: "-", with: "+")
                               .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder == 1 { return false }
        if remainder > 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: normalized), data.count >= 12 else { return false }
        var printable = 0
        for byte in data where (byte >= 0x20 && byte <= 0x7E) || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            printable += 1
        }
        return Double(printable) / Double(data.count) >= 0.95
    }

    /// Shannon entropy in bits per character over the byte histogram.
    static func shannonEntropy(_ token: ArraySlice<UInt8>) -> Double {
        guard !token.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in token { counts[Int(byte)] += 1 }
        let total = Double(token.count)
        var entropy = 0.0
        for count in counts where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }
        return entropy
    }

    // MARK: - 3.2 Financial

    /// §3.2 — financial identifiers, each behind a real checksum.
    ///
    /// Returns the flags plus the byte ranges consumed by a card or an IBAN, so
    /// the phone rule (§3.3) cannot double-count the same digits.
    static func scanFinancial(bytes: [UInt8], tokens: [Range<Int>]) -> (flags: ClipFlags, consumed: [Range<Int>]) {
        var flags: ClipFlags = []
        var consumed: [Range<Int>] = []

        // -- Card: a 13–19 digit run (single spaces/dashes tolerated inside),
        //    Luhn-valid AND matching a real issuer prefix.
        for run in digitGroupRuns(bytes) {
            let digits = run.digits
            guard (13...19).contains(digits.count) else { continue }
            guard luhnValid(digits), cardBrand(digits) != nil else { continue }
            flags.insert(.financial)
            consumed.append(run.range)
        }

        // -- ABA routing: exactly 9 contiguous digits with the 3-7-1 checksum.
        for run in contiguousDigitRuns(bytes) where run.digits.count == 9 {
            if abaRoutingValid(run.digits) {
                flags.insert(.financial)
                consumed.append(run.range)
            }
        }

        // -- IBAN: token-wise, plus the conventional 4-character grouping
        //    ("GB82 WEST 1234 …") reassembled from consecutive tokens.
        for (index, range) in tokens.enumerated() {
            guard let candidate = ibanCandidate(bytes: bytes, tokens: tokens, startingAt: index) else { continue }
            if ibanValid(candidate.text) {
                flags.insert(.financial)
                consumed.append(range.lowerBound..<candidate.end)
            }
        }

        // -- Crypto addresses. Length- and prefix-gated *before* materialising a
        //    String, so a paragraph of prose costs nothing here.
        // Crypto-address validation is the most expensive rule in the pass
        // (base58check = double SHA-256; EIP-55 = Keccak-256), and the cheap
        // prefix screen above lets through any 26–42 char token starting `1`/`3`.
        // A clip full of such tokens would otherwise pay a hash for each, on the
        // copy hot path. Budget the expensive validations: a real clip holds a
        // handful of addresses, so the cap only ever bites on pathological input,
        // where the flag adds nothing anyway.
        var cryptoBudget = 64
        for range in tokens {
            let token = bytes[range]
            guard (26...42).contains(token.count) else { continue }
            let looksBitcoin = hasPrefix(token, Array("bc1".utf8)) || hasPrefix(token, Array("BC1".utf8))
                || token.first == UInt8(ascii: "1") || token.first == UInt8(ascii: "3")
            let looksEthereum = token.count == 42 && token.first == UInt8(ascii: "0")
            guard looksBitcoin || looksEthereum else { continue }
            guard cryptoBudget > 0 else { break }
            cryptoBudget -= 1
            let text = String(decoding: token, as: UTF8.self)
            if isBitcoinAddress(text) || isEthereumAddress(text) {
                flags.insert(.financial)
                consumed.append(range)
            }
        }

        return (flags, consumed)
    }

    /// The Luhn (mod-10) checksum. Necessary but **never sufficient**: roughly
    /// one in ten random digit runs passes it, which is why `cardBrand` is a hard
    /// requirement alongside it (§3.2).
    static func luhnValid(_ digits: [Int]) -> Bool {
        guard digits.count >= 2 else { return false }
        var sum = 0
        var double = false
        for digit in digits.reversed() {
            var value = digit
            if double {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
            double.toggle()
        }
        return sum % 10 == 0
    }

    /// The mandatory IIN / brand-prefix check.
    ///
    /// Without it a Luhn-passing invoice number, order id or account number
    /// becomes a "credit card" ~10% of the time. Length is part of each brand's
    /// definition and is enforced too — a 16-digit Amex is not an Amex.
    static func cardBrand(_ digits: [Int]) -> String? {
        func prefix(_ count: Int) -> Int {
            guard digits.count >= count else { return -1 }
            return digits.prefix(count).reduce(0) { $0 * 10 + $1 }
        }
        let n = digits.count
        if prefix(1) == 4, [13, 16, 19].contains(n) { return "visa" }
        if (51...55).contains(prefix(2)), n == 16 { return "mastercard" }
        if (2221...2720).contains(prefix(4)), n == 16 { return "mastercard" }
        if [34, 37].contains(prefix(2)), n == 15 { return "amex" }
        if prefix(4) == 6011 || prefix(2) == 65, (16...19).contains(n) { return "discover" }
        return nil
    }

    /// ABA routing number: 9 digits, weights 3-7-1 repeating, sum ≡ 0 (mod 10).
    static func abaRoutingValid(_ digits: [Int]) -> Bool {
        guard digits.count == 9 else { return false }
        let weights = [3, 7, 1, 3, 7, 1, 3, 7, 1]
        var sum = 0
        for (digit, weight) in zip(digits, weights) { sum += digit * weight }
        return sum % 10 == 0
    }

    /// IBAN validity: rearrange (first four characters to the back), expand
    /// letters to `A=10 … Z=35`, then require the whole number ≡ 1 (mod 97).
    ///
    /// The modulus is computed incrementally so no big-integer type is needed.
    static func ibanValid(_ raw: String) -> Bool {
        let chars = Array(raw.uppercased().utf8)
        guard (15...34).contains(chars.count) else { return false }
        guard CharsetMask.upper.contains(chars[0]), CharsetMask.upper.contains(chars[1]),
              CharsetMask.digit.contains(chars[2]), CharsetMask.digit.contains(chars[3]) else { return false }

        var remainder = 0
        // Rearranged order: characters 4… then 0..<4.
        for index in 0..<chars.count {
            let byte = chars[(index + 4) % chars.count]
            if CharsetMask.digit.contains(byte) {
                remainder = (remainder * 10 + Int(byte - UInt8(ascii: "0"))) % 97
            } else if CharsetMask.upper.contains(byte) {
                let value = Int(byte - UInt8(ascii: "A")) + 10
                remainder = (remainder * 100 + value) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// Assemble an IBAN candidate starting at `index`: either the single token,
    /// or that token plus following all-alphanumeric tokens (the conventional
    /// four-character grouping). Returns `nil` when the token cannot start one.
    private static func ibanCandidate(bytes: [UInt8], tokens: [Range<Int>],
                                      startingAt index: Int) -> (text: String, end: Int)? {
        let first = tokens[index]
        let head = bytes[first]
        guard head.count >= 4 else { return nil }
        // Cheap byte-level gate before any String is built: `CC99…`.
        let start = head.startIndex
        guard CharsetMask.upper.contains(head[start]), CharsetMask.upper.contains(head[start + 1]),
              CharsetMask.digit.contains(head[start + 2]), CharsetMask.digit.contains(head[start + 3]) else { return nil }

        var text = String(decoding: head, as: UTF8.self)
        var end = first.upperBound
        guard text.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        if text.count >= 15 { return (text, end) }

        // Grow across at most 8 following groups — an IBAN is ≤ 34 characters.
        var next = index + 1
        while next < tokens.count, next - index <= 8, text.count < 34 {
            let piece = String(decoding: bytes[tokens[next]], as: UTF8.self)
            guard !piece.isEmpty, piece.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
            text += piece
            end = tokens[next].upperBound
            next += 1
        }
        return text.count >= 15 ? (text, end) : nil
    }

    // MARK: Crypto addresses

    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)

    /// A Bitcoin address: bech32/bech32m (`bc1…`) with a verified checksum, or a
    /// legacy base58check address with a verified double-SHA-256 checksum.
    static func isBitcoinAddress(_ token: String) -> Bool {
        if token.lowercased().hasPrefix("bc1") { return bech32Valid(token) }
        return base58CheckValid(token)
    }

    /// BIP-173 / BIP-350 checksum verification. Accepts both constants so the
    /// newer taproot (`bc1p…`, bech32m) addresses validate as well.
    static func bech32Valid(_ address: String) -> Bool {
        // Mixed case is invalid per BIP-173.
        let hasUpper = address.contains { $0.isUppercase }
        let hasLower = address.contains { $0.isLowercase }
        if hasUpper && hasLower { return false }
        let lower = Array(address.lowercased().utf8)
        guard (14...90).contains(lower.count) else { return false }
        guard let separator = lower.lastIndex(of: UInt8(ascii: "1")), separator >= 1,
              lower.count - separator - 1 >= 6 else { return false }
        let hrp = lower[0..<separator]
        var values: [Int] = []
        values.reserveCapacity(lower.count)
        for byte in hrp { values.append(Int(byte) >> 5) }
        values.append(0)
        for byte in hrp { values.append(Int(byte) & 31) }
        for byte in lower[(separator + 1)...] {
            guard let position = bech32Charset.firstIndex(of: byte) else { return false }
            values.append(position)
        }
        let checksum = bech32Polymod(values)
        return checksum == 1 || checksum == 0x2bc830a3
    }

    private static func bech32Polymod(_ values: [Int]) -> Int {
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ value
            for bit in 0..<5 where (top >> bit) & 1 == 1 { checksum ^= generator[bit] }
        }
        return checksum
    }

    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    /// Legacy Bitcoin address: base58 decode → 25 bytes → the last four must be
    /// the first four bytes of `SHA256(SHA256(payload))`. A single mistyped
    /// character fails, which is exactly the property that makes this zero-FP.
    static func base58CheckValid(_ token: String) -> Bool {
        let input = Array(token.utf8)
        guard (26...35).contains(input.count) else { return false }
        var bytes: [UInt8] = [0]
        for character in input {
            guard let value = base58Alphabet.firstIndex(of: character) else { return false }
            var carry = value
            for index in (0..<bytes.count).reversed() {
                carry += 58 * Int(bytes[index])
                bytes[index] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        // Leading '1's are leading zero bytes.
        var leadingZeros = 0
        for character in input {
            if character == UInt8(ascii: "1") { leadingZeros += 1 } else { break }
        }
        while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
        bytes.insert(contentsOf: [UInt8](repeating: 0, count: leadingZeros), at: 0)

        guard bytes.count == 25 else { return false }
        // Version byte: P2PKH (0x00) or P2SH (0x05). Anything else is another
        // chain or a WIF key and is out of scope for this rule.
        guard bytes[0] == 0x00 || bytes[0] == 0x05 else { return false }
        let payload = Array(bytes[0..<21])
        let expected = Array(bytes[21..<25])
        let digest = Array(SHA256.hash(data: Data(SHA256.hash(data: Data(payload)))))
        return Array(digest[0..<4]) == expected
    }

    /// An Ethereum address: `0x` + 40 hex characters.
    ///
    /// EIP-55 is a *case* checksum, so it can only be verified when the string is
    /// genuinely mixed-case. An all-lowercase or all-uppercase address carries no
    /// checksum information — it is still a valid address and is still tagged
    /// (shape-only), because refusing to tag it would silently drop the most
    /// common way addresses are pasted.
    static func isEthereumAddress(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count == 42, bytes[0] == UInt8(ascii: "0"),
              bytes[1] == UInt8(ascii: "x") || bytes[1] == UInt8(ascii: "X") else { return false }
        let body = Array(bytes[2...])
        guard body.allSatisfy({ CharsetMask.hex.contains($0) }) else { return false }

        var hasUpperLetter = false
        var hasLowerLetter = false
        for byte in body {
            if byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F") { hasUpperLetter = true }
            if byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f") { hasLowerLetter = true }
        }
        guard hasUpperLetter && hasLowerLetter else { return true }  // shape-only, still tagged
        return eip55Valid(body)
    }

    /// EIP-55: hash the lowercase hex body with Keccak-256; a body character must
    /// be uppercase exactly when the corresponding hash nibble is ≥ 8.
    static func eip55Valid(_ body: [UInt8]) -> Bool {
        let lower = body.map { byte -> UInt8 in
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F")) ? byte + 32 : byte
        }
        let hash = Keccak256.hash(lower)
        for (index, byte) in body.enumerated() {
            let nibble = index % 2 == 0 ? (hash[index / 2] >> 4) : (hash[index / 2] & 0x0f)
            let isLetter = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
            guard isLetter else { continue }
            let shouldBeUpper = nibble >= 8
            let isUpper = byte <= UInt8(ascii: "F")
            if shouldBeUpper != isUpper { return false }
        }
        return true
    }

    // MARK: - 3.3 PII, severity-split

    private static let streetSuffixes: Set<String> = [
        "street", "st", "road", "rd", "avenue", "ave", "lane", "ln", "drive", "dr",
        "boulevard", "blvd", "way", "close", "court", "ct", "place", "pl", "terrace",
        "crescent", "square", "sq", "highway", "hwy", "parkway", "pkwy",
    ]

    /// The same set as UTF-8 bytes, so token matching never has to build a String.
    private static let streetSuffixBytes: Set<[UInt8]> = Set(streetSuffixes.map { Array($0.utf8) })

    /// §3.3 — identity, split by severity.
    ///
    /// `email` / `phone` earn the informational `.pii` bit only: they are copied
    /// in order to be pasted, and masking them would make the app worse at its
    /// job. National ids and postal addresses earn `.piiSensitive` and the
    /// protective treatment that goes with it.
    static func scanPII(bytes: [UInt8], lowered: [UInt8], tokens: [Range<Int>],
                        consumed: [Range<Int>]) -> ClipFlags {
        var flags: ClipFlags = []

        for range in tokens where isEmailAddress(bytes[range]) {
            flags.insert(.pii)
            break
        }

        // Phone: a digit run that is genuinely *phone-shaped* and does not
        // overlap anything the financial pass already claimed (§3.3 — a card or
        // an IBAN must never be double-counted as a phone number).
        //
        // The claimed ranges are flattened into a byte mask ONCE (O(total claimed
        // length)) instead of being re-scanned per run. The obvious
        // `consumed.contains(where:)` inside the loop is O(runs x claimed), which
        // on a clip holding thousands of card-shaped runs turns this hot-path
        // scan quadratic — and this runs synchronously on every copy, before the
        // clip is even persisted, so a blow-up here freezes the clipboard.
        var claimed = [Bool](repeating: false, count: bytes.count)
        for r in consumed {
            for i in r.clamped(to: 0..<bytes.count) { claimed[i] = true }
        }
        for run in digitGroupRuns(bytes) {
            let r = run.range.clamped(to: 0..<bytes.count)
            guard !r.contains(where: { claimed[$0] }) else { continue }
            guard isPhoneShaped(run) else { continue }
            flags.insert(.pii)
            break
        }

        if detectNationalID(bytes: bytes) { flags.insert(.piiSensitive) }
        if detectPostalAddress(bytes: bytes, lowered: lowered, tokens: tokens) { flags.insert(.piiSensitive) }

        return flags
    }

    /// Digit-group shapes that a phone number is actually written in.
    private static let phoneGroupShapes: Set<[Int]> = [
        [3, 3, 4], [3, 4, 4], [4, 3, 3], [4, 3, 4], [2, 4, 4], [3, 4], [5, 6], [4, 6], [4, 7],
        [2, 3, 3, 4], [3, 3, 3, 3],
    ]

    /// Whether a digit run is phone-shaped.
    ///
    /// This is deliberately *shape*-based rather than "7–15 digits with any
    /// separator". A timestamp like `2026-08-06 12:34:56` yields a 10-digit run
    /// grouped `[4, 2, 2, 2]`, and an ISO date yields `[4, 2, 2]` — both would
    /// pass a naive length-plus-separator rule and put a PII badge on every
    /// copied date. Requiring a leading `+`, a UK-style bare `0…` mobile, or one
    /// of the real-world group shapes removes that whole false-positive class.
    static func isPhoneShaped(_ run: DigitRun) -> Bool {
        let total = run.digits.count
        if run.plusPrefixed { return (8...15).contains(total) }
        if phoneGroupShapes.contains(run.groups) { return (9...13).contains(total) }
        // Bare national mobile: 11 digits starting with a trunk 0.
        if run.groups.count == 1, total == 11, run.digits.first == 0 { return true }
        return false
    }

    /// An email address, not a bare `@handle`.
    ///
    /// Requires a non-empty local part, exactly one `@`, and a domain with a dot
    /// and an alphabetic TLD of at least two characters. `@antreas` and
    /// `user@localhost` are both rejected — the first is a social handle, the
    /// second is not routable and is far more often a code sample than a contact.
    static func isEmailAddress(_ token: ArraySlice<UInt8>) -> Bool {
        // Trim common trailing punctuation so "mail me at a@b.com." still matches.
        var slice = token
        while let last = slice.last, CharsetMask.trailingPunctuation.contains(last) { slice = slice.dropLast() }
        while let first = slice.first, CharsetMask.leadingPunctuation.contains(first) { slice = slice.dropFirst() }
        guard slice.count >= 6 else { return false }

        var atIndex: Int?
        for (offset, byte) in slice.enumerated() where byte == UInt8(ascii: "@") {
            if atIndex != nil { return false }  // two '@' ⇒ not an address
            atIndex = offset
        }
        guard let at = atIndex, at >= 1, at < slice.count - 4 else { return false }

        let local = Array(slice)[0..<at]
        let domain = Array(slice)[(at + 1)...]
        guard local.allSatisfy({ CharsetMask.emailLocal.contains($0) }) else { return false }
        guard domain.allSatisfy({ CharsetMask.alnumDashDot.contains($0) }) else { return false }
        guard let lastDot = domain.lastIndex(of: UInt8(ascii: ".")) else { return false }
        let tld = domain[(lastDot + 1)...]
        guard tld.count >= 2, tld.allSatisfy({ CharsetMask.letter.contains($0) }) else { return false }
        guard lastDot > domain.startIndex else { return false }
        return true
    }

    /// National-identifier shapes. Only formats with a *structural* validity rule
    /// are implemented, so the sensitive bit stays rare (§3.3: "fire rarely").
    ///
    /// - US SSN `AAA-GG-SSSS`: no check digit exists, so the SSA's published
    ///   allocation rules stand in for one (area ≠ 000/666/900-999, group ≠ 00,
    ///   serial ≠ 0000).
    /// - Canadian SIN `AAA-AAA-AAA`: a genuine Luhn check digit, verified.
    /// - UK NINO `AB123456C`: strict prefix/suffix alphabet.
    static func detectNationalID(bytes: [UInt8]) -> Bool {
        var previous: UInt8 = 0x20
        for index in 0..<bytes.count {
            // Cheapest rejection first: every shape here starts with a digit or
            // an uppercase letter at a token boundary, so lowercase prose is
            // discarded on a single table lookup. `previous` carries the
            // boundary test without a second bounds-checked read.
            let byte = bytes[index]
            defer { previous = byte }
            guard CharsetMask.digitOrUpper.contains(byte) else { continue }
            guard !CharsetMask.alnum.contains(previous) else { continue }
            if matchesSSN(bytes, at: index) { return true }
            if matchesSIN(bytes, at: index) { return true }
            if matchesNINO(bytes, at: index) { return true }
        }
        return false
    }

    private static func matchesSSN(_ bytes: [UInt8], at index: Int) -> Bool {
        // 3 digits, sep, 2 digits, sep, 4 digits — sep is '-' or ' '.
        guard index + 11 <= bytes.count else { return false }
        let groups = [3, 2, 4]
        var cursor = index
        var digits: [Int] = []
        for (position, size) in groups.enumerated() {
            for _ in 0..<size {
                guard cursor < bytes.count, CharsetMask.digit.contains(bytes[cursor]) else { return false }
                digits.append(Int(bytes[cursor] - UInt8(ascii: "0")))
                cursor += 1
            }
            if position < groups.count - 1 {
                guard cursor < bytes.count,
                      bytes[cursor] == UInt8(ascii: "-") || bytes[cursor] == UInt8(ascii: " ") else { return false }
                cursor += 1
            }
        }
        guard isBoundary(bytes, after: cursor) else { return false }
        let area = digits[0] * 100 + digits[1] * 10 + digits[2]
        let group = digits[3] * 10 + digits[4]
        let serial = digits[5] * 1000 + digits[6] * 100 + digits[7] * 10 + digits[8]
        guard area != 0, area != 666, area < 900, group != 0, serial != 0 else { return false }
        return true
    }

    private static func matchesSIN(_ bytes: [UInt8], at index: Int) -> Bool {
        // 3-3-3 grouping with a Luhn check digit. The grouping is what keeps this
        // from colliding with a 9-digit ABA routing number (never separated).
        guard index + 11 <= bytes.count else { return false }
        var cursor = index
        var digits: [Int] = []
        for position in 0..<3 {
            for _ in 0..<3 {
                guard cursor < bytes.count, CharsetMask.digit.contains(bytes[cursor]) else { return false }
                digits.append(Int(bytes[cursor] - UInt8(ascii: "0")))
                cursor += 1
            }
            if position < 2 {
                guard cursor < bytes.count,
                      bytes[cursor] == UInt8(ascii: "-") || bytes[cursor] == UInt8(ascii: " ") else { return false }
                cursor += 1
            }
        }
        guard isBoundary(bytes, after: cursor) else { return false }
        guard digits[0] != 0 else { return false }
        return luhnValid(digits)
    }

    private static let ninoInvalidPrefixes: Set<String> = ["BG", "GB", "NK", "KN", "TN", "NT", "ZZ"]

    private static func matchesNINO(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 9 <= bytes.count else { return false }
        let slice = Array(bytes[index..<(index + 9)])
        guard CharsetMask.upper.contains(slice[0]), CharsetMask.upper.contains(slice[1]) else { return false }
        for offset in 2..<8 where !CharsetMask.digit.contains(slice[offset]) { return false }
        guard "ABCD".utf8.contains(slice[8]) else { return false }
        guard isBoundary(bytes, after: index + 9) else { return false }
        let prefix = String(decoding: slice[0..<2], as: UTF8.self)
        guard !ninoInvalidPrefixes.contains(prefix) else { return false }
        guard !"DFIQUV".utf8.contains(slice[0]), !"DFIQUVO".utf8.contains(slice[1]) else { return false }
        return true
    }

    /// A postal address needs **all three** of: a house number, a street suffix,
    /// and a postcode. Any one alone is far too common ("Flat 3", "the High
    /// Street", "SW1A") — the co-occurrence is what makes this rare enough to
    /// justify protective treatment.
    static func detectPostalAddress(bytes: [UInt8], lowered: [UInt8], tokens: [Range<Int>]) -> Bool {
        // Two passes, cheapest first. The house-number test is pure byte work;
        // the suffix test needs a lowercased copy per token, so it only runs at
        // all once a house number has actually been seen.
        var hasHouseNumber = false
        for (index, range) in tokens.enumerated() where index + 1 < tokens.count {
            // House number: digits, optionally with one trailing letter ("221B").
            // It must be followed by something — a bare number is not an address.
            if isHouseNumber(trimmedPunctuation(bytes[range])) { hasHouseNumber = true; break }
        }
        guard hasHouseNumber else { return false }

        var hasSuffix = false
        for range in tokens {
            let word = trimmedPunctuation(bytes[range])
            guard (2...10).contains(word.count) else { continue }
            if streetSuffixBytes.contains(asciiLowercased(Array(word))) { hasSuffix = true; break }
        }
        guard hasSuffix else { return false }
        return containsPostcode(bytes: bytes, tokens: tokens)
    }

    private static func isHouseNumber(_ word: ArraySlice<UInt8>) -> Bool {
        guard (1...5).contains(word.count) else { return false }
        var seenLetter = false
        for (offset, byte) in word.enumerated() {
            if CharsetMask.digit.contains(byte) {
                if seenLetter { return false }
            } else if CharsetMask.letter.contains(byte), offset == word.count - 1, offset > 0 {
                seenLetter = true
            } else {
                return false
            }
        }
        return true
    }

    /// UK postcode (`SW1A 1AA`, `EC1Y 8QE`) or US ZIP (`94103`, `94103-1234`),
    /// matched byte-wise — no regex on the hot path.
    static func containsPostcode(bytes: [UInt8], tokens: [Range<Int>]) -> Bool {
        for (index, range) in tokens.enumerated() {
            let word = trimmedPunctuation(bytes[range])
            if isUSZIP(word) { return true }
            if isUKPostcode(word) { return true }
            // Space-separated UK outward/inward pair ("NW1" + "6XE").
            if index + 1 < tokens.count, isUKOutward(word) {
                let next = trimmedPunctuation(bytes[tokens[index + 1]])
                if isUKInward(next) { return true }
            }
        }
        return false
    }

    private static func isUSZIP(_ word: ArraySlice<UInt8>) -> Bool {
        let digits = word.filter { CharsetMask.digit.contains($0) }
        if word.count == 5 { return digits.count == 5 }
        if word.count == 10 {
            let array = Array(word)
            return digits.count == 9 && array[5] == UInt8(ascii: "-")
        }
        return false
    }

    private static func isUKOutward(_ word: ArraySlice<UInt8>) -> Bool {
        let array = Array(word)
        guard (2...4).contains(array.count) else { return false }
        var index = 0
        var letters = 0
        while index < array.count, CharsetMask.upper.contains(array[index]) { letters += 1; index += 1 }
        guard (1...2).contains(letters) else { return false }
        guard index < array.count, CharsetMask.digit.contains(array[index]) else { return false }
        index += 1
        if index == array.count { return true }
        guard index == array.count - 1 else { return false }
        return CharsetMask.upperDigit.contains(array[index])
    }

    private static func isUKInward(_ word: ArraySlice<UInt8>) -> Bool {
        let array = Array(word)
        guard array.count == 3, CharsetMask.digit.contains(array[0]),
              CharsetMask.upper.contains(array[1]), CharsetMask.upper.contains(array[2]) else { return false }
        return true
    }

    private static func isUKPostcode(_ word: ArraySlice<UInt8>) -> Bool {
        guard (5...7).contains(word.count) else { return false }
        let array = Array(word)
        let split = array.count - 3
        return isUKOutward(array[0..<split]) && isUKInward(array[split...])
    }

    /// Drop leading/trailing punctuation from a token without allocating a String.
    static func trimmedPunctuation(_ token: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = token
        while let last = slice.last, CharsetMask.trailingPunctuation.contains(last) { slice = slice.dropLast() }
        while let first = slice.first, CharsetMask.leadingPunctuation.contains(first) { slice = slice.dropFirst() }
        return slice
    }

    // MARK: - 3.8 One-time code

    private static let otpKeywords: [[UInt8]] = [
        Array("code".utf8), Array("verification".utf8), Array("one-time".utf8),
        Array("one time".utf8), Array("otp".utf8), Array("passcode".utf8),
        Array("2fa".utf8),
    ]

    private static let magicLinkMarkers: [[UInt8]] = [
        Array("login".utf8), Array("verify".utf8), Array("magic".utf8),
        Array("confirm".utf8), Array("signin".utf8), Array("sign-in".utf8),
        Array("auth".utf8),
    ]

    /// §3.8 — an isolated 4–8 digit run near an OTP keyword, **or** a
    /// login/verify/magic URL carrying a high-entropy token parameter.
    ///
    /// Source app and recency are deliberately *not* required. The design says
    /// they are "a confidence booster, not a hard AND" — an OTP pasted from a
    /// browser or a note is still an OTP, and the caller is free to raise its
    /// confidence when the origin and the clock agree.
    static func detectOTP(bytes: [UInt8], lowered: [UInt8]) -> Bool {
        // (a) digits near a keyword.
        for run in contiguousDigitRuns(bytes) where (4...8).contains(run.digits.count) {
            guard isBoundary(bytes, before: run.range.lowerBound),
                  isBoundary(bytes, after: run.range.upperBound) else { continue }
            let window = 48
            let start = max(0, run.range.lowerBound - window)
            let end = min(bytes.count, run.range.upperBound + window)
            let context = lowered[start..<end]
            for keyword in otpKeywords where containsWord(context, keyword) { return true }
        }

        // (b) magic link with a high-entropy token parameter.
        for url in urlSpans(lowered) {
            let span = lowered[url]
            guard magicLinkMarkers.contains(where: { contains(span, pattern: $0) }) else { continue }
            let original = Array(bytes[url])
            if hasHighEntropyParameter(original) { return true }
        }
        return false
    }

    /// A `key=value` (or trailing path segment) carrying something that looks
    /// like a single-use token: ≥ 16 characters, ≥ 3.0 bits/char, mixed classes.
    private static func hasHighEntropyParameter(_ url: [UInt8]) -> Bool {
        var candidates: [ArraySlice<UInt8>] = []
        var start = 0
        for (index, byte) in url.enumerated() {
            if byte == UInt8(ascii: "=") || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "&")
                || byte == UInt8(ascii: "/") {
                if index > start { candidates.append(url[start..<index]) }
                start = index + 1
            }
        }
        if start < url.count { candidates.append(url[start..<url.count]) }

        for candidate in candidates where candidate.count >= 16 {
            var hasLetter = false, hasDigit = false
            var ok = true
            for byte in candidate {
                if CharsetMask.letter.contains(byte) { hasLetter = true }
                else if CharsetMask.digit.contains(byte) { hasDigit = true }
                else if !CharsetMask.dashUnderscore.contains(byte) { ok = false; break }
            }
            guard ok, hasLetter, hasDigit else { continue }
            if shannonEntropy(candidate) >= 3.0 { return true }
        }
        return false
    }

    // MARK: - 3.4 Shape

    /// The complete shape vocabulary. There is no `prose` member and no
    /// `safe`/`public` member — §3.4 requires the default to be blank, and
    /// principle 4 requires every emitted value to map to one glance-action.
    static let shapeVocabulary: [String] = ["url", "command", "code", "json", "yaml", "path", "color", "value"]

    private static let commandVerbs: Set<String> = [
        "git", "cd", "brew", "sudo", "docker", "kubectl", "npm", "pip", "ssh", "curl",
    ]

    /// §3.4 — structural shape, **first-match-wins**, in the documented order:
    /// `url → command → code → json → yaml → path → color → value → nil`.
    ///
    /// Only runs for `kind == .text`; every other kind is already described by
    /// `kind` itself, so re-deriving it would just be the content-type axis the
    /// design dropped. Conceptually this runs *after* §3.1–3.3/§3.8: shape is
    /// cosmetic and must never pre-empt a protective badge.
    ///
    /// Prose returns `nil`. That is the single most important line in this
    /// function — a `prose` tag has no glance-action and would sit on the
    /// majority of clips, making every other chip harder to see.
    static func shape(of text: String, kind: ClipKind) -> String? {
        guard kind == .text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let singleToken = !trimmed.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" })

        if singleToken, isURLLike(trimmed) { return "url" }
        if isCommand(trimmed) { return "command" }
        if isCode(trimmed, lines: lines) { return "code" }
        if isJSON(trimmed) { return "json" }
        if isYAML(lines) { return "yaml" }
        if singleToken, isPath(trimmed) { return "path" }
        if singleToken, isColor(trimmed) { return "color" }
        if singleToken, isValue(trimmed) { return "value" }
        return nil
    }

    private static func isURLLike(_ text: String) -> Bool {
        guard let schemeEnd = text.range(of: "://") else { return false }
        let scheme = text[text.startIndex..<schemeEnd.lowerBound]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0 == "+" || $0 == "." || $0 == "-" }) else { return false }
        return schemeEnd.upperBound < text.endIndex
    }

    /// A shell command.
    ///
    /// `$ ` and `# ` are the conventional user/root prompt markers, but `#` is
    /// also a Markdown heading and a shell *comment*. So a leading `#` only
    /// counts when the very next token is a known command verb: `# docker ps` is
    /// a root prompt, `# Heading text` and `# install the deps first` are not.
    private static func isCommand(_ text: String) -> Bool {
        var body = Substring(text)

        if body.hasPrefix("$") {
            body = body.dropFirst()
            guard let first = body.first, first == " " || first == "\t" else { return false }
            return !body.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if body.hasPrefix("#") {
            body = body.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
            guard let verb = body.split(separator: " ", maxSplits: 1).first else { return false }
            return commandVerbs.contains(String(verb).lowercased())
        }
        guard let verb = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return false }
        return commandVerbs.contains(String(verb))
    }

    /// Code: an explicit fence, or brace-plus-semicolon density, or an indented
    /// multi-line block containing a language keyword.
    ///
    /// The semicolon requirement is what keeps this from stealing JSON (which is
    /// checked next and has braces but no semicolons).
    private static func isCode(_ text: String, lines: [String]) -> Bool {
        if text.contains("```") { return true }
        let hasBrace = text.contains("{") || text.contains("}")
        let hasSemicolon = text.contains(";")
        if hasBrace && hasSemicolon { return true }
        guard lines.count >= 2 else { return false }
        // An indented block *and* a language keyword. Both are required: prose
        // is sometimes indented (quotes, lists) and sometimes contains the word
        // "return", but rarely both at once.
        let indented = lines.filter { $0.hasPrefix(" ") || $0.hasPrefix("\t") }.count
        guard indented >= 1 else { return false }
        let keywords = ["func ", "def ", "class ", "function ", "return ", "import ", "var ", "let ", "=> ", "public ", "private "]
        return keywords.contains { text.contains($0) }
    }

    /// JSON is decided by the parser, not by a heuristic — the whole point of
    /// JSON is that validity is decidable.
    private static func isJSON(_ text: String) -> Bool {
        let first = text.first
        guard first == "{" || first == "[" else { return false }
        let last = text.last
        guard last == "}" || last == "]" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    private static func isYAML(_ lines: [String]) -> Bool {
        guard lines.count >= 2 else { return false }
        var matches = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.hasPrefix("- ") { matches += 1; continue }
            if trimmed.range(of: "^[A-Za-z0-9_.-]+:( .*)?$", options: .regularExpression) != nil { matches += 1 }
        }
        return matches >= 2
    }

    private static func isPath(_ text: String) -> Bool {
        guard text.contains("/") else { return false }
        return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../")
    }

    /// `#RGB` / `#RGBA` / `#RRGGBB` / `#RRGGBBAA`, with or without the hash.
    ///
    /// Without the hash a hex letter is required, otherwise `1234` (a perfectly
    /// ordinary number) would be classified as a colour and stolen from `value`.
    /// The leading `#` is REQUIRED. A bare hex run of 6–8 chars is far more often
    /// an abbreviated git SHA or a hex identifier (`deadbeef`, `a1b2c3d4`,
    /// `cafebabe`) than a colour, and mis-labelling one as `color` offers no
    /// useful glance-action (design principle 4) — blank is the honest answer.
    private static func isColor(_ text: String) -> Bool {
        guard text.hasPrefix("#") else { return false }
        let body = text.dropFirst()
        guard [3, 4, 6, 8].contains(body.count) else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }

    /// A single-token number, amount or identifier — something you paste into a
    /// field. Requires a digit, so a lone prose word never becomes a `value`.
    private static func isValue(_ text: String) -> Bool {
        guard text.count <= 64, text.contains(where: { $0.isNumber }) else { return false }
        if text.range(of: "^[+-]?[$£€¥]?[0-9][0-9,._]*%?$", options: .regularExpression) != nil { return true }
        if text.range(of: "^[0-9][0-9,._]*[$£€¥%]?$", options: .regularExpression) != nil { return true }
        // Identifier-ish: alphanumerics with internal dashes/underscores.
        if text.range(of: "^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$", options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Byte helpers
    //
    // Everything below operates on UTF-8 bytes. That is both the fastest
    // representation and a safe one: every multi-byte scalar's continuation
    // bytes are ≥ 0x80, so they can never be mistaken for an ASCII delimiter,
    // digit or letter. No index arithmetic here can walk off the end.

    struct CharsetMask {
        private let table: [Bool]
        init(_ characters: String) { self.init(bytes: Array(characters.utf8)) }
        init(bytes: [UInt8]) {
            var table = [Bool](repeating: false, count: 256)
            for byte in bytes { table[Int(byte)] = true }
            self.table = table
        }
        func contains(_ byte: UInt8) -> Bool { table[Int(byte)] }

        static let digit = CharsetMask("0123456789")
        static let upper = CharsetMask("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        static let letter = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        static let hex = CharsetMask("0123456789abcdefABCDEF")
        static let upperDigit = CharsetMask("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        static let digitOrUpper = upperDigit
        static let alnum = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        static let alnumUnderscore = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        static let alnumDash = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        static let alnumDashUnderscore = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        static let alnumDashDot = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        static let base64URL = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=")
        static let credential = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+/=.~")
        static let emailLocal = CharsetMask("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
        static let dashUnderscore = CharsetMask("-_")
        static let trailingPunctuation = CharsetMask(",.;:!?)>\"'")
        static let leadingPunctuation = CharsetMask("(<\"'")
    }

    /// A digit run, plus how it was grouped — the group *shape* is what tells a
    /// phone number apart from a timestamp.
    struct DigitRun {
        let digits: [Int]
        let range: Range<Int>
        /// Sizes of the digit groups, e.g. `(415) 555-2671` → `[3, 3, 4]`.
        let groups: [Int]
        let plusPrefixed: Bool
        var grouped: Bool { groups.count > 1 }
    }

    /// Maximal runs of digits, tolerating up to **two** consecutive internal
    /// separators (space, `-`, `.`, `(`, `)`) — how humans write cards and phone
    /// numbers, including `(415) 555-2671` with its `") "` pair.
    static func digitGroupRuns(_ bytes: [UInt8]) -> [DigitRun] {
        var runs: [DigitRun] = []
        var index = 0
        let separators: Set<UInt8> = [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "."),
                                      UInt8(ascii: "("), UInt8(ascii: ")")]
        while index < bytes.count {
            guard CharsetMask.digit.contains(bytes[index]) else { index += 1; continue }
            let start = index
            var digits: [Int] = []
            var groups: [Int] = []
            var currentGroup = 0
            var cursor = index
            while cursor < bytes.count {
                if CharsetMask.digit.contains(bytes[cursor]) {
                    digits.append(Int(bytes[cursor] - UInt8(ascii: "0")))
                    currentGroup += 1
                    cursor += 1
                    continue
                }
                // Look ahead over at most two separators for the next digit.
                var lookahead = cursor
                var separatorCount = 0
                while lookahead < bytes.count, separators.contains(bytes[lookahead]), separatorCount < 2 {
                    lookahead += 1
                    separatorCount += 1
                }
                if separatorCount > 0, lookahead < bytes.count, CharsetMask.digit.contains(bytes[lookahead]) {
                    groups.append(currentGroup)
                    currentGroup = 0
                    cursor = lookahead
                } else {
                    break
                }
            }
            groups.append(currentGroup)
            let plusPrefixed = start > 0 && bytes[start - 1] == UInt8(ascii: "+")
            runs.append(DigitRun(digits: digits, range: start..<cursor, groups: groups, plusPrefixed: plusPrefixed))
            index = cursor
        }
        return runs
    }

    /// Maximal runs of *contiguous* digits — no separators tolerated.
    static func contiguousDigitRuns(_ bytes: [UInt8]) -> [DigitRun] {
        var runs: [DigitRun] = []
        var index = 0
        while index < bytes.count {
            guard CharsetMask.digit.contains(bytes[index]) else { index += 1; continue }
            let start = index
            var digits: [Int] = []
            while index < bytes.count, CharsetMask.digit.contains(bytes[index]) {
                digits.append(Int(bytes[index] - UInt8(ascii: "0")))
                index += 1
            }
            let plusPrefixed = start > 0 && bytes[start - 1] == UInt8(ascii: "+")
            runs.append(DigitRun(digits: digits, range: start..<index, groups: [digits.count],
                                 plusPrefixed: plusPrefixed))
        }
        return runs
    }

    /// Whitespace-delimited token ranges.
    static func whitespaceTokens(_ bytes: [UInt8]) -> [Range<Int>] {
        var tokens: [Range<Int>] = []
        var index = 0
        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        while index < bytes.count {
            guard !isSpace(bytes[index]) else { index += 1; continue }
            let start = index
            while index < bytes.count, !isSpace(bytes[index]) { index += 1 }
            tokens.append(start..<index)
        }
        return tokens
    }

    /// Byte ranges of `http(s)://…` spans.
    static func urlSpans(_ lowered: [UInt8]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        let marker = Array("http".utf8)
        let scheme = Array("://".utf8)
        var index = 0
        while index + marker.count < lowered.count {
            // Cheapest possible rejection first: almost no byte is 'h'.
            if lowered[index] == marker[0],
               lowered[index + 1] == marker[1], lowered[index + 2] == marker[2], lowered[index + 3] == marker[3],
               contains(lowered[index..<min(lowered.count, index + 10)], pattern: scheme) {
                var end = index
                while end < lowered.count, lowered[end] > 0x20, lowered[end] != UInt8(ascii: "\"") { end += 1 }
                spans.append(index..<end)
                index = end
            } else {
                index += 1
            }
        }
        return spans
    }

    static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") ? $0 + 32 : $0 }
    }

    /// Naive substring search. Generic over `Array`/`ArraySlice` so callers never
    /// have to copy a slice into a fresh array just to search it.
    static func contains<C: RandomAccessCollection>(_ haystack: C, pattern: [UInt8]) -> Bool
        where C.Element == UInt8, C.Index == Int {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return false }
        let limit = haystack.endIndex - pattern.count
        var index = haystack.startIndex
        while index <= limit {
            var offset = 0
            while offset < pattern.count, haystack[index + offset] == pattern[offset] { offset += 1 }
            if offset == pattern.count { return true }
            index += 1
        }
        return false
    }

    /// Substring search with alphanumeric word boundaries, so `code` does not
    /// match inside `barcode` or `decoded`.
    static func containsWord<C: RandomAccessCollection>(_ haystack: C, _ pattern: [UInt8]) -> Bool
        where C.Element == UInt8, C.Index == Int {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return false }
        let limit = haystack.endIndex - pattern.count
        var index = haystack.startIndex
        while index <= limit {
            var offset = 0
            while offset < pattern.count, haystack[index + offset] == pattern[offset] { offset += 1 }
            if offset == pattern.count {
                let beforeOK = index == haystack.startIndex || !CharsetMask.alnum.contains(haystack[index - 1])
                let afterIndex = index + pattern.count
                let afterOK = afterIndex >= haystack.endIndex || !CharsetMask.alnum.contains(haystack[afterIndex])
                if beforeOK && afterOK { return true }
            }
            index += 1
        }
        return false
    }

    static func hasPrefix(_ slice: ArraySlice<UInt8>, _ prefix: [UInt8]) -> Bool {
        guard slice.count >= prefix.count else { return false }
        var index = slice.startIndex
        for byte in prefix {
            if slice[index] != byte { return false }
            index += 1
        }
        return true
    }

    /// True when the byte before `index` is not alphanumeric (start of a token).
    static func isBoundary(_ bytes: [UInt8], before index: Int) -> Bool {
        index == 0 || !CharsetMask.alnum.contains(bytes[index - 1])
    }

    /// True when the byte at `index` is not alphanumeric (end of a token).
    static func isBoundary(_ bytes: [UInt8], after index: Int) -> Bool {
        index >= bytes.count || !CharsetMask.alnum.contains(bytes[index])
    }
}

// MARK: - Keccak-256

/// Keccak-256 (the original padding, *not* NIST SHA3-256), needed by EIP-55.
///
/// CryptoKit ships SHA-2 but no Keccak, and EIP-55 is defined against Keccak, so
/// the permutation lives here. It is a pure function over bytes — no allocation
/// beyond two small fixed arrays, no state shared between calls.
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotationOffsets: [UInt64] = [
        1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14,
        27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44,
    ]
    private static let piLane: [Int] = [
        10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4,
        15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1,
    ]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        let rate = 136
        var message = input
        message.append(0x01)
        while message.count % rate != 0 { message.append(0x00) }
        message[message.count - 1] |= 0x80

        var state = [UInt64](repeating: 0, count: 25)
        var offset = 0
        while offset < message.count {
            for lane in 0..<(rate / 8) {
                var value: UInt64 = 0
                for byte in 0..<8 {
                    value |= UInt64(message[offset + lane * 8 + byte]) << (8 * UInt64(byte))
                }
                state[lane] ^= value
            }
            permute(&state)
            offset += rate
        }

        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for lane in 0..<4 {
            for byte in 0..<8 {
                digest.append(UInt8((state[lane] >> (8 * UInt64(byte))) & 0xff))
            }
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }

    private static func permute(_ state: inout [UInt64]) {
        var lanes = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // θ
            for index in 0..<5 {
                lanes[index] = state[index] ^ state[index + 5] ^ state[index + 10]
                    ^ state[index + 15] ^ state[index + 20]
            }
            for index in 0..<5 {
                let temp = lanes[(index + 4) % 5] ^ rotateLeft(lanes[(index + 1) % 5], 1)
                for column in stride(from: 0, to: 25, by: 5) { state[column + index] ^= temp }
            }
            // ρ and π
            var carry = state[1]
            for index in 0..<24 {
                let lane = piLane[index]
                let saved = state[lane]
                state[lane] = rotateLeft(carry, rotationOffsets[index])
                carry = saved
            }
            // χ
            for row in stride(from: 0, to: 25, by: 5) {
                for index in 0..<5 { lanes[index] = state[row + index] }
                for index in 0..<5 {
                    state[row + index] ^= ~lanes[(index + 1) % 5] & lanes[(index + 2) % 5]
                }
            }
            // ι
            state[0] ^= roundConstants[round]
        }
    }
}
