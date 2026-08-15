import SwiftUI

// MARK: - Signals

/// One thing a clip can *say about itself* — and, one-for-one, one thing the
/// filter menu can constrain by.
///
/// This type is the single source of truth behind design principle 4: **every
/// emitted value maps to a glance-action**. A chip on a card and an entry in the
/// filter menu are literally the same `ClipSignal` value, so a signal cannot be
/// rendered without also being filterable, and cannot be offered as a filter
/// without being something a card actually shows. Adding a case obliges you to
/// give it a title, a glyph, a spoken label and a predicate — which is exactly
/// the bar the audit said decorative tags never cleared.
///
/// Note the deliberate absence of any "safe"/"public"/"clean" case: `ClipFlags`
/// is presence-only by construction (design principle 3), and the UI must not
/// invent a positive label the detectors cannot prove.
enum ClipSignal: Hashable, Sendable {
    /// A protective detector verdict (§3.1–3.3, §3.8, §3.9). Always a *single*
    /// bit drawn from ``ClipFlags/allKnown`` — never a composite.
    case flag(ClipFlags)
    /// A §3.4 structural shape ("url", "json", "path", …). `kind == .text` only.
    case shape(String)
    /// The friendly name of the originating app (§3.5).
    case source(String)
    /// A behavioural value from §3.6 (`sticky`/`throwaway`/`fresh`) or §3.7
    /// (`to-open`/`read-later`/`reference`). They share a group because they are
    /// the same question — "what should I do with this next?" — asked of two
    /// different clip kinds, and no clip can carry both.
    case lifecycle(String)
    /// One of the user's own labels (§3.10). Model-immune, always trusted.
    case userTag(String)
}

extension ClipSignal {
    /// Facet grouping. Values inside a group OR, groups AND — the same semantics
    /// the tag-dimension facets already use, so the filter menu behaves
    /// uniformly whichever section a user picks from.
    enum Group: Hashable, Sendable, CaseIterable {
        case sensitivity, shape, source, lifecycle, userTag
    }

    var group: Group {
        switch self {
        case .flag:      return .sensitivity
        case .shape:     return .shape
        case .source:    return .source
        case .lifecycle: return .lifecycle
        case .userTag:   return .userTag
        }
    }

    /// How loudly the chip must read. Only `protective`/`caution` get warning
    /// colour, and both also carry a glyph and a spoken label so colour is never
    /// the sole carrier of "sensitive" (WCAG 1.4.1).
    enum Tier: Hashable, Sendable {
        /// A high-confidence protective verdict. Reads as a warning.
        case protective
        /// Protective but low-confidence (`secretEntropy`) or short-lived
        /// (`otp`). Warned about, never acted on destructively (§3.1).
        case caution
        /// True but harmless — §3.3 splits email/phone out precisely so the
        /// everyday case does not train users to ignore red chips.
        case informational
        /// Neutral facts: shape, source, lifecycle, the user's own labels.
        case neutral
    }

    /// Short chip text. Kept terse because it renders at 9pt on a 3-slot row;
    /// the long form lives in ``spoken``.
    var title: String {
        switch self {
        case .flag(let flag):     return Self.flagCopy(flag).title
        case .shape(let value):   return value
        case .source(let value):  return value
        case .lifecycle(let value): return value
        case .userTag(let value): return "#" + value
        }
    }

    var symbol: String {
        switch self {
        case .flag(let flag): return Self.flagCopy(flag).symbol
        case .shape(let value):
            switch value {
            case "url":     return "link"
            case "command": return "terminal"
            case "code":    return "chevron.left.forwardslash.chevron.right"
            case "json", "yaml": return "curlybraces"
            case "path":    return "folder"
            case "color":   return "paintpalette"
            case "value":   return "number"
            default:        return "textformat"
            }
        case .source:
            return "macwindow"
        case .lifecycle(let value):
            switch value {
            case "sticky":     return "pin"
            case "fresh":      return "sparkles"
            case "throwaway":  return "trash"
            case "to-open":    return "arrow.up.forward.app"
            case "read-later": return "book"
            case "reference":  return "text.quote"
            default:           return "clock"
            }
        case .userTag:
            return "tag"
        }
    }

