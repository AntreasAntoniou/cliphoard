import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = ClipStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private lazy var model = PanelViewModel(store: store)
    private let panel = FloatingPanel()
    private let hotKey = HotKey()

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var keyMonitor: Any?

    private var previousApp: NSRunningApplication?
    private var isVisible = false
    private var isClosing = false
    private var didPromptAX = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupHotKey()
        setupRemoteToggle()
        monitor.start()
        // Note: we deliberately do NOT prompt for Accessibility on launch — that
        // nags on every start (and after every reinstall, since the code identity
        // changes). We prompt lazily the first time an auto-paste actually needs it.
    }

    /// A Darwin notification that toggles the bar — lets scripts/tests drive it
    /// without needing the global hotkey (which requires Accessibility).
    private func setupRemoteToggle() {
        let name = "ai.axiotic.ditto.toggle" as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, ctx, { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { me.toggle() }
        }, name, nil, .deliverImmediately)
    }

    // MARK: Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Ditto")
            button.image?.isTemplate = true
        }
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    /// Rebuilt every time the menu opens (via `menuNeedsUpdate`) so live state —
    /// the Accessibility grant, toggles, history count — is always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Ditto  (⌃⌥⌘V)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())

        let limitItem = NSMenuItem(title: "History Limit", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for n in [0, 100, 200, 500, 1000, 5000] {
            let title = n == 0 ? "Unlimited" : "\(n) items"
            let it = NSMenuItem(title: title, action: #selector(setLimit(_:)), keyEquivalent: "")
            it.tag = n
            it.state = (store.historyLimit == n) ? .on : .off
            limitMenu.addItem(it)
        }
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        let soundItem = NSMenuItem(title: "Play Sound on Copy", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.state = Feedback.soundEnabled ? .on : .off
        menu.addItem(soundItem)

        let soundChoice = NSMenuItem(title: "Copy Sound", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for name in Feedback.availableSounds {
            let it = NSMenuItem(title: name, action: #selector(chooseSound(_:)), keyEquivalent: "")
            it.representedObject = name
            it.state = (Feedback.soundName == name) ? .on : .off
            soundMenu.addItem(it)
        }
        soundChoice.submenu = soundMenu
        menu.addItem(soundChoice)

        let debugItem = NSMenuItem(title: "Debug Logging", action: #selector(toggleDebug), keyEquivalent: "")
        debugItem.state = DebugLog.enabled ? .on : .off
        menu.addItem(debugItem)

        menu.addItem(.separator())
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Grant Accessibility (for auto-paste)…",
                         action: #selector(promptAccessibility), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Clear Unpinned History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(withTitle: "About Ditto", action: #selector(about), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ditto", action: #selector(quit), keyEquivalent: "q")
    }

    // MARK: Panel

    private func setupPanel() {
        model.onPaste = { [weak self] item, plain in self?.commit(item, plain: plain) }
        model.onClose = { [weak self] in self?.hide(paste: false) }
        model.onCopy = { [weak self] item in self?.copyToClipboard(item) }
        panel.onResignKey = { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.hide(paste: false)
        }
        panel.setContent { [model, store] in ContentView(model: model, store: store) }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKey(event)
        }
    }

    @objc private func toggle() {
        isVisible ? hide(paste: false) : show()
    }

    private func show() {
        guard !isVisible else { return }
        // Re-evaluate the SwiftUI tree against the *current* ClipStore state on
        // every present. The panel spends almost all its life `orderOut`, where
        // an NSHostingView's observation can be coalesced/dropped; rebuilding the
        // hosting controller here guarantees the freshly-summoned bar shows the
        // newest clips without needing an app restart.
        panel.refresh()
        previousApp = NSWorkspace.shared.frontmostApplication
        model.query = ""
        model.activeKind = nil
        model.pinnedOnly = false
        model.showSettings = false
        model.resetSelection()
        model.presentToken &+= 1
        isVisible = true
        isClosing = false
        NSApp.activate(ignoringOtherApps: true)
        panel.slideIn()
    }

    private func hide(paste: Bool) {
        guard isVisible, !isClosing else { return }
        isClosing = true
        panel.slideOut { [weak self] in
            guard let self else { return }
            if paste {
                Paster.paste(into: self.previousApp)
            } else {
                self.previousApp?.activate(options: [])
            }
            self.isVisible = false
            self.isClosing = false
        }
    }

    /// - Parameter plain: when `true` (Option held at commit), write the clip
    ///   as plain text only — strip the RTF representation before pasting.
    private func commit(_ item: ClipItem, plain: Bool = false) {
        store.markUsed(item)
        monitor.suppressNextChange()
        Paster.writeToPasteboard(item, store: store, plain: plain)
        // The clip is now on the system pasteboard regardless. Only the ⌘V
        // keystroke needs Accessibility — prompt once if it's missing.
        let canPaste = AXIsProcessTrusted()
        if !canPaste && !didPromptAX {
            didPromptAX = true
            promptAccessibility()
        }
        hide(paste: canPaste)
    }

    /// Copy a clip onto the system clipboard without pasting, then dismiss so the
    /// chosen clip is ready to paste manually elsewhere.
    private func copyToClipboard(_ item: ClipItem) {
        store.markUsed(item)
        monitor.suppressNextChange()
        Paster.writeToPasteboard(item, store: store)
        Feedback.playCapture()
        hide(paste: false)
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let cmd = event.modifierFlags.contains(.command)
        let control = event.modifierFlags.contains(.control)
        // Holding Option at commit time requests "paste as plain text" — the
        // clip is written without its RTF representation (⌥↩ or ⌥+⌘1–9).
        let plain = event.modifierFlags.contains(.option)

        // In settings, let the controls handle keys; only intercept Esc (which
        // returns to the clipboard view rather than dismissing the bar).
        if model.showSettings {
            if Int(event.keyCode) == kVK_Escape { model.showSettings = false; return nil }
            return event
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            hide(paste: false); return nil
        case kVK_LeftArrow:
            model.moveSelection(-1); return nil
        case kVK_RightArrow:
            model.moveSelection(1); return nil
        case kVK_DownArrow, kVK_UpArrow:
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.commitSelection(plain: plain); return nil
        case kVK_ANSI_C where cmd || control:
            // Copy the selected clip onto the system clipboard without pasting.
            model.copySelection(); return nil
        case kVK_Delete where cmd:
            model.deleteSelection(); return nil
        case kVK_ANSI_P where cmd:
            model.pinSelection(); return nil
        default:
            if cmd, let digit = digit(for: Int(event.keyCode)) {
                model.quickSelect(digit, plain: plain); return nil
            }
            return event
        }
    }

    private func digit(for keyCode: Int) -> Int? {
        let map: [Int: Int] = [
            kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
            kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9
        ]
        return map[keyCode]
    }

    // MARK: Hotkey

    private func setupHotKey() {
        hotKey.onPressed = { [weak self] in self?.toggle() }
        // ⌃⌥⌘V — Control + Option + Command + V.
        hotKey.register(keyCode: UInt32(kVK_ANSI_V),
                        modifiers: UInt32(controlKey | optionKey | cmdKey))
    }

    // MARK: Menu actions

    @objc private func setLimit(_ sender: NSMenuItem) {
        store.historyLimit = sender.tag
        rebuildMenu()
    }

    @objc private func clearHistory() {
        store.clearUnpinned()
    }

    @objc private func toggleSound() {
        Feedback.soundEnabled.toggle()
        if Feedback.soundEnabled { Feedback.playCapture() }
        rebuildMenu()
    }

    @objc private func chooseSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Feedback.soundName = name
        Feedback.soundEnabled = true
        Feedback.play(named: name) // preview the choice
        rebuildMenu()
    }

    @objc private func toggleDebug() {
        UserDefaults.standard.set(!DebugLog.enabled, forKey: "debugLog")
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        LoginItem.set(!LoginItem.enabled)
        rebuildMenu()
    }

    private var launchAtLoginEnabled: Bool { LoginItem.enabled }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Ditto"
        alert.informativeText = "A floating clipboard manager for macOS.\n\nPress ⌃⌥⌘V anywhere to summon your clipboard history."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Accessibility

    @objc private func promptAccessibility() {
        _ = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
    }
}
