import SwiftUI
import AppKit
import ApplicationServices

/// First-run welcome window: explains the hotkey and the one-time Accessibility
/// grant, then gets out of the way. Shown once (gated on UserDefaults), and
/// re-openable from the menu-bar menu.
enum Onboarding {
    private static let key = "didOnboardV1"
    private static var window: NSWindow?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        present()
    }

    static func present() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return
        }
        let view = OnboardingView(onDone: {
            UserDefaults.standard.set(true, forKey: key)
            window?.close(); window = nil
        })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(NSSize(width: 460, height: 560))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    let onDone: () -> Void
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// The app's own hoard-bag icon (the white filled bag), matching the panel
    /// toolbar; falls back to the ⌘ glyph if the bundle icon can't load.
    @ViewBuilder private var brandIcon: some View {
        if let icon = Bundle.main.image(forResource: "Cliphoard") ?? NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable().interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "command")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                brandIcon
                Text("Welcome to Cliphoard").font(.system(size: 24, weight: .bold))
                Text("Your clipboard history, one keystroke away.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.top, 38).padding(.bottom, 26)

            VStack(alignment: .leading, spacing: 18) {
                hotkeyRow
                feature("lock.shield", "Private by design",
                        "Everything stays on your Mac. No cloud, no telemetry, no account.")
                feature("sparkles", "Semantic search",
                        "On-device AI finds clips by meaning, not just exact text.")
            }
            .padding(.horizontal, 32)

            Divider().padding(.vertical, 22).padding(.horizontal, 24)

            accessibilitySection.padding(.horizontal, 32)

            Spacer(minLength: 16)

            Button(action: onDone) {
                Text("Start using Cliphoard")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 32).padding(.bottom, 28)
        }
        .frame(width: 460, height: 560)
        .background(VisualEffectBackground(material: .windowBackground, blending: .behindWindow))
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }

    private func feature(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hotkeyRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text("Summon it anywhere").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(["⌃", "⌥", "⌘", "V"], id: \.self) { k in
                        Text(k).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(minWidth: 22).padding(.vertical, 5).padding(.horizontal, 6)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text("from any app").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var accessibilitySection: some View {
        HStack(spacing: 14) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.shield")
                .font(.system(size: 18)).foregroundStyle(trusted ? .green : .orange).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(trusted ? "Accessibility granted" : "One quick permission")
                    .font(.system(size: 13, weight: .semibold))
                Text(trusted ? "Cliphoard can paste the clip you pick back into your app."
                             : "Cliphoard needs Accessibility to paste into the app you were using.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !trusted {
                Button("Grant…") { grant() }.controlSize(.small)
            }
        }
        .padding(12)
        .background((trusted ? Color.green : Color.orange).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func grant() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
