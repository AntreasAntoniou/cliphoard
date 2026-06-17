import AppKit
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipStore()
    private lazy var monitor = ClipboardMonitor(store: store)
    private lazy var model = PanelViewModel(store: store)
    private let panel = FloatingPanel()
    private let hotKey = HotKey()

    private var statusItem: NSStatusItem!
    private var keyMonitor: Any?

    private var previousApp: NSRunningApplication?
    private var isVisible = false
    private var isClosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        setupHotKey()
        setupRemoteToggle()
        monitor.start()
        checkAccessibility()
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
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Ditto  (⌃⌥⌘V)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(.separator())

        let limitItem = NSMenuItem(title: "History Limit", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for n in [50, 100, 200, 500, 1000] {
            let it = NSMenuItem(title: "\(n) items", action: #selector(setLimit(_:)), keyEquivalent: "")
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
        menu.addItem(withTitle: "Clear Unpinned History", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(withTitle: "About Ditto", action: #selector(about), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ditto", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: Panel

    private func setupPanel() {
        model.onPaste = { [weak self] item in self?.commit(item) }
        model.onClose = { [weak self] in self?.hide(paste: false) }
        panel.onResignKey = { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.hide(paste: false)
        }
        panel.setContent(ContentView(model: model, store: store))

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
        previousApp = NSWorkspace.shared.frontmostApplication
        model.query = ""
        model.activeKind = nil
        model.pinnedOnly = false
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

    private func commit(_ item: ClipItem) {
        store.markUsed(item)
        monitor.suppressNextChange()
        Paster.writeToPasteboard(item, store: store)
        hide(paste: true)
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        let cmd = event.modifierFlags.contains(.command)
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
            model.commitSelection(); return nil
        case kVK_Delete where cmd:
            model.deleteSelection(); return nil
        case kVK_ANSI_P where cmd:
            model.pinSelection(); return nil
        default:
            if cmd, let digit = digit(for: Int(event.keyCode)) {
                model.quickSelect(digit); return nil
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
        setLaunchAtLogin(!launchAtLoginEnabled)
        rebuildMenu()
    }

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Ditto: launch-at-login toggle failed: \(error)")
        }
    }

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

    private func checkAccessibility() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
        if !trusted {
            NSLog("Ditto: needs Accessibility permission to auto-paste.")
        }
    }
}
