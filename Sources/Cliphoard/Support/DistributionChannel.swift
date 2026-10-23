import Foundation

/// Compile-time distribution differences that must not depend on receipts, file paths, or
/// mutable defaults. `APP_STORE` is supplied only by `Scripts/build-mas.sh`.
enum DistributionChannel {
    #if APP_STORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// The direct build may post Command-V after the user grants Accessibility. The sandboxed
    /// Store build deliberately stops at a pasteboard write and asks the user to press Command-V.
    static var supportsAutomaticPaste: Bool { !isAppStore }

    static var primaryActionTitle: String { supportsAutomaticPaste ? "Paste" : "Copy & Close" }
    static var quickActionTitle: String { supportsAutomaticPaste ? "Quick paste" : "Quick copy" }

    /// A sandbox cannot enumerate another app's private or Application Support stores. Store
    /// imports enter through NSOpenPanel, which grants access only to the URL the user chooses.
    static var canDiscoverExternalStores: Bool { !isAppStore }

    static let manualPasteMessage = "Copied to clipboard — press ⌘V to paste"

    /// Balance the security scope supplied by a standard open/save panel. The scope is needed
    /// only by the Store build; direct builds keep their existing filesystem behavior.
    static func withSecurityScopedAccess<Result>(
        to url: URL,
        _ body: () throws -> Result
    ) rethrows -> Result {
        #if APP_STORE
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        #endif
        return try body()
    }
}