    var tier: Tier {
        switch self {
        case .flag(let flag): return Self.flagCopy(flag).tier
        default:              return .neutral
        }
    }

    /// The VoiceOver phrasing. Every chip has one, and every protective chip
    /// states its severity in *words* — a screen-reader user must learn nothing
    /// from the red capsule they cannot see.
    var spoken: String {
        switch self {
        case .flag(let flag):       return Self.flagCopy(flag).spoken
        case .shape(let value):     return "Shape: \(value)"
        case .source(let value):    return "Copied from \(value)"
        case .lifecycle(let value): return "Status: \(value)"
        case .userTag(let value):   return "Your tag: \(value)"
        }
    }

    /// The menu wording, which can afford to be longer than the chip.
    var menuTitle: String {
        switch self {
        case .flag(let flag):       return Self.flagCopy(flag).menu
        case .userTag(let value):   return value
        default:                    return title
        }
    }

    /// Whether `item` carries this signal.
    ///
    /// This is what makes a chip *actionable* rather than decorative: the same
    /// predicate that put a chip on a card selects the clips when that chip's
    /// filter is switched on, so "filter by what I can see" is true by
    /// construction rather than by two implementations agreeing.
    ///
    /// - Parameter now: injected so age-derived signals are testable without
    ///   wall-clock, exactly as `DerivedTags` does.
    func matches(_ item: ClipItem, now: Date = Date()) -> Bool {
        switch self {
        case .flag(let flag):
            // `isEmpty` guard: `contains([])` is vacuously true for an OptionSet,
            // which would make an empty signal match every clip — i.e. silently
            // label benign clips as sensitive. Fail closed instead.
            return !flag.isEmpty && item.flags.contains(flag)
        case .shape(let value):
            return item.shape == value
        case .source(let value):
            return DerivedTags.source(item) == value
        case .lifecycle(let value):
            return DerivedTags.lifecycle(item, now: now) == value
                || DerivedTags.linkDisposition(item, now: now) == value
        case .userTag(let value):
            return item.userTags.contains(value)
        }
    }

    /// Copy for one protective flag, in one place so the chip, the menu entry
    /// and the spoken label can never drift apart.
    /// UI-only sentinel for "this clip carries a protective bit this build does
    /// not recognise". Uses the high bit so it can never collide with a real
    /// persisted flag; it is never written to disk, only rendered.
    static let unrecognisedProtective = ClipFlags(rawValue: 1 << 62)

    private static func flagCopy(_ flag: ClipFlags) -> (title: String, menu: String, symbol: String, tier: Tier, spoken: String) {
        switch flag {
        case Self.unrecognisedProtective:
            return ("sensitive", "Sensitive (unrecognised)", "exclamationmark.shield.fill", .protective,
                    "Sensitive: flagged by a newer version of Cliphoard")
        case .secret:
            return ("secret", "Secrets", "key.fill", .protective,
                    "Sensitive: contains a credential")
        case .secretEntropy:
            return ("high entropy", "Possible secrets", "key", .caution,
                    "Possibly sensitive: high-entropy token, low confidence")
        case .financial:
            return ("financial", "Financial", "creditcard.fill", .protective,
                    "Sensitive: contains a financial identifier")
        case .piiSensitive:
            return ("personal ID", "Personal IDs", "exclamationmark.shield.fill", .protective,
                    "Sensitive: contains a national identifier or postal address")
        case .pii:
            return ("contact", "Contact details", "person.crop.circle", .informational,
                    "Contains an email address or phone number")
        case .otp:
            return ("one-time code", "One-time codes", "clock.badge.exclamationmark", .caution,
                    "Sensitive: one-time code or sign-in link, expires quickly")
        case .quarantined:
            return ("password app", "From a password app", "lock.shield.fill", .protective,
                    "Sensitive: copied from a password manager")
        default:
            // A bit written by a NEWER build (the raw value is deliberately never
            // masked down — see `ClipItem.flags`). We cannot name it, so we say
            // the only honest thing and treat it as protective. Fail closed.
            let name = flag.names.first ?? "sensitive"
            return (name, name.capitalized, "exclamationmark.triangle.fill", .protective,
                    "Sensitive: \(name)")
        }
    }
}

