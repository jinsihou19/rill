import AppKit
import XCTest
@testable import RillApp

@MainActor
final class CommandInputSelectionTests: XCTestCase {
    private final class CustomEditorWindow: NSWindow {
        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? { nil }
    }

    private func fixture(_ text: String) throws -> (NSWindow, NSTextField, NSTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 10, y: 10, width: 480, height: 24)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (window, field, editor)
    }

    func testCancelRestoresEndAndMiddleCaretBeforeContinuingDraft() async throws {
        for (text, location, insertion, expected) in [("GET app:ver", 11, "sion", "GET app:version"),
                                                       ("GET appversion", 7, ":", "GET app:version")] {
            let (window, field, editor) = try fixture(text)
            defer { window.close() }
            editor.setSelectedRange(NSRange(location: location, length: 0))
            let saved = try XCTUnwrap(CommandInputSelection.capture(in: window, text: text))
            editor.selectAll(nil)
            XCTAssertTrue(saved.restore(ifUnchanged: text))
            let restored = try XCTUnwrap(field.currentEditor() as? NSTextView)
            restored.insertText(insertion, replacementRange: restored.selectedRange())
            XCTAssertEqual(restored.string, expected)
        }
    }

    func testCancelRestoresUnicodeSelectionForReplacement() async throws {
        let text = "GET 用户:🔑"
        let (window, field, editor) = try fixture(text)
        defer { window.close() }
        let range = (text as NSString).range(of: "用户:🔑")
        editor.setSelectedRange(range)
        let saved = try XCTUnwrap(CommandInputSelection.capture(in: window, text: text))
        editor.selectAll(nil)
        XCTAssertTrue(saved.restore(ifUnchanged: text))
        let restored = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(restored.selectedRange(), range)
        restored.insertText("other", replacementRange: restored.selectedRange())
        XCTAssertEqual(restored.string, "GET other")
    }

    func testStaleSelectionDoesNotReplaceChangedCommand() async throws {
        let (window, field, editor) = try fixture("GET old")
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 4, length: 3))
        let saved = try XCTUnwrap(CommandInputSelection.capture(in: window, text: "GET old"))
        field.stringValue = "PING"
        XCTAssertFalse(saved.restore(ifUnchanged: "PING"))
        XCTAssertEqual(field.stringValue, "PING")
        XCTAssertNil(CommandInputSelection.capture(in: nil, text: "PING"))
    }

    func testCustomFieldEditorWorksWithoutDefaultWindowEditor() async throws {
        _ = NSApplication.shared
        let window = CustomEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        editor.isFieldEditor = true; editor.string = "GET app:ver"
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNil(window.fieldEditor(false, for: nil))
        editor.setSelectedRange(NSRange(location: 11, length: 0))
        let saved = try XCTUnwrap(CommandInputSelection.capture(in: window, text: editor.string))
        editor.selectAll(nil)
        XCTAssertTrue(saved.restore(ifUnchanged: "GET app:ver"))
        editor.insertText("sion", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "GET app:version")
    }
}
