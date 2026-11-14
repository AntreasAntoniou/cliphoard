import XCTest
import AppKit
import SwiftUI
@testable import Cliphoard

#if !APP_STORE || LOCAL_PERFORMANCE_PRO
final class DirectUpdateTests: XCTestCase {
    private func release(_ tag: String = "direct-v1.0.4-build36", draft: Bool = false,
                         prerelease: Bool = false) -> [String: Any] {
        let parts = tag.replacingOccurrences(of: "direct-v", with: "").components(separatedBy: "-build")
        let name = "Cliphoard-\(parts[0])-Direct-build\(parts.count > 1 ? parts[1] : "0").zip"
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease,
         "assets": [["name": name, "state": "uploaded",
                     "size": 55188877, "browser_download_url":
                     "https://github.com/AntreasAntoniou/cliphoard/releases/download/\(tag)/\(name)"]]]
    }

    private func data(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    func testNumericVersionAndBuildOrdering() throws {
        let v = try XCTUnwrap(DirectRelease.Version(marketing: "1.0.4", build: "36"))
        XCTAssertTrue(v < DirectRelease.Version(marketing: "1.0.4", build: "100")!)
        XCTAssertTrue(v < DirectRelease.Version(marketing: "1.0.10", build: "1")!)
        XCTAssertFalse(v < DirectRelease.Version(marketing: "1.0.3", build: "999")!)
        for bad in ["1.0", "1.0.4-beta", "-1.0.4", "1.0. 4", "1.0.4.1"] {
            XCTAssertNil(DirectRelease.Version(marketing: bad, build: "36"))
        }
        XCTAssertNil(DirectRelease.Version(marketing: "1.0.4", build: "9999999999999999999999"))
    }

    func testOnlyPublishedDirectReleasesWithExactAssetAreAccepted() throws {
        let valid = release()
        let result = try DirectRelease.latest(in: data([
            release("direct-v1.0.4-build38", draft: true),
            release("direct-v1.0.4-build39", prerelease: true),
            release("v99.0.0"), valid]))
        XCTAssertEqual(result.tag, "direct-v1.0.4-build36")
        XCTAssertEqual(result.pageURL.absoluteString,
                       "https://github.com/AntreasAntoniou/cliphoard/releases/tag/direct-v1.0.4-build36")
        var hostile = valid
        hostile["assets"] = [["name": "Cliphoard-1.0.4-Direct-build36.zip", "state": "uploaded",
                               "size": 100, "browser_download_url": "https://evil.example/app.zip"]]
        XCTAssertThrowsError(try DirectRelease.latest(in: data([hostile])))
        XCTAssertNil(DirectRelease(tag: "direct-v1.0.4-build36/../../evil"))
        XCTAssertThrowsError(try DirectRelease.latest(in: Data(repeating: 32, count: 524289)))
        XCTAssertThrowsError(try DirectRelease.latest(in: Data("{}".utf8)))
    }

    @MainActor func testNewerReleaseIsSharedAndNotificationIsDeduplicatedAcrossRestart() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var notifications = 0
        let payload = try data([release()])
        let response = HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let checker = DirectUpdateChecker(defaults: defaults, installed: .init(marketing: "1.0.4", build: "35"),
            load: { _ in (payload, response) })
        checker.notify = { _ in notifications += 1; return true }
        await checker.check()
        XCTAssertEqual(checker.available?.version.build, 36)
        XCTAssertTrue(checker.showsNotice)
        XCTAssertEqual(notifications, 1)
        checker.dismissNotice()
        XCTAssertFalse(checker.showsNotice)
        await checker.check(manual: true)
        XCTAssertTrue(checker.showsNotice)
        XCTAssertEqual(notifications, 1)
        let restarted = DirectUpdateChecker(defaults: defaults, installed: checker.installed,
                                             load: { _ in (payload, response) })
        restarted.notify = { _ in notifications += 1; return true }
        XCTAssertNotNil(restarted.available)
        await restarted.check(manual: true)
        XCTAssertEqual(notifications, 1)
        let upgraded = DirectUpdateChecker(defaults: defaults, installed: .init(marketing: "1.0.4", build: "36"),
                                            load: { _ in (payload, response) })
        XCTAssertNil(upgraded.available)
    }

    @MainActor func testThrottleOptOutManualCheckAndOfflineFailure() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var requests = 0
        let checker = DirectUpdateChecker(defaults: defaults, installed: .init(marketing: "1.0.4", build: "36"),
            clock: { now }, load: { request in
                requests += 1
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.httpBody)
                XCTAssertEqual(request.url, DirectUpdateChecker.endpoint)
                throw URLError(.notConnectedToInternet)
            })
        XCTAssertTrue(checker.automaticChecks)
        await checker.check(); await checker.check()
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(checker.checking)
        XCTAssertTrue(checker.message.contains("couldn’t"))
        now += 86401
        await checker.check()
        XCTAssertEqual(requests, 2)
        checker.automaticChecks = false
        now += 86401
        await checker.check()
        XCTAssertEqual(requests, 2)
        await checker.check(manual: true)
        XCTAssertEqual(requests, 3)
    }

    @MainActor func testEqualOrNewerInstalledBuildDoesNotNotifyAndHTTPFailureIsNotUpToDate() async throws {
        let payload = try data([release()])
        for build in ["36", "37"] {
            let checker = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
                installed: .init(marketing: "1.0.4", build: build), load: { _ in
                    (payload, HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 200,
                                               httpVersion: nil, headerFields: nil)!)
                })
            checker.notify = { _ in XCTFail("No update for equal/newer installed app"); return false }
            await checker.check()
            XCTAssertNil(checker.available)
            XCTAssertEqual(checker.message, "You’re up to date.")
        }
        let denied = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: .init(marketing: "1.0.4", build: "35"), load: { _ in
                (payload, HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 403,
                                          httpVersion: nil, headerFields: nil)!)
            })
        await denied.check(manual: true)
        XCTAssertNil(denied.available)
        XCTAssertNotEqual(denied.message, "You’re up to date.")
    }
    func testHighestNumericDirectReleaseWinsRegardlessOfFeedOrder() throws {
        let result = try DirectRelease.latest(in: data([release(), release("direct-v1.0.10-build2"),
                                                       release("direct-v1.0.3-build999")]))
        XCTAssertEqual(result.tag, "direct-v1.0.10-build2")
    }

    @MainActor func testOptOutDuringFlightDiscardsResultAndConcurrentCheckIsSingleFlight() async throws {
        let payload = try data([release()])
        var continuation: CheckedContinuation<Void, Never>?
        var requests = 0
        let checker = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: .init(marketing: "1.0.4", build: "35"), load: { _ in
                requests += 1
                await withCheckedContinuation { continuation = $0 }
                return (payload, HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!)
            })
        let task = Task { await checker.check() }
        while continuation == nil { await Task.yield() }
        await checker.check(manual: true)
        XCTAssertEqual(requests, 1)
        checker.automaticChecks = false
        continuation?.resume(); await task.value
        XCTAssertNil(checker.available)
        XCTAssertFalse(checker.checking)
    }

    @MainActor func testNotificationDenialKeepsInAppNoticeAndHostileResponseURLFails() async throws {
        let payload = try data([release()])
        let checker = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: .init(marketing: "1.0.4", build: "35"), load: { _ in
                (payload, HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!)
            })
        checker.notify = { _ in false }
        await checker.check()
        XCTAssertTrue(checker.showsNotice)
        let hostile = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: checker.installed, load: { _ in
                (payload, HTTPURLResponse(url: URL(string: "https://evil.example/feed")!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!)
            })
        await hostile.check()
        XCTAssertNil(hostile.available)
    }

    @MainActor func testNativeUpdateViewsFitAndSaveSyntheticPreview() async throws {
        _ = NSApplication.shared
        let payload = try data([release()])
        let checker = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: .init(marketing: "1.0.4", build: "35"), load: { _ in
                (payload, HTTPURLResponse(url: DirectUpdateChecker.endpoint, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!)
            })
        await checker.check(manual: true)
        for width in [640.0, 1200.0] {
            let view = VStack(alignment: .leading, spacing: 12) {
                DirectUpdateNotice(updates: checker)
                Divider()
                DirectUpdateSettingsView(updates: checker).padding(16)
            }.frame(width: width).background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(.dark).environment(\.colorScheme, .dark)
            let controller = NSHostingController(rootView: view)
            let size = controller.sizeThatFits(in: CGSize(width: width, height: .infinity))
            XCTAssertLessThan(size.height, 360)
            XCTAssertGreaterThan(size.height, 120)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false; window.contentViewController = controller
            controller.view.frame = NSRect(origin: .zero, size: size)
            window.setContentSize(size)
            window.orderBack(nil); controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            if let output = ProcessInfo.processInfo.environment["CLIPHOARD_UPDATE_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: output).appendingPathComponent("updates-\(Int(width)).png"))
            }
            window.close()
        }
    }

    @MainActor func testLivePublicReleaseFeedWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["CLIPHOARD_UPDATE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public network check")
        }
        let checker = DirectUpdateChecker(defaults: UserDefaults(suiteName: UUID().uuidString)!,
            installed: .init(marketing: "1.0.4", build: "35"))
        await checker.check(manual: true)
        XCTAssertEqual(checker.available?.tag, "direct-v1.0.4-build36")
        XCTAssertTrue(checker.showsNotice)
        print("LIVE DIRECT FEED: \(checker.message)")
    }

}
#endif