// MARK: - Chips

/// Builds the certainty-ordered chip row for a clip.
///
/// Pure and store-free (same contract as `Detectors`/`DerivedTags`), so the row
/// is unit-testable without a view and cheap enough to evaluate for every
/// visible card on every render.
///
/// **Ordering is the whole point** (principle 1: cheapest-and-surest first;
/// principle 6: ≤3, ordered by certainty):
///
/// 1. protective flags — deterministic detector verdicts, and the only chips
///    whose absence would actually cost the user something;
/// 2. shape and source — recorded/structural facts, margin ≈ 1.0;
/// 3. lifecycle and link-disposition — real behaviour, but read through
///    thresholds the spec still calls uncalibrated placeholders;
/// 4. the user's own labels — trusted, but they are already the thing the user
///    typed, so they yield the scarce slots to what the user does *not* know.
///
/// An empty result is the **common, correct** outcome (principle 2). There is no
/// filler chip and no "safe" chip; a blank row means nothing fired, which is not
/// the same claim as "this is safe".
enum ClipChips {
    /// Hard cap on chips rendered on a card, including the "+N" overflow chip
    /// (principle 6). Enforced here rather than at the call site so no view can
    /// render a fourth.
    static let maxChips = 3

    /// Every signal this clip carries, in certainty order and **uncapped** — the
    /// supercard shows the full list, the card shows a prefix of it.
    static func chips(for item: ClipItem, now: Date = Date()) -> [ClipSignal] {
        var chips: [ClipSignal] = []

        // (a) Protective flags, in `protectiveOrder`: loudest tier first, then
        // spec §3 cluster order inside a tier. Tier before spec order matters —
        // sorting §3.3 `pii` (an informational badge) ahead of §3.9
        // `quarantined` would let a harmless "contact" chip push a real warning
        // off a three-slot row.
        for flag in protectiveOrder where item.flags.contains(flag) {
            chips.append(.flag(flag))
        }
        // Fail CLOSED on bits this build does not know. `flags` is persisted and
        // deliberately preserves unknown bits written by a newer version — but
        // rendering only the known ones means a future protective flag would show
        // NOTHING, silently downgrading a warned clip to an unmarked one. Any
        // unrecognised bit still raises a generic caution chip.
        let knownMask = ClipFlags.allKnown.reduce(into: ClipFlags()) { $0.insert($1.flag) }
        if !item.flags.subtracting(knownMask).isEmpty {
            chips.append(.flag(ClipSignal.unrecognisedProtective))
        }

        // (b) Structure, then provenance. Both are exact facts about the clip;
        // shape leads because it describes the content itself while the source
        // app describes where it came from.
        if let shape = item.shape, !shape.isEmpty { chips.append(.shape(shape)) }
        if let source = DerivedTags.source(item) { chips.append(.source(source)) }

        // (c) Behaviour. `linkDisposition` before `lifecycle`, matching the
        // certainty order `DerivedTags.all` already documents (its strongest
        // value, `reference`, is deterministic pattern matching).
        if let disposition = DerivedTags.linkDisposition(item, now: now) {
            chips.append(.lifecycle(disposition))
        }
        if let lifecycle = DerivedTags.lifecycle(item, now: now) {
            chips.append(.lifecycle(lifecycle))
        }

        // (d) The user's own labels, in the order they applied them.
        for tag in item.userTags { chips.append(.userTag(tag)) }

        return chips
    }

