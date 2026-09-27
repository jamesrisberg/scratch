import AppKit
import ScratchKit
import SwiftUI

/// The pad editor: a plain-text NSTextView (undo, find bar, native drag out of a selection).
/// Files dropped on it fall through to the panel's drop handler (which makes a pad); text
/// dropped on it is inserted as usual.
final class ScratchTextView: NSTextView {
    weak var coordinator: EditorCoordinator?

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let coordinator else { return menu }
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(coordinator.transformMenuItem(), at: 0)
        return menu
    }
}

struct EditorView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> EditorCoordinator { EditorCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ScratchTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier("scratch.editor")
        scroll.documentView = textView

        context.coordinator.textView = textView
        model.editor = context.coordinator
        context.coordinator.sync(force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync(force: false)
    }
}

@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate {
    var model: AppModel
    weak var textView: ScratchTextView?
    private(set) var padID: String?
    private var reloadToken = -1
    private var monospace: Bool?
    private var isLoading = false

    init(model: AppModel) { self.model = model }

    static func font(monospace: Bool) -> NSFont {
        monospace ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 14)
    }

    /// Loads the selected pad when the selection changed or its text changed elsewhere, and
    /// applies the font.
    func sync(force: Bool) {
        guard let textView else { return }
        if monospace != model.monospace || force {
            monospace = model.monospace
            let font = Self.font(monospace: model.monospace)
            textView.font = font
            textView.typingAttributes[.font] = font
        }
        let id = model.selectedID
        guard force || id != padID || model.editorReload != reloadToken else { return }
        let samePad = id == padID
        padID = id
        reloadToken = model.editorReload
        let body = id.flatMap { model.store.pad($0)?.body } ?? ""
        textView.isEditable = id != nil
        guard textView.string != body else { return }
        let selection = textView.selectedRange()
        isLoading = true
        if samePad {
            // Text changed underneath (socket append): replace through the text system so the
            // edit is undoable, and keep the caret where it was.
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: whole, replacementString: body) {
                textView.replaceCharacters(in: whole, with: body)
                textView.didChangeText()
            }
            let length = (body as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        } else {
            textView.string = body
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
        isLoading = false
    }

    func focus(atEnd: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView, let window = textView.window else { return }
            self?.sync(force: false)
            window.makeFirstResponder(textView)
            if atEnd { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
        }
    }

    var isFocused: Bool { textView.map { $0.window?.firstResponder === $0 } ?? false }

    /// Pushes the editor's text to the store now (normally done on every keystroke).
    func commitIfEditing(_ id: String) {
        guard id == padID, let textView, !textView.hasMarkedText() else { return }
        model.editorDidChange(padID: id, text: textView.string)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isLoading, let id = padID, let textView else { return }
        model.editorDidChange(padID: id, text: textView.string)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        padID.map { model.undoManager(for: $0) }
    }

    // MARK: Commands

    /// Applies a transform to the selection, or to the whole pad when nothing is selected,
    /// as one undoable edit.
    func apply(_ transform: Transform) throws {
        guard let textView, padID != nil else { return }
        let selected = textView.selectedRange()
        let whole = selected.length == 0
        let range = whole ? NSRange(location: 0, length: (textView.string as NSString).length) : selected
        let source = (textView.string as NSString).substring(with: range)
        let result = try transform.apply(source)
        guard result != source else {
            model.show("\(transform.title): no change")
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: result) else { return }
        textView.replaceCharacters(in: range, with: result)
        textView.didChangeText()
        textView.undoManager?.setActionName(transform.title)
        let length = (result as NSString).length
        textView.setSelectedRange(whole ? NSRange(location: 0, length: 0) : NSRange(location: range.location, length: length))
        model.show("\(transform.title) applied to \(whole ? "the pad" : "the selection")")
    }

    /// Empties the editor as one undoable edit named "Clear". Returns false when there is
    /// nothing loaded or nothing to clear.
    func clearAll() -> Bool {
        guard let textView, padID != nil, !textView.string.isEmpty else { return false }
        if textView.hasMarkedText() { textView.unmarkText() }
        textView.breakUndoCoalescing()
        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: whole, replacementString: "") else { return false }
        textView.replaceCharacters(in: whole, with: "")
        textView.didChangeText()
        textView.undoManager?.setActionName(AppModel.clearActionName)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        return true
    }

    /// Cmd-Shift-V: pastes the clipboard's plain text with Strip Formatting applied.
    func pastePlainText() {
        guard let textView, padID != nil,
              let raw = NSPasteboard.general.string(forType: .string) else { return }
        let text = (try? Transform.stripFormatting.apply(raw)) ?? raw
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func transformMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Transform", action: nil, keyEquivalent: "")
        item.submenu = TransformMenu.make(target: self, action: #selector(transformChosen(_:)))
        return item
    }

    @objc func transformChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let transform = Transform(rawValue: raw) else { return }
        model.applyTransform(transform)
    }
}

enum TransformMenu {
    /// Grouped transforms; each item's representedObject is the transform's raw value.
    @MainActor
    static func make(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Transform")
        var group: Int?
        for transform in Transform.allCases {
            if let g = group, g != transform.group { menu.addItem(.separator()) }
            group = transform.group
            let item = NSMenuItem(title: transform.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = transform.rawValue
            menu.addItem(item)
        }
        return menu
    }
}
