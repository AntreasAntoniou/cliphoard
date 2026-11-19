import AppKit
import Combine
import CryptoKit
import LocalAuthentication
import SwiftUI

enum SensitiveClipPolicy {
    static func requiresAuthentication(flags: ClipFlags) -> Bool {
        // Ordinary contact details retain their informational classification.
        // Unknown persisted bits remain protective. Entropy now conceals by owner policy.
        !flags.subtracting([.pii, .nsfw]).isEmpty
            || (flags.contains(.nsfw) && ContentAnalysisPreferences.nsfwActive)
    }
    static func requiresAuthentication(_ item: ClipItem) -> Bool {
        // NSFW policy is dynamic: do not memoize a Focus or settings decision on a clip.
        if ContentAnalysisPreferences.nsfwActive, !NSFWDetection.exempt(item),
           item.flags.contains(.nsfw) || NSFWDetection.labelled(item) { return true }
        return requiresCoreAuthentication(item)
    }
    /// Credential and other pre-existing protection, independent of NSFW policy.
    static func requiresCoreAuthentication(_ item: ClipItem) -> Bool {
        item.memoizedSensitivity {
            // Alternate rich content may contain different text, attachments or link
            // destinations. Conceal it conservatively without parsing untrusted rich
            // content before authentication. Preserve the original representation.
            if let rtf = item.rtf, !rtf.isEmpty { return true }
            if requiresAuthentication(flags: item.flags.subtracting(.nsfw)) { return true }
            // Old rows predate new vendor signatures; presentation must protect them
            // immediately without changing or migrating the user's stored history.
            let fields = [item.text, item.ocrText ?? "", item.filePath ?? "", item.colorHex ?? "", item.sourceApp ?? ""] + item.userTags
            return fields.contains {
                requiresAuthentication(flags: Detectors.scan(text: $0, kind: item.kind, sourceApp: item.sourceApp).flags)
            }
        }
    }
    static func visibleUserTags(in items: [ClipItem]) -> [String] {
        Array(Set(items.filter { !requiresAuthentication($0) }.flatMap(\.userTags))).sorted()
    }
    static func fingerprint(_ item: ClipItem) -> String {
        item.memoizedFingerprint {
            // Length-prefixed fields prevent ambiguous joins. The digest never leaves memory.
            let fields = [item.text, item.ocrText ?? "", item.filePath ?? "", item.payloadFile ?? "",
                          item.colorHex ?? "", item.sourceApp ?? "", String(item.flags.rawValue),
                          String(describing: item.kind)] + item.userTags
            var hash = SHA256()
            hash.update(data: Data("fields=\(fields.count);".utf8))
            for field in fields {
                let bytes = Data(field.utf8)
                hash.update(data: Data("\(bytes.count):".utf8))
                hash.update(data: bytes)
            }
            let rtf = item.rtf ?? Data()
            hash.update(data: Data("rtf=\(rtf.count):".utf8))
            hash.update(data: rtf)
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}

@MainActor
final class SensitiveClipReveal: ObservableObject {
    static let shared = SensitiveClipReveal()
    @Published private(set) var revision = 0
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authenticationFailed = false
    private var state = SensitiveRevealState()
    private var context: LAContext?
    private var expiry: Timer?
    private var completion: Task<Void, Never>?
    private let authenticate: (LAContext, @escaping @Sendable (Bool) -> Void) -> Void
    private let restoreFocus: (NSWindow?) -> Bool
    private var observers: [NSObjectProtocol] = []

    init(authenticate: ((LAContext, @escaping @Sendable (Bool) -> Void) -> Void)? = nil,
         restoreFocus: ((NSWindow?) -> Bool)? = nil, observeSystemEvents: Bool = true) {
        self.authenticate = authenticate ?? Self.authenticateWithMac
        self.restoreFocus = restoreFocus ?? Self.restoreAuthenticationFocus
        guard observeSystemEvents else { return }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.willSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        }
        // macOS broadcasts this when locking without sleeping (for example
        // Control-Command-Q). Keep the public workspace/session hooks above as
        // independent invalidators; OS notification delivery needs device testing.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // This notification belongs to the focus change that just happened.
                // Reading the state on a later task can relock a completed prompt.
                guard let self, !self.isAuthenticating else { return }
                self.lock()
            }
        })
    }

    private static func authenticateWithMac(_ context: LAContext, reply: @escaping @Sendable (Bool) -> Void) {
        // Uses the system's device-owner authentication, including its configured fallback.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            reply(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal this sensitive clipboard item") {
            success, _ in reply(success)
        }
    }

    private static func restoreAuthenticationFocus(_ origin: NSWindow?) -> Bool {
        guard let origin, origin.isVisible, NSApp.isActive || origin.isKeyWindow else { return false }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === origin else { return false }
        if !origin.isKeyWindow { origin.makeKey() }
        return origin.isKeyWindow
    }

    func isConcealed(_ item: ClipItem) -> Bool {
        SensitiveClipPolicy.requiresAuthentication(item)
            && !state.permits(id: item.id, fingerprint: SensitiveClipPolicy.fingerprint(item), now: ProcessInfo.processInfo.systemUptime)
    }
    func lock() {
        state.lock()
        completion?.cancel()
        completion = nil
        context?.invalidate()
        context = nil
        expiry?.invalidate()
        expiry = nil
        isAuthenticating = false
        authenticationFailed = false
        revision &+= 1
    }
    func reveal(_ item: ClipItem) {
        guard !isAuthenticating else { return }
        lock()
        let request = state.begin(id: item.id, fingerprint: SensitiveClipPolicy.fingerprint(item))
        let origin = NSApp?.keyWindow
        let context = LAContext()
        self.context = context
        isAuthenticating = true

        authenticate(context) { [weak self, weak origin] success in
            Task { @MainActor in
                guard let self, self.state.pending == request else { return }
                self.completion = Task { @MainActor [weak self, weak origin] in
                    // LocalAuthentication can reply before the system window returns key
                    // focus. Keep the panel's dismiss guard active through that transition.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.state.pending == request else { return }
                    let focusRestored = self.restoreFocus(origin)
                    // An explicit close or a lock during focus restoration invalidates the request.
                    guard self.state.pending == request else { return }
                    self.state.complete(request, success: success && focusRestored,
                        fingerprint: SensitiveClipPolicy.fingerprint(item), now: ProcessInfo.processInfo.systemUptime)
                    self.context = nil
                    self.completion = nil
                    self.authenticationFailed = self.isConcealed(item)
                    self.isAuthenticating = false
                    self.revision &+= 1
                    if !self.authenticationFailed {
                        self.expiry = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                            Task { @MainActor in self?.lock() }
                        }
                    }
                }
            }
        }
    }

}

/// Replaces the content subtree; no blur, opacity or accessibility-only mask.
/// Hidden values are never supplied as labels, help, metadata, or selectable text.
@MainActor
struct SensitiveClipPlaceholder: View {
    let item: ClipItem
    @ObservedObject var reveal = SensitiveClipReveal.shared
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill").font(.title)
            Text("Sensitive content hidden").font(.headline)
            Text("Authenticate with macOS to reveal for 60 seconds.")
                .font(.caption).multilineTextAlignment(.center)
            Button("Reveal sensitive content") { reveal.reveal(item) }
                .disabled(reveal.isAuthenticating)
            if reveal.authenticationFailed {
                Text("Authentication did not reveal this item. Try again when ready.").font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