    /// What the card actually draws: the chips that fit, plus how many are
    /// hidden behind the "+N" affordance.
    ///
    /// The row never exceeds ``maxChips`` *elements*, so when there is overflow
    /// the "+N" chip takes the last slot rather than becoming a fourth. Nothing
    /// becomes unreachable: "+N" opens the supercard, which lists them all.
    static func row(for item: ClipItem, now: Date = Date()) -> (shown: [ClipSignal], overflow: Int) {
        let all = chips(for: item, now: now)
        if all.count <= maxChips { return (all, 0) }
        let shown = Array(all.prefix(maxChips - 1))
        return (shown, all.count - shown.count)
    }

    /// Capsule colours for a tier, shared by every surface that draws a chip so
    /// a red "secret" capsule means the same thing on a card, in a dense row and
    /// in the spotlight preview.
    ///
    /// Protective tiers use the system semantic red and orange rather than a
    /// theme token: they must keep reading as *danger* under every preset,
    /// including the ones that repaint the accent.
    static func colors(for tier: ClipSignal.Tier) -> (fill: Color, text: Color) {
        switch tier {
        case .protective:    return (Color.red.opacity(0.18), Color.red)
        case .caution:       return (Color.orange.opacity(0.20), Color.orange)
        case .informational: return (Theme.t.tagFill, Color.secondary)
        case .neutral:       return (Theme.t.tagFill, Theme.t.tagText)
        }
    }

    /// Protective flags in render order: `protective` tier (spec §3.1, §3.2,
    /// §3.3-sensitive, §3.9), then `caution` (§3.8, then the low-confidence
    /// Tier-2 entropy bit §3.1 forbids from driving destructive action), then
    /// the purely `informational` §3.3 badge.
    ///
    /// Drawn from `ClipFlags.allKnown` bits only — there is deliberately no way
    /// to spell a positive "safe" label here.
    private static let protectiveOrder: [ClipFlags] = [
        .secret, .financial, .piiSensitive, .quarantined, .otp, .secretEntropy, .pii
    ]
}

// MARK: - Card

