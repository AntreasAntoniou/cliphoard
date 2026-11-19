import AppKit
import LocalAuthentication
import SwiftUI
import XCTest
@testable import Cliphoard

@MainActor
final class SensitiveRevealInteractionTests: XCTestCase {
    func testAuthenticationKeepsDismissGuardUntilFocusReturns() async throws {
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        var focusRestorations = 0
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in reply = callback },
            restoreFocus: { _ in focusRestorations += 1; return true }, observeSystemEvents: false)
        let item = sensitiveClip()
        reveal.reveal(item)
        XCTAssertTrue(reveal.isAuthenticating)
        try XCTUnwrap(reply)(.success(()))
        await Task.yield()
        XCTAssertTrue(reveal.isAuthenticating, "macOS can report success before returning key focus")
        XCTAssertTrue(reveal.isConcealed(item))
        try await waitForCompletion(reveal)
        XCTAssertEqual(focusRestorations, 1)
        XCTAssertFalse(reveal.isConcealed(item))
        reveal.lock()
    }

    func testSuccessfulAuthenticationWaitsForTheOriginalWindow() async throws {
        var focusChecks = 0
        let reveal = SensitiveClipReveal(authenticate: { _, _, reply in reply(.success(())) },
            restoreFocus: { _ in
                focusChecks += 1
                return focusChecks == 8
            }, observeSystemEvents: false)
        let item = sensitiveClip()
        defer { reveal.lock() }
        reveal.reveal(item)
        try await Task.sleep(for: .milliseconds(275))
        XCTAssertTrue(reveal.isAuthenticating)
        XCTAssertTrue(reveal.isConcealed(item))
        try await waitForCompletion(reveal)
        XCTAssertEqual(focusChecks, 8)
        XCTAssertFalse(reveal.isConcealed(item))
    }

    func testSwitchingAwayOrLockingDuringAuthenticationStaysConcealed() async throws {
        var reply: (@Sendable (Result<Void, SensitiveRevealFailure>) -> Void)?
        let reveal = SensitiveClipReveal(authenticate: { _, _, callback in reply = callback },
            restoreFocus: { _ in false }, focusTimeout: .milliseconds(300), observeSystemEvents: false)
        let item = sensitiveClip()
        reveal.reveal(item)
        try XCTUnwrap(reply)(.success(()))
        try await waitForCompletion(reveal)
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertEqual(reveal.authenticationFailure(for: item), .focusDidNotReturn)
        reveal.reveal(item)
        let lateReply = try XCTUnwrap(reply)
        reveal.lock()
        lateReply(.success(()))
        await Task.yield()
        XCTAssertTrue(reveal.isConcealed(item))
        XCTAssertFalse(reveal.isAuthenticating)
        XCTAssertNil(reveal.authenticationFailure(for: item))
    }

    func testCancellingAuthenticationReturnsFocusButStaysConcealed() async throws {
        var restored = false
        let reveal = SensitiveClipReveal(authenticate: { _, _, reply in reply(.failure(.cancelled)) },
            restoreFocus: { _ in restored = true; return true }, observeSystemEvents: false)
        let item = sensitiveClip()
        reveal.reveal(item)
        try await waitForCompletion(reveal)
        XCTAssertTrue(restored)
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
        let reveal = SensitiveClipReveal(authenticate: { _, _, _ in prompts += 1 },
            observeSystemEvents: false)
        let card = ClipCardView(sensitiveReveal: reveal, item: sensitiveClip(), index: 0,
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
