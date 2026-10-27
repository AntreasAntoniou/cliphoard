#if CLIPHOARD_DEVICE_LICENSING_PROTOTYPE && !APP_STORE
import AppKit
import SwiftUI
import XCTest
@testable import Cliphoard

@MainActor
final class DeviceLicenceApprovalViewTests: XCTestCase {
    func testConstructingAndLayingOutStandaloneViewHasNoEffects() async throws {
        let f = try FlowFixture()
        let host = NSHostingView(rootView: DeviceLicenceApprovalView(flow: f.flow))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 640)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let counts = await (f.identityStore.reads, f.keys.creations, f.receipts.reads, f.service.begins.count)
        XCTAssertEqual(counts.0, 0); XCTAssertEqual(counts.1, 0); XCTAssertEqual(counts.2, 0); XCTAssertEqual(counts.3, 0)
        XCTAssertEqual(f.ids.calls, 0)
    }

    func testPresentationDistinguishesCodeEntryExactRetryAndLocalRecovery() async {
        let code = DeviceLicenceApprovalPresentation(state: .init(phase: .awaitingCode, notice: .approvalQueued,
            canRequest: false, canEnterCode: true, canCancel: true))
        XCTAssertEqual(code.title, "Check your email")
        XCTAssertFalse(code.message.lowercased().contains("delivered"))
        XCTAssertNil(code.retryTitle)
        let retry = DeviceLicenceApprovalPresentation(state: .init(phase: .retryable, notice: .outcomeUnknown,
            retry: .sameRequest, canRequest: false))
        XCTAssertEqual(retry.retryTitle, "Retry same request")
        XCTAssertTrue(retry.message.contains("does not start a different approval"))
        let recovery = DeviceLicenceApprovalPresentation(state: .init(phase: .recoveryRequired,
            notice: .commitUncertain, isApproved: true, canRequest: false, canImport: false))
        XCTAssertEqual(recovery.title, "Check saved approval")
        XCTAssertTrue(recovery.message.contains("nothing was saved"))
        XCTAssertNil(recovery.retryTitle)
        for state in [code.state, retry.state, recovery.state] {
            let text = DeviceLicenceApprovalPresentation(state: state).message
            XCTAssertFalse(text.contains("CLIPD1")); XCTAssertFalse(text.contains("P256"))
            XCTAssertFalse(text.contains("refund")); XCTAssertFalse(text.contains("held for review"))
        }
    }

    func testSyntheticLightDarkNarrowWideAndScrollReachability() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLIPHOARD_FLOW_FIXTURE_DIR"] else {
            throw XCTSkip("Offscreen artifact directory is supplied explicitly by the task harness")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Never overwrite prior visual evidence")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fixtures: [(String, DeviceLicenceApprovalState, CGFloat, CGFloat, ColorScheme)] = [
            ("ready-wide-light", .init(), 680, 680, .light),
            ("code-medium-dark", .init(phase: .awaitingCode, notice: .approvalQueued,
                canRequest: false, canEnterCode: true, canCancel: true), 480, 680, .dark),
            ("approved-wide-dark", .init(isApproved: true, canRequest: false), 680, 640, .dark),
            ("uncertain-narrow-light", .init(phase: .recoveryRequired, notice: .commitUncertain,
                isApproved: true, canRequest: false, canImport: false), 300, 300, .light),
            ("retry-narrow-dark", .init(phase: .retryable, notice: .outcomeUnknown,
                retry: .sameRequest, canRequest: false, canCancel: true), 300, 300, .dark),
        ]
        var metadata: [[String: Any]] = []
        for (name, state, width, height, scheme) in fixtures {
            var actions = 0
            let content = DeviceLicenceApprovalContent(state: state, request: { actions += 1 },
                submitCode: { _ in actions += 1 }, retry: { actions += 1 }, cancel: { actions += 1 },
                differentCode: { actions += 1 }, restore: { actions += 1 }, importReceipt: { _ in actions += 1 })
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(red: 0.12, green: 0.12, blue: 0.13) : Color.white)
            let position = ApprovalFixturePosition()
            let host = NSHostingView(rootView: ApprovalScrollableFixture(position: position, content: content))
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            // An unshown task-owned window establishes the SwiftUI hosting lifecycle.
            // Never make key, order front, activate an app, or deliver user input.
            _ = NSApplication.shared
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 40_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width); XCTAssertEqual(host.bounds.height, height)
            let top = try capture(host, to: root.appendingPathComponent(name + "-top.png"))
            if width == 300 {
                // SwiftUI manages this offscreen ScrollView's layout separately from
                // NSScrollView.documentView (whose height can be zero). Use its own
                // public scrolling API, then preserve pixels for visual inspection.
                position.target = "deviceApproval.policy"
                try await Task.sleep(nanoseconds: 60_000_000)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 20_000_000)
                let bottom = try capture(host, to: root.appendingPathComponent(name + "-bottom.png"))
                XCTAssertNotEqual(top, bottom, "Scrolling to the policy footer must change the visible content")
            }
            XCTAssertEqual(actions, 0, "Rendering cannot dispatch an effect")
            XCTAssertFalse(window.isVisible, "Synthetic fixture window must never be shown")
            metadata.append(["fixture": name, "width": width, "height": height,
                "scheme": scheme == .dark ? "dark" : "light", "actions": actions,
                "scrollTarget": width == 300 ? "deviceApproval.policy" : "none",
                "scrollAPI": "SwiftUI.ScrollViewProxy.scrollTo(anchor: .bottom)"])
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("FIXTURES.json"), options: .withoutOverwriting)
    }
    @discardableResult private func capture(_ view: NSView, to url: URL) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1000)
        try png.write(to: url, options: .withoutOverwriting)
        return png
    }
}

@MainActor private final class ApprovalFixturePosition: ObservableObject {
    @Published var target: String?
}
@MainActor private struct ApprovalScrollableFixture<Content: View>: View {
    @ObservedObject var position: ApprovalFixturePosition
    let content: Content
    var body: some View {
        ScrollViewReader { proxy in
            content.onChange(of: position.target) { target in
                if let target { proxy.scrollTo(target, anchor: .bottom) }
            }
        }
    }
}
#endif
