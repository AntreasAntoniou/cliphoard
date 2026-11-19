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

enum SensitiveRevealFailure: Error, Equatable {
    case cancelled, interrupted, unavailable, notVerified, focusDidNotReturn, clipChanged

    init(macError: Error?, fallback: Self) {
        switch (macError as? LAError)?.code {
        case .userCancel: self = .cancelled
        case .systemCancel, .appCancel, .invalidContext: self = .interrupted
        case .passcodeNotSet, .notInteractive: self = .unavailable
        case .authenticationFailed: self = .notVerified
        default: self = fallback
        }
    }

    var message: String {
        switch self {
        case .cancelled: return "Authentication was cancelled."
        case .interrupted: return "macOS interrupted authentication. Try again with Cliphoard open."
        case .unavailable: return "macOS couldn’t start authentication. Try again with Cliphoard open."
        case .notVerified: return "macOS couldn’t verify your identity. Try Touch ID or your Mac password."
        case .focusDidNotReturn: return "Cliphoard couldn’t return to this window. Click Reveal again."
        case .clipChanged: return "This clip changed during authentication. Click Reveal again."
        }
    }
}

@MainActor
final class SensitiveClipReveal: ObservableObject {
    static let shared = SensitiveClipReveal()
    @Published private(set) var revision = 0
    @Published private(set) var isAuthenticating = false
    @Published private var lastFailure: (clipID: UUID, failure: SensitiveRevealFailure)?
    private var state = SensitiveRevealState()
    private var context: LAContext?
    private var expiry: Timer?
    private var completion: Task<Void, Never>?
    typealias Authentication = (LAContext, NSWindow?, @escaping @Sendable (Result<Void, SensitiveRevealFailure>) -> Void) -> Void
    private let authenticate: Authentication
    private let focusTimeout: Duration
    private let restoreFocus: (NSWindow?) -> Bool
    private var observers: [NSObjectProtocol] = []

    init(authenticate: Authentication? = nil, restoreFocus: ((NSWindow?) -> Bool)? = nil,
         focusTimeout: Duration = .seconds(3), observeSystemEvents: Bool = true) {
        self.authenticate = authenticate ?? Self.authenticateWithMac
        self.restoreFocus = restoreFocus ?? Self.restoreAuthenticationFocus
        self.focusTimeout = focusTimeout
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

    private static func authenticateWithMac(
        _ context: LAContext, origin: NSWindow?,
        reply: @escaping @Sendable (Result<Void, SensitiveRevealFailure>) -> Void
    ) {
        guard let origin, origin.isVisible else { reply(.failure(.focusDidNotReturn)); return }

        // The history bar normally leaves the previous app active. A user who
        // clicks Reveal explicitly asks Cliphoard to present macOS authentication.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        origin.makeKey()
        context.touchIDAuthenticationAllowableReuseDuration = 0

        Task { @MainActor [weak origin] in
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            while !NSApp.isActive, origin?.isVisible == true, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard restoreAuthenticationFocus(origin) else {
                reply(.failure(.focusDidNotReturn))
                return
            }
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                reply(.failure(SensitiveRevealFailure(macError: error, fallback: .unavailable)))
                return
            }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal this sensitive clipboard item") {
                success, error in
                reply(success ? .success(()) : .failure(SensitiveRevealFailure(macError: error, fallback: .notVerified)))
            }
        }
    }

    private static func restoreAuthenticationFocus(_ origin: NSWindow?) -> Bool {
        // After the system prompt, never activate the app over another app.
        guard let origin, origin.isVisible, NSApp.isActive else { return false }
        guard NSApp.keyWindow == nil || NSApp.keyWindow === origin else { return false }
        if !origin.isKeyWindow { origin.makeKey() }
        return origin.isKeyWindow
    }

    func authenticationFailure(for item: ClipItem) -> SensitiveRevealFailure? {
        lastFailure?.clipID == item.id ? lastFailure?.failure : nil
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
        lastFailure = nil
        revision &+= 1
    }
    func reveal(_ item: ClipItem) {
        guard !isAuthenticating else { return }
        lock()
        let request = state.begin(id: item.id, fingerprint: SensitiveClipPolicy.fingerprint(item))
        // Mouse and keyboard actions carry their own window. A non-activating
        // panel can receive the click even when NSApp.keyWindow still reports nil.
        let origin = NSApp?.currentEvent?.window ?? NSApp?.keyWindow
        let context = LAContext()
        self.context = context
        isAuthenticating = true

        authenticate(context, origin) { [weak self, weak origin] result in
            Task { @MainActor in
                guard let self, self.state.pending == request else { return }
                self.completion = Task { @MainActor [weak self, weak origin] in
                    guard let self else { return }
                    let clock = ContinuousClock()
                    let deadline = clock.now + self.focusTimeout
                    var focusRestored = false
                    // The callback can arrive while macOS is still dismissing its window.
                    // Continue waiting for the actual key window, within a bounded period.
                    try? await Task.sleep(for: .milliseconds(100))
                    while !Task.isCancelled && self.state.pending == request {
                        focusRestored = self.restoreFocus(origin)
                        if focusRestored || clock.now >= deadline { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard !Task.isCancelled, self.state.pending == request else { return }
                    self.finish(request, for: item, result: result, focusRestored: focusRestored)
                }
            }
        }
    }

    private func finish(_ request: SensitiveRevealState.Request, for item: ClipItem,
                        result: Result<Void, SensitiveRevealFailure>, focusRestored: Bool) {
        let fingerprint = SensitiveClipPolicy.fingerprint(item)
        let failure: SensitiveRevealFailure?
        switch result {
        case .failure(let error): failure = error
        case .success where !focusRestored: failure = .focusDidNotReturn
        case .success where request.fingerprint != fingerprint: failure = .clipChanged
        case .success: failure = nil
        }
        state.complete(request, success: failure == nil,
            fingerprint: fingerprint, now: ProcessInfo.processInfo.systemUptime)
        context = nil
        completion = nil
        lastFailure = failure.map { (item.id, $0) }
        isAuthenticating = false
        revision &+= 1

        if failure == nil {
            let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.lock() }
            }
            RunLoop.main.add(timer, forMode: .common)
            expiry = timer
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
            if let failure = reveal.authenticationFailure(for: item) {
                Text(failure.message).font(.caption)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
