import SwiftUI
import AppKit

/// The visual tokens that define one theme preset. Most text stays semantic
/// (`.primary`/`.secondary`) and adapts via the forced `scheme`; presets mainly
/// vary accent, surfaces, borders, and (for flat themes) fills.
struct ThemeTokens {
    var accent: Color
    var pin: Color                                   // distinct from accent (selection vs pin)
    var cardWidth: CGFloat = 220
    var cardHeight: CGFloat = 250
    var cornerRadius: CGFloat = 12
    var usesMaterials: Bool = true                   // vibrancy vs flat fills
    var barMaterial: NSVisualEffectView.Material = .hudWindow
    var cardMaterial: NSVisualEffectView.Material = .contentBackground
    var barFill: Color = .clear                      // used when !usesMaterials
    var cardFill: Color = .clear
    var border: Color = Color.primary.opacity(0.08)
    var borderHover: Color = Color.primary.opacity(0.18)
    var selectedBorderWidth: CGFloat = 2.5
    var tagFill: Color = Color.primary.opacity(0.08)
    var tagText: Color = .secondary
    var scheme: ColorScheme? = nil                   // force light/dark, nil = follow system
    var fontDesign: Font.Design = .default
}

/// Selectable theme presets (the visual-QA bake-off shortlist). `system` is the
/// default and preserves the original look so nothing changes unless chosen.
enum ThemePreset: String, CaseIterable, Identifiable {
    case system, swiss, glass, highContrast, paper
    // Popular code-editor palettes (One Dark, Dracula, …).
    case oneDark, dracula, tokyoNight, catppuccin, gruvbox, monokai, nightOwl
    // Popular light palettes.
    case solarizedLight, githubLight, catppuccinLatte, rosePineDawn, oneLight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:       return "Automatic (One Dark / Swiss)"
        case .swiss:        return "Swiss Grayscale"
        case .glass:        return "Midnight Glass"
        case .highContrast: return "High Contrast"
        case .paper:        return "Paper & Ink"
        case .oneDark:      return "One Dark"
        case .dracula:      return "Dracula"
        case .tokyoNight:   return "Tokyo Night"
        case .catppuccin:   return "Catppuccin Mocha"
        case .gruvbox:      return "Gruvbox Dark"
        case .monokai:      return "Monokai"
        case .nightOwl:     return "Night Owl"
        case .solarizedLight:  return "Solarized Light"
        case .githubLight:     return "GitHub Light"
        case .catppuccinLatte: return "Catppuccin Latte"
        case .rosePineDawn:    return "Rosé Pine Dawn"
        case .oneLight:        return "One Light"
        }
    }

    /// A flat light editor theme: paper-white background, a faintly tinted card
    /// panel, signature accent, and a muted secondary color. Dark text comes from
    /// the forced light scheme.
    private static func lightEditor(bg: String, panel: String, accent: String,
                                    pin: String, muted: String) -> ThemeTokens {
        ThemeTokens(
            accent: Theme.color(fromHex: accent), pin: Theme.color(fromHex: pin),
            cornerRadius: 10, usesMaterials: false,
            barFill: Theme.color(fromHex: bg), cardFill: Theme.color(fromHex: panel),
            border: Color.black.opacity(0.10), borderHover: Color.black.opacity(0.22),
            selectedBorderWidth: 2,
            tagFill: Color.black.opacity(0.05), tagText: Theme.color(fromHex: muted),
            scheme: .light)
    }

    /// A flat dark code-editor theme: solid editor background, slightly lifted
    /// panel for cards, the palette's signature accent, and a muted comment color
    /// for secondary chrome. Semantic text adapts via the forced dark scheme.
    private static func editor(bg: String, panel: String, accent: String,
                               pin: String, muted: String) -> ThemeTokens {
        ThemeTokens(
            accent: Theme.color(fromHex: accent), pin: Theme.color(fromHex: pin),
            cornerRadius: 12, usesMaterials: false,
            barFill: Theme.color(fromHex: bg), cardFill: Theme.color(fromHex: panel),
            border: Color.white.opacity(0.10), borderHover: Color.white.opacity(0.20),
            selectedBorderWidth: 2,
            tagFill: Color.white.opacity(0.07), tagText: Theme.color(fromHex: muted),
            scheme: .dark)
    }

    var tokens: ThemeTokens {
        switch self {
        case .system:
            // Follow the macOS appearance: One Dark in Dark Mode, Swiss in Light.
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? ThemePreset.oneDark.tokens : ThemePreset.swiss.tokens
        case .swiss:
            return ThemeTokens(
                accent: Color(.sRGB, red: 0.16, green: 0.50, blue: 0.96, opacity: 1),
                pin: Color(.sRGB, red: 0.95, green: 0.55, blue: 0.10, opacity: 1),
                cornerRadius: 9, usesMaterials: false,
                barFill: Color(.sRGB, white: 0.96, opacity: 1),
                cardFill: .white,
                border: Color(.sRGB, white: 0.82, opacity: 1),
                borderHover: Color(.sRGB, white: 0.62, opacity: 1),
                selectedBorderWidth: 2,
                tagFill: Color(.sRGB, white: 0.93, opacity: 1),
                tagText: Color(.sRGB, white: 0.42, opacity: 1),
                scheme: .light)
        case .glass:
            return ThemeTokens(
                accent: Color(.sRGB, red: 0.27, green: 0.90, blue: 0.82, opacity: 1),
                pin: Color(.sRGB, red: 0.27, green: 0.90, blue: 0.82, opacity: 1),
                cornerRadius: 14,
                barMaterial: .hudWindow, cardMaterial: .contentBackground,
                border: Color.white.opacity(0.10), borderHover: Color.white.opacity(0.22),
                selectedBorderWidth: 2,
                tagFill: Color.white.opacity(0.06), tagText: Color(white: 0.70),
                scheme: .dark)
        case .highContrast:
            return ThemeTokens(
                accent: Color(.sRGB, red: 0.25, green: 0.85, blue: 1.0, opacity: 1),
                pin: Color(.sRGB, red: 1.0, green: 0.60, blue: 0.0, opacity: 1),
                cornerRadius: 8, usesMaterials: false,
                barFill: .black,
                cardFill: Color(.sRGB, white: 0.07, opacity: 1),
                border: Color.white.opacity(0.55), borderHover: Color.white.opacity(0.85),
                selectedBorderWidth: 3.5,
                tagFill: Color(.sRGB, white: 0.18, opacity: 1), tagText: Color(white: 0.92),
                scheme: .dark)
        case .paper:
            return ThemeTokens(
                accent: Color(.sRGB, red: 0.66, green: 0.32, blue: 0.18, opacity: 1),
                pin: Color(.sRGB, red: 0.70, green: 0.50, blue: 0.10, opacity: 1),
                cornerRadius: 10, usesMaterials: false,
                barFill: Color(.sRGB, red: 0.96, green: 0.94, blue: 0.89, opacity: 1),
                cardFill: Color(.sRGB, red: 0.99, green: 0.98, blue: 0.95, opacity: 1),
                border: Color(.sRGB, red: 0.82, green: 0.78, blue: 0.70, opacity: 1),
                borderHover: Color(.sRGB, red: 0.60, green: 0.55, blue: 0.45, opacity: 1),
                selectedBorderWidth: 2,
                tagFill: Color(.sRGB, red: 0.90, green: 0.87, blue: 0.80, opacity: 1),
                tagText: Color(.sRGB, red: 0.45, green: 0.40, blue: 0.32, opacity: 1),
                scheme: .light, fontDesign: .serif)
        case .oneDark:
            return Self.editor(bg: "#21252b", panel: "#282c34", accent: "#61afef", pin: "#d19a66", muted: "#9097a3")
        case .dracula:
            return Self.editor(bg: "#21222c", panel: "#282a36", accent: "#bd93f9", pin: "#ffb86c", muted: "#7b86b0")
        case .tokyoNight:
            return Self.editor(bg: "#16161e", panel: "#1a1b26", accent: "#7aa2f7", pin: "#e0af68", muted: "#6b75a3")
        case .catppuccin:
            return Self.editor(bg: "#181825", panel: "#1e1e2e", accent: "#cba6f7", pin: "#fab387", muted: "#9399b2")
        case .gruvbox:
            return Self.editor(bg: "#1d2021", panel: "#282828", accent: "#fabd2f", pin: "#fe8019", muted: "#a89984")
        case .monokai:
            return Self.editor(bg: "#1e1f1c", panel: "#272822", accent: "#a6e22e", pin: "#fd971f", muted: "#9d967f")
        case .nightOwl:
            return Self.editor(bg: "#010e1a", panel: "#011627", accent: "#82aaff", pin: "#f78c6c", muted: "#637777")
        case .solarizedLight:
            return Self.lightEditor(bg: "#eee8d5", panel: "#fdf6e3", accent: "#268bd2", pin: "#cb4b16", muted: "#657b83")
        case .githubLight:
            return Self.lightEditor(bg: "#f6f8fa", panel: "#ffffff", accent: "#0969da", pin: "#bc4c00", muted: "#57606a")
        case .catppuccinLatte:
            return Self.lightEditor(bg: "#e6e9ef", panel: "#eff1f5", accent: "#8839ef", pin: "#fe640b", muted: "#6c6f85")
        case .rosePineDawn:
            return Self.lightEditor(bg: "#faf4ed", panel: "#fffaf3", accent: "#907aa9", pin: "#b4637a", muted: "#797593")
        case .oneLight:
            return Self.lightEditor(bg: "#fafafa", panel: "#ffffff", accent: "#4078f2", pin: "#c18401", muted: "#a0a1a7")
        }
    }
}

