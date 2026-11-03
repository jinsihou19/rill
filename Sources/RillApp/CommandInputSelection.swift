import AppKit

@MainActor
struct CommandInputSelection {
    private weak var window: NSWindow?
    private weak var editor: NSTextView?
    private let text: String
    private let range: NSRange
    private let affinity: NSSelectionAffinity

    static func capture(in window: NSWindow?, text: String) -> Self? {
        // SwiftUI may use a custom field editor instead of the window's default editor.
        guard let window, let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor, editor.window === window, editor.string == text,
              editor.selectedRange().location != NSNotFound else { return nil }
        return Self(window: window, editor: editor, text: text, range: editor.selectedRange(), affinity: editor.selectionAffinity)
    }

    @discardableResult
    func restore(ifUnchanged currentText: String) -> Bool {
        guard currentText == text, let window, let editor, editor.window === window,
              editor.isEditable, editor.string == text else { return false }
        let length = (text as NSString).length
        guard range.location <= length, range.length <= length - range.location else { return false }
        guard window.makeFirstResponder(editor) else { return false }
        editor.setSelectedRange(range, affinity: affinity, stillSelecting: false)
        return true
    }
}
