import AppKit
import LocalAuthentication
import SwiftUI
import XCTest
@testable import Cliphoard

@MainActor
final class SensitiveRevealInteractionTests: XCTestCase {
    func testSuccessfulAuthenticationRevealsWithoutAKeyWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        XCTAssertFalse(window.isKeyWindow)
        let reveal = SensitiveClipReveal(authenticate: { _, _, reply in reply(.success(())) },
            observeSystemEvents: false)
        let item = sensitiveClip()
        defer { reveal.lock(); window.close() }
        reveal.reveal(item)
        try await waitForCompletion(reveal)
        XCTAssertFalse(reveal.isConcealed(item))
        XCTAssertNil(reveal.authenticationFailure(for: item))
        XCTAssertTrue(reveal.isConcealed(sensitiveClip()))
        XCTAssertFalse(window.isKeyWindow)
    }

    func testCompletedRevealSurvivesApplicationDeactivation() async throws {
        let reveal = SensitiveClipReveal(authenticate: { _, _, reply in reply(.success(())) })
        let item = sensitiveClip()
        defer { reveal.lock() }
        reveal.reveal(item)
        try await waitForCompletion(reveal)
        XCTAssertFalse(reveal.isConcealed(item))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(reveal.isConcealed(item))
    }

    func testExplicitRelockDiscardsLateAuthentication() async throws {
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in reply = callback },
            observeSystemEvents: false)
        let item = sensitiveClip()
        reveal.reveal(item)
        XCTAssertTrue(reveal.isAuthenticating)
        let lateReply = try XCTUnwrap(reply)
        reveal.lock()
        lateReply(.success(()))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertFalse(reveal.isAuthenticating)
        XCTAssertNil(reveal.authenticationFailure(for: item))
    }

    func testChangingTheRequestedClipDuringAuthenticationStaysConcealed() async throws {
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in reply = callback },
            observeSystemEvents: false)
        let item = sensitiveClip()
        defer { reveal.lock() }
        reveal.reveal(item)
        item.ocrText = "New synthetic content"
        try XCTUnwrap(reply)(.success(()))
        try await waitForCompletion(reveal)
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertEqual(reveal.authenticationFailure(for: item), .clipChanged)
    }

    func testDisplaySleepRevokesPendingAuthentication() async throws {
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in reply = callback })
        let item = sensitiveClip()
        reveal.reveal(item)
        let lateReply = try XCTUnwrap(reply)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await waitForCompletion(reveal)
        lateReply(.success(()))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertFalse(reveal.isAuthenticating)
        XCTAssertNil(reveal.authenticationFailure(for: item))
    }

    func testCancellingAuthenticationStaysConcealed() async throws {
        let reveal = SensitiveClipReveal(authenticate: { _, _, reply in reply(.failure(.cancelled)) },
            observeSystemEvents: false)
        let item = sensitiveClip()
        reveal.reveal(item)
        try await waitForCompletion(reveal)
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertEqual(reveal.authenticationFailure(for: item), .cancelled)
        XCTAssertNil(reveal.authenticationFailure(for: sensitiveClip()))
    }

    func testAuthenticationFailureReportsTheMacOSReason() {
        XCTAssertEqual(SensitiveRevealFailure(macError: LAError(.userCancel), fallback: .notVerified), .cancelled)
        XCTAssertEqual(SensitiveRevealFailure(macError: LAError(.systemCancel), fallback: .notVerified), .interrupted)
        XCTAssertEqual(SensitiveRevealFailure(macError: LAError(.notInteractive), fallback: .notVerified), .unavailable)
        XCTAssertEqual(SensitiveRevealFailure(macError: LAError(.authenticationFailed), fallback: .unavailable), .notVerified)
    }

    func testNativeRevealClickDoesNotActivateTheSelectedCard() async throws {
        _ = NSApplication.shared
        var prompts = 0
        var cardTaps = 0
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in
            prompts += 1
            reply = callback
        },
            observeSystemEvents: false)
        let item = sensitiveClip()
        let card = ClipCardView(sensitiveReveal: reveal, item: item, index: 0,
            selected: true, storeDir: FileManager.default.temporaryDirectory, onActivate: { cardTaps += 1 },
            onInspect: {}, onInspectTags: {}, onPin: {}, onDelete: {}, historyIsMutable: true,
            onTap: { cardTaps += 1 })
        let host = NSHostingView(rootView: card)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: Theme.cardWidth, height: Theme.thumbnailHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { reveal.lock(); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // The centered button follows two text rows and the shield. Try a small
        // vertical range to account for the user's chosen text metrics and bar height.
        for offset in stride(from: 34.0, through: 90.0, by: 8.0) where prompts == 0 {
            let y = host.bounds.midY + (host.isFlipped ? offset : -offset)
            let point = host.convert(NSPoint(x: host.bounds.midX, y: y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: Int(offset),
                    clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(cardTaps, 0)
        XCTAssertTrue(reveal.isAuthenticating)
        XCTAssertFalse(window.isKeyWindow)
        try XCTUnwrap(reply)(.success(()))
        try await waitForCompletion(reveal)
        XCTAssertFalse(reveal.isConcealed(item))
        XCTAssertFalse(window.isKeyWindow)
    }

    private func sensitiveClip() -> ClipItem {
        let item = ClipItem(kind: .text, text: "Synthetic protected fixture")
        item.flags = [.secret]
        return item
    }

    private func waitForCompletion(_ reveal: SensitiveClipReveal) async throws {
        for _ in 0..<30 where reveal.isAuthenticating {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(reveal.isAuthenticating)
    }
}
