import SwiftUI
import AppKit

/// The two shared pieces of the paid split's interface: the badge that names a Pro row, and
/// the card a refused control shows instead of doing nothing.
///
/// They live together because the alternative is four surfaces each inventing their own
/// wording, their own price and their own button — and the price in particular must be
/// written once (`Licence.priceLabel`) or the app will eventually quote a number the
/// checkout does not charge.
///
/// THE RULE THESE ENCODE: a gated control is never hidden and never silently inert. It is
/// named, it says what it costs, and pressing it explains itself. This app already does that
/// for a LIMIT (`SearchMode.blurb` names what Image mode will not show you) and for a frozen
/// store (the safe-mode banner offers the recovery its own text promises); a paywall that
/// behaved worse than either would be the least honest surface in the build.

/// A "PRO" marker. Small, quiet, and always adjacent to the thing it describes.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Cliphoard Pro feature")
    }
}

/// What a gated control shows when a free build touches it. States the capability, states
/// the price, and offers the one button that resolves it.
struct ProPitchCard: View {
    let message: String
    /// Optional headline — the Import panel uses it to show the user their own clip count,
    /// which is the most persuasive number the app has and the only one it did not invent.
    var headline: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headline {
                Text(headline).font(.system(size: 12, weight: .semibold))
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Get Pro — \(Licence.priceLabel)") {
                    // Hands the URL to the user's browser. The APP makes no request of its
                    // own — PRIVACY.md and the site promise zero network calls, and buying
                    // must not be the sentence that makes them false.
                    NSWorkspace.shared.open(Licence.buyURL)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Which gated surface raised a pitch. Carried with the message so the explanation renders
/// UNDER the control the user actually touched — a banner at the top of a long scroll view
/// is, for someone who just clicked something near the bottom, indistinguishable from
/// nothing happening at all.
enum ProSurface: String {
    case imageSearch, imageUnderstanding, history, importPanel
}

struct ProPitch: Equatable {
    let surface: ProSurface
    let message: String

    init(_ surface: ProSurface, _ message: String) {
        self.surface = surface
        self.message = message
    }
}
