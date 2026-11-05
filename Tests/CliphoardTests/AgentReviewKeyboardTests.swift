import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Cliphoard

@MainActor
final class AgentReviewKeyboardTests: XCTestCase {
    private final class Editor: NSTextView {
        var commands: [String] = []
        override func selectAll(_ sender: Any?) { commands.append("selectAll") }
        override func paste(_ sender: Any?) { commands.append("paste") }
        override func copy(_ sender: Any?) { commands.append("copy") }
        override func cut(_ sender: Any?) { commands.append("cut") }
    }

    private func event(_ code: Int, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "",
                        charactersIgnoringModifiers: "", isARepeat: false,
                        keyCode: UInt16(code))!
    }

    func testSelectAndPasteReachFocusedEditor() {
        let editor = Editor()
        XCTAssertTrue(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_A), editor: editor))
        XCTAssertTrue(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_V), editor: editor))
        XCTAssertEqual(editor.commands, ["selectAll", "paste"])
    }

    func testCopyAndCutRequireSelectedText() {
        let editor = Editor()
        editor.string = "Invented test query"
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_C), editor: editor))
        XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_X), editor: editor))
        XCTAssertTrue(editor.commands.isEmpty)
        editor.setSelectedRange(NSRange(location: 0, length: 8))
        XCTAssertTrue(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_C), editor: editor))
        XCTAssertTrue(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_X), editor: editor))
        XCTAssertEqual(editor.commands, ["copy", "cut"])
    }

    func testNoEditorNeverHandlesCommand() {
        for code in [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X] {
            XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(code), editor: nil))
        }
    }

    func testHistoryAndUnmodifiedCommandsDoNotReachEditor() {
        let editor = Editor()
        editor.string = "Invented test query"
        editor.selectAll(nil)
        editor.commands = []
        for code in [kVK_Delete, kVK_Return, kVK_ANSI_P, kVK_ANSI_O, kVK_ANSI_1] {
            XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(code), editor: editor))
        }
        XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_C, flags: .control), editor: editor))
        XCTAssertFalse(AppDelegate.routeAgentReviewTextKey(event(kVK_ANSI_A, flags: []), editor: editor))
        XCTAssertTrue(editor.commands.isEmpty)
    }
}
