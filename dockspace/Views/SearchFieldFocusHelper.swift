import AppKit

/// AppKit fallback for focusing SwiftUI `TextField` inside an `NSHostingView`.
/// SwiftUI `@FocusState` alone is unreliable on borderless `NSPanel` windows.
enum SearchFieldFocusHelper {

    /// Focuses the first editable text field in the panel and places the caret at the end.
    @discardableResult
    static func focus(in window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        guard let field = findEditableTextField(in: window.contentView) else { return false }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)

        if let editor = field.currentEditor() {
            let length = field.stringValue.utf16.count
            editor.selectedRange = NSRange(location: length, length: 0)
        }

        return true
    }

    private static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }

        if let field = view as? NSTextField, field.isEditable, field.isEnabled {
            return field
        }

        for subview in view.subviews {
            if let field = findEditableTextField(in: subview) {
                return field
            }
        }
        return nil
    }
}