/// How the bar arranges its clips (the visual-QA layout shortlist).
enum LayoutMode: String, CaseIterable, Identifiable {
    case strip, spotlight, list
    var id: String { rawValue }
    var title: String {
        switch self {
        case .strip:     return "Card Strip"
        case .spotlight: return "Spotlight Palette"
        case .list:      return "Compact List"
        }
    }
    var subtitle: String {
        switch self {
        case .strip:     return "Horizontal cards (classic)"
        case .spotlight: return "Search + results + preview"
        case .list:      return "Dense one-line rows"
        }
    }
}

/// Small palette + helpers shared across the bar UI. Reads the active preset.
enum Theme {
    static var preset: ThemePreset {
        get { ThemePreset(rawValue: UserDefaults.standard.string(forKey: "themePreset") ?? "system") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "themePreset") }
    }
    static var layout: LayoutMode {
        get { LayoutMode(rawValue: UserDefaults.standard.string(forKey: "layoutMode") ?? "strip") ?? .strip }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "layoutMode") }
    }
    static var t: ThemeTokens { preset.tokens }
    static var accent: Color { t.accent }
    static var pin: Color { t.pin }
    static var cardWidth: CGFloat { t.cardWidth }
    static var cardHeight: CGFloat { t.cardHeight }
    static var cornerRadius: CGFloat { t.cornerRadius }

    /// The bar's background — vibrancy material or a flat themed fill.
    @ViewBuilder static func barBackground() -> some View {
        if t.usesMaterials {
            VisualEffectBackground(material: t.barMaterial, blending: .behindWindow)
        } else {
            t.barFill
        }
    }

    /// A card's background — vibrancy material or a flat themed fill.
    @ViewBuilder static func cardBackground() -> some View {
        if t.usesMaterials {
            VisualEffectBackground(material: t.cardMaterial, blending: .withinWindow)
        } else {
            t.cardFill
        }
    }

    static func color(fromHex hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// A wrapping flow layout — each subview takes its natural width and wraps to the
/// next row when it runs out of horizontal space. Used so tag pills show their
/// full text instead of being truncated by a fixed-width grid.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A blurred material background matching the system vibrancy.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}
