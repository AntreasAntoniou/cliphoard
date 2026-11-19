// LOCAL_PERFORMANCE_PRO is the owner's local validation edition, never a Store release.
#if !APP_STORE || LOCAL_PERFORMANCE_PRO
import AppKit
import Combine
import Foundation

struct DirectRelease: Equatable {
    struct Version: Equatable, Comparable {
        let components: [Int]
        let build: Int
        init?(marketing: String, build: String) {
            let parts = marketing.split(separator: ".", omittingEmptySubsequences: false)
            func number(_ text: String) -> Int? {
                guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return Int(text)
            }
            let numbers = parts.compactMap { number(String($0)) }
            guard parts.count == 3, numbers.count == 3, let build = number(build), build > 0 else { return nil }
            self.components = numbers; self.build = build
        }
        var marketing: String { components.map(String.init).joined(separator: ".") }
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.components == rhs.components ? lhs.build < rhs.build
                : lhs.components.lexicographicallyPrecedes(rhs.components)
        }
    }

    let version: Version
    let tag: String
    var pageURL: URL { URL(string: "https://github.com/AntreasAntoniou/cliphoard/releases/tag/\(tag)")! }
    var label: String { "Cliphoard \(version.marketing) (\(version.build))" }
    init?(tag: String) {
        guard tag.hasPrefix("direct-v") else { return nil }
        let parts = tag.dropFirst(8).components(separatedBy: "-build")
        guard parts.count == 2, let version = Version(marketing: parts[0], build: parts[1]),
              tag == "direct-v\(version.marketing)-build\(version.build)" else { return nil }
        self.version = version; self.tag = tag
    }

    private struct Asset: Decodable { let name: String; let state: String; let size: Int; let browser_download_url: String }
    private struct Entry: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
    enum FeedError: Error { case invalidResponse }
    static func latest(in data: Data) throws -> Self {
        guard data.count <= 524288 else { throw FeedError.invalidResponse }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let releases = entries.compactMap { entry -> Self? in
            guard !entry.draft, !entry.prerelease, let release = Self(tag: entry.tag_name) else { return nil }
            let name = "Cliphoard-\(release.version.marketing)-Direct-build\(release.version.build).zip"
            let url = "https://github.com/AntreasAntoniou/cliphoard/releases/download/\(release.tag)/\(name)"
            guard entry.assets.contains(where: {
                $0.name == name && $0.state == "uploaded" && $0.size > 0 && $0.browser_download_url == url
            }) else { return nil }
            return release
        }
        guard let latest = releases.max(by: { $0.version < $1.version }) else { throw FeedError.invalidResponse }
        return latest
    }
}

/// Metadata only: no cookies, credentials, clipboard, licence, device IDs, or automatic installation.
private final class DirectUpdateTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request, delegate: DirectUpdateTransport())
        guard let response = response as? HTTPURLResponse else { throw DirectRelease.FeedError.invalidResponse }
        return (data, response)
    }
}

@MainActor
final class DirectUpdateChecker: ObservableObject {
    static let shared = DirectUpdateChecker()
    static let endpoint = URL(string: "https://api.github.com/repos/AntreasAntoniou/cliphoard/releases?per_page=20")!
    let installed: DirectRelease.Version?
    @Published private(set) var available: DirectRelease?
    @Published private(set) var checking = false
    @Published private(set) var message = "Not checked yet."
    @Published private var dismissedTag: String?
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "directUpdates.automatic")
            if !automaticChecks { generation += 1 }
        }
    }
    var notify: ((DirectRelease) async -> Bool)?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let load: (URLRequest) async throws -> (Data, HTTPURLResponse)
    private var timer: Timer?
    private var generation = 0

    init(defaults: UserDefaults = .standard, installed: DirectRelease.Version? =
         .init(marketing: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
               build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
         clock: @escaping () -> Date = Date.init,
         load: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse) = DirectUpdateTransport.load) {
        self.defaults = defaults; self.installed = installed; self.clock = clock; self.load = load
        automaticChecks = defaults.object(forKey: "directUpdates.automatic") as? Bool ?? true
        dismissedTag = defaults.string(forKey: "directUpdates.dismissed")
        if let tag = defaults.string(forKey: "directUpdates.available"), let release = DirectRelease(tag: tag),
           let installed, installed < release.version { available = release }
    }

    var showsNotice: Bool { available != nil && available?.tag != dismissedTag }
    func dismissNotice() {
        dismissedTag = available?.tag
        defaults.set(dismissedTag, forKey: "directUpdates.dismissed")
    }
    func openRelease() { if let available { NSWorkspace.shared.open(available.pageURL) } }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer?.tolerance = 300
        RunLoop.main.add(timer!, forMode: .common)
        Task { await check() }
    }

    func check(manual: Bool = false) async {
        guard !checking, let installed else { return }
        let now = clock()
        if !manual {
            guard automaticChecks else { return }
            if let last = defaults.object(forKey: "directUpdates.attempt") as? Date,
               now >= last, now.timeIntervalSince(last) < 86400 { return }
        }
        checking = true
        defer { checking = false }
        let epoch = generation
        defaults.set(now, forKey: "directUpdates.attempt")
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Cliphoard-Direct-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await load(request)
            guard manual || (automaticChecks && generation == epoch) else { return }
            guard response.statusCode == 200, response.url == Self.endpoint else { throw DirectRelease.FeedError.invalidResponse }
            let release = try DirectRelease.latest(in: data)
            defaults.set(now, forKey: "directUpdates.checked")
            guard installed < release.version else {
                available = nil; defaults.removeObject(forKey: "directUpdates.available")
                message = "You’re up to date."
                return
            }
            available = release; defaults.set(release.tag, forKey: "directUpdates.available")
            message = "\(release.label) is available."
            if manual { dismissedTag = nil; defaults.removeObject(forKey: "directUpdates.dismissed") }
            if !manual, defaults.string(forKey: "directUpdates.notified") != release.tag,
               let notify, await notify(release) {
                defaults.set(release.tag, forKey: "directUpdates.notified")
            }
        } catch {
            guard manual || generation == epoch else { return }
            message = "Cliphoard couldn’t check for updates. Try again when you’re online."
        }
    }
}
#endif