/// A single clipboard entry rendered as a Paste-style card.
struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let storeDir: URL
    var onActivate: () -> Void
    var onInspect: () -> Void
    var onInspectTags: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void
    /// Whether the store will actually accept a deletion right now.
    ///
    /// NOT defaulted, deliberately. This view holds no store (only `storeDir`), so the
    /// fact has to be passed in — and a default of `true` would be a skip-hatch: the next
    /// call site that forgets ships a live Delete on a frozen store, which is exactly how
    /// the primary Delete came to be the one control left ungated while three secondary
    /// ones were covered. Without a default the compiler makes each call site answer.
    let historyIsMutable: Bool

    @State private var hovering = false

    /// Decoded thumbnails keyed by file name, so the body doesn't re-decode the
    /// image on every hover/selection re-evaluation (audit BL-09/H8).
    private static let imageCache = NSCache<NSString, NSImage>()

    /// Loads the downsampled `<uuid>-thumb.png` if it exists, else the full-res
    /// original, decoding at most once per file name thanks to `imageCache`.
    private func cachedImage(for file: String) -> NSImage? {
        let thumbName = (file as NSString).deletingPathExtension + "-thumb.png"
        let thumbURL = storeDir.appendingPathComponent(thumbName)
        let useThumb = FileManager.default.fileExists(atPath: thumbURL.path)
        let name = useThumb ? thumbName : file
        if let cached = Self.imageCache.object(forKey: name as NSString) { return cached }
        let url = useThumb ? thumbURL : storeDir.appendingPathComponent(file)
        // Payloads (and their thumbnails) are sealed at rest — read the bytes,
        // decrypt via Crypto.open, then decode. Legacy plaintext PNGs pass
        // through Crypto.open untouched, so old histories still render.
        guard let stored = try? Data(contentsOf: url),
              let decoded = Crypto.open(stored),
              let image = NSImage(data: decoded) else { return nil }
        Self.imageCache.setObject(image, forKey: name as NSString)
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            // The slot states the invariant next to the fixed size that depends
            // on it: content never displaces chrome. `Color.clear` accepts any
            // proposal, so this VStack's size comes from the chrome plus what is
            // left, never from what `content` decided it wanted.
            //
            // A backstop, not the fix. Every current content kind renders
            // byte-identically with and without it, and no test requires it,
            // because what it prevents is a content kind nobody has written yet.
            // It must not become load-bearing: on its own — with the image site
            // reverted — it re-anchors every photo crop to top-leading, which
            // `ClipCardChromeTests.testTheCropStaysCentredOnThePicture` refuses.
            Color.clear
                .overlay(alignment: .topLeading) { content }
                .clipped()
            tagRow
            footer
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .background(Theme.cardBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : (hovering ? Theme.t.borderHover : Theme.t.border),
                              lineWidth: selected ? Theme.t.selectedBorderWidth : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 10 : 5, y: 3)
        // No scaleEffect: shrinking unselected cards shifted their header baselines
        // out of row alignment. Selection reads via the ring + shadow instead.
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Paste") { onActivate() }
            Button("Inspect") { onInspect() }
            Button(item.pinned ? "Unpin" : "Pin") { onPin() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
                .disabled(!historyIsMutable)   // refuses while frozen; do not look live
        }
        .help(item.preview)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue(item.characterCountLabel)
        // Command-Return is named here because `accessibilityElement(children:
        // .combine)` above folds the expand button into this one element, so a
        // VoiceOver user cannot reach the button itself. The shortcut is the
        // route that remains (AppDelegate routes ⌘-Return to `inspectSelection`).
        .accessibilityHint("Press Return to paste, Command-C to copy, "
                           + "Command-Return to inspect")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A spoken label combining the clip's chips, its kind, its source app, and a
    /// short preview.
    ///
    /// The chips are folded in here — not left to the per-chip
    /// `accessibilityLabel`s — because the card is an
    /// `accessibilityElement(children: .combine)` with an explicit label, which
    /// replaces everything its children would have said. Protective chips lead
    /// so a VoiceOver user hears "Sensitive: contains a credential" *before* the
    /// preview text, which is the only ordering that can still change what they
    /// do next.
    private var accessibilityLabelText: String {
        let source = item.sourceApp ?? item.kind.title
        let preview = String(item.preview.prefix(80))
        let row = chipRow
        // Order is already certainty-descending, and protective chips sort first.
        var parts = row.shown.map(\.spoken)
        if row.overflow > 0 { parts.append("\(row.overflow) more tag\(row.overflow == 1 ? "" : "s")") }
        parts.append(contentsOf: ["\(item.kind.title)", source, preview])
        return parts.joined(separator: ", ")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(item.sourceApp ?? item.kind.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.pin)
            }
            if hovering || selected {
                Button(action: onInspect) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                // The bare 9pt glyph is an 11x11pt target (121pt²) on a card in
                // a dense strip. This makes it 22x14 (308pt²) for nothing: 14 is
                // under the header's 28pt, and the `Spacer` absorbs the width.
                // The obvious alternative, `.padding(5)`, grows the header to
                // 35pt and takes 7pt out of every card's image slot forever.
                .frame(width: 22, height: 14)
                .contentShape(Rectangle())
                .help("Inspect clip (Command-Return)")
                .accessibilityLabel("Inspect clip")
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let file = item.payloadFile,
               let nsImage = cachedImage(for: file) {
                // `Color.clear` is the size authority here, not the picture. An
                // aspect-FILL image REPORTS its filled size — it exceeds the
                // proposal on one axis by construction — and a flexible frame
                // with an infinite maximum does not clamp that: it reports
                // `max(proposal, childSize)`. So the picture, not the chrome,
                // used to size the card's VStack, the fixed frame below CENTRED
                // the oversized stack, and `clipShape` cut the header and footer
                // off. (`.clipped()` never helped: it clipped the image to its
                // own oversized bounds.) Sizing the slot from a view that accepts
                // any proposal, and hanging the picture off it as an overlay,
                // keeps the overshoot inside the overlay where `.clipped()` can
                // actually cut it. The overlay is centred, which is what makes
                // this a centre crop rather than a top-left one.
                Color.clear
                    .overlay(
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipped()
            } else {
                placeholder(symbol: "photo")
            }
        case .color:
            ZStack {
                Theme.color(fromHex: item.colorHex ?? "#000000")
                Text(item.colorHex ?? "")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
        case .file:
            VStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text((item.filePath as NSString?)?.lastPathComponent ?? "File")
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .lineLimit(6)
            }
            .padding(10)
        case .text:
            Text(item.text)
                .font(.system(size: 12))
                .lineLimit(11)
                .multilineTextAlignment(.leading)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func placeholder(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The chips this card renders, computed once per body pass.
    ///
    /// Not cached across renders on purpose: the inputs are two stored fields
    /// plus `Date()`, and a `fresh` clip must stop claiming to be fresh without
    /// anyone invalidating anything (design §5 — derived at render time).
    private var chipRow: (shown: [ClipSignal], overflow: Int) { ClipChips.row(for: item) }

    @ViewBuilder private var tagRow: some View {
        // At most three elements, certainty-ordered, and **frequently empty** —
        // a blank row is the correct, common outcome (principle 2), not a gap to
        // be filled. The old row showed the first two raw auto-tag strings
        // whether or not they meant anything; the audit's finding was that those
        // strings were decoration, so there is no fallback here.
        //
        // Every kind is eligible now: the old row was suppressed for images and
        // colours because an embedding caption on a screenshot was noise, but a
        // screenshot copied out of a password manager is exactly the case that
        // must show its badge.
        let row = chipRow
        if !row.shown.isEmpty {
            HStack(spacing: 4) {
                ForEach(row.shown, id: \.self) { signal in chip(signal) }
                if row.overflow > 0 {
                    Button(action: onInspectTags) {
                        plainChip("+\(row.overflow)", style: ClipChips.colors(for: .neutral))
                    }
                    .buttonStyle(.plain)
                    .help("Show all tags")
                    .accessibilityLabel("Show \(row.overflow) more tag\(row.overflow == 1 ? "" : "s")")
                }
                Spacer(minLength: 0)
            }
            // Chips are `.fixedSize()`, so a full row can want more width than
            // the card has: "command" + "Google Chrome" + "fresh" measures 225pt
            // against the 200pt available. That widened the same VStack and slid
            // every row on the card 12pt left — on TEXT cards as much as image
            // ones, and from data the user does not control (a detector flag, the
            // source app's name). The clamp keeps the row's REPORTED width at
            // what the card can offer; the overhang is cut by the card's own
            // `clipShape`.
            //
            // What that gives up is bounded by the row's own ordering: chips are
            // certainty-descending and `+N` always takes the last slot, so the
            // element left overhanging is the least certain chip, or the trailing
            // curve of the `+N` capsule (6pt of it on the widest protective row
            // this vocabulary can build). Never a protective chip, and nothing
            // becomes unreachable — `+N` opens the supercard.
            //
            // Coupled to the horizontal padding below: change one, change both.
            .frame(maxWidth: Theme.cardWidth - 20, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    /// One signal chip: glyph + short label. The glyph and the spoken label are
    /// what carry "sensitive"; the tint only reinforces it, so the meaning
    /// survives greyscale and colour-blindness (WCAG 1.4.1).
    private func chip(_ signal: ClipSignal) -> some View {
        let colors = ClipChips.colors(for: signal.tier)
        return HStack(spacing: 3) {
            Image(systemName: signal.symbol)
                .font(.system(size: 8, weight: .semibold))
            Text(signal.title)
                .font(.system(size: 9, weight: signal.tier == .neutral ? .medium : .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(colors.fill, in: Capsule())
        .foregroundStyle(colors.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(signal.spoken)
    }

    private func plainChip(_ text: String, style colors: (fill: Color, text: Color)) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colors.fill, in: Capsule())
            .foregroundStyle(colors.text)
    }

    private var footer: some View {
        HStack {
            Text(item.characterCountLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)   // was .tertiary — failed AA on the card material
            Spacer()
            Text(item.createdAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
