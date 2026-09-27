import AppKit
import ScratchKit
import SwiftUI

/// A transient footer message, optionally with an Undo button.
struct Flash: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError = false
    var undo: (() -> Void)?

    static func == (a: Flash, b: Flash) -> Bool { a.id == b.id }
}

/// App state shared by the panel, the control socket and the menu bar item.
@MainActor
final class AppModel: ObservableObject {
    let store: PadStore
    let settingsURL: URL

    @Published private(set) var pads: [Pad] = []
    @Published var selectedID: String? {
        didSet { if selectedID != oldValue { onSelectionChange?() } }
    }
    @Published var searchText = ""
    @Published var monospace: Bool
    @Published var isCompact = false
    @Published private(set) var flash: Flash?
    /// Bumped when the selected pad's body changed from outside the editor (socket, inbox),
    /// so the editor reloads its text.
    @Published private(set) var editorReload = 0
    /// Bumped to ask the sidebar to focus its search field.
    @Published private(set) var searchFocusRequest = 0
    @Published var isDropTargeted = false
    @Published private(set) var settings: ScratchSettings

    /// The live editor, for transforms, plain paste and focus.
    weak var editor: EditorCoordinator?
    /// Called after any change to the pads (for debounced `state` events).
    var onPadsChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    /// Undo for sidebar operations (delete); text edits use per-pad undo managers.
    let listUndo = UndoManager()
    private var textUndo: [String: UndoManager] = [:]
    private var undoObservers: [NSObjectProtocol] = []
    private var flashTask: DispatchWorkItem?

    init(store: PadStore, settingsURL: URL) {
        self.store = store
        self.settingsURL = settingsURL
        let settings = ScratchSettings.load(from: settingsURL)
        self.settings = settings
        monospace = settings.defaultMonospace
        store.autosaveDelay = settings.autosaveDelay
        store.inboxPosition = settings.inbox
        store.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        do { try store.load() } catch { show("Could not read pads: \(error.localizedDescription)", error: true) }
        pads = store.sorted
        // Scratch is one pad you type into: always have one, and open on the one last worked on.
        if pads.isEmpty { store.create() }
        selectedID = Self.currentPad(in: store.sorted)?.id
    }

    /// The pad to open on: the most recently edited one, preferring anything over the inbox.
    static func currentPad(in pads: [Pad]) -> Pad? {
        let recent = pads.sorted { $0.updatedAt > $1.updatedAt }
        return recent.first { !$0.isInbox } ?? recent.first
    }

    private func storeDidChange() {
        pads = store.sorted
        if let id = selectedID, store.pad(id) == nil { selectedID = pads.first?.id }
        onPadsChange?()
    }

    // MARK: - Queries

    var visiblePads: [Pad] { searchText.isEmpty ? pads : store.search(searchText) }
    var selectedPad: Pad? { selectedID.flatMap(store.pad) }

    func undoManager(for padID: String) -> UndoManager {
        if let existing = textUndo[padID] { return existing }
        let manager = UndoManager()
        textUndo[padID] = manager
        // NSTextView does not always report undo/redo edits through textDidChange, so push the
        // editor's text to the store after every undo or redo (a no-op when unchanged).
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, NSNotification.Name.NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.editor?.commitIfEditing(padID) }
            })
        }
        return manager
    }

    // MARK: - Pads

    @discardableResult
    func newPad(body: String = "", title: String? = nil, select: Bool = true) -> Pad {
        let pad = store.create(body: body, title: title)
        if select {
            searchText = ""
            selectedID = pad.id
            editor?.focus(atEnd: true)
        }
        return pad
    }

    func select(_ id: String) {
        guard store.pad(id) != nil else { return }
        if !visiblePads.contains(where: { $0.id == id }) { searchText = "" }
        selectedID = id
    }

    func togglePin(_ id: String) {
        guard let pad = store.pad(id) else { return }
        store.setPinned(id, !pad.pinned)
    }

    /// Sets a pad's title from the header; an empty title (or the one derived from the body)
    /// goes back to deriving it from the first line.
    func rename(_ id: String, to raw: String) {
        guard let pad = store.pad(id) else { return }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != pad.title else { return }
        store.setTitle(id, title.isEmpty || title == Pad.deriveTitle(from: pad.body) ? nil : title)
    }

    /// Empties a pad's body in one undoable step and keeps the pad. The pad in the editor is
    /// cleared through the text system, so Cmd-Z undoes it like any edit; another pad (from the
    /// socket) is cleared in the store with a sidebar-level undo. Long pads get a
    /// "Cleared — Undo" toast for 5 s instead of a confirmation.
    @discardableResult
    func clear(_ id: String) -> Pad? {
        guard let pad = store.pad(id) else { return nil }
        guard !pad.body.isEmpty else {
            if id == selectedID { show("Nothing to clear") }
            return pad
        }
        let undo: () -> Void
        if id == selectedID, let editor, editor.padID == id, editor.clearAll() {
            editor.commitIfEditing(id)
            let manager = undoManager(for: id)
            undo = { [weak self] in
                if manager.canUndo, manager.undoActionName == Self.clearActionName { manager.undo() }
                self?.flash = nil
            }
        } else {
            editor?.commitIfEditing(id)
            guard let before = store.clear(id) else { return store.pad(id) }
            externalChange(id)
            listUndo.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.store.restore(before)
                    model.externalChange(before.id)
                }
            }
            listUndo.setActionName(Self.clearActionName)
            undo = { [weak self] in self?.listUndo.undo(); self?.flash = nil }
        }
        if Pad.clearNeedsToast(pad.body) {
            show("Cleared", undo: undo, duration: 5)
        } else {
            show("Cleared")
        }
        return store.pad(id)
    }

    static let clearActionName = "Clear"

    func delete(_ id: String) {
        editor?.commitIfEditing(id)
        let list = visiblePads
        let index = list.firstIndex { $0.id == id }
        guard let removed = store.delete(id) else { return }
        textUndo[id] = nil
        if selectedID == id || selectedID == nil {
            let remaining = visiblePads
            selectedID = index.flatMap { remaining.indices.contains($0) ? remaining[$0].id : remaining.last?.id } ?? remaining.first?.id
        }
        let restore = { [weak self] in
            guard let self else { return }
            self.store.restore(removed)
            self.selectedID = removed.id
            self.show("Restored “\(removed.title)”")
        }
        listUndo.registerUndo(withTarget: self) { _ in MainActor.assumeIsolated { restore() } }
        listUndo.setActionName("Delete Pad")
        show("Deleted “\(removed.title)”", undo: { [weak self] in self?.listUndo.undo() })
    }

    /// From the editor: the user typed.
    func editorDidChange(padID: String, text: String) {
        store.update(padID, body: text)
    }

    /// Text arrived from outside the editor (socket, hotkey, drop) for `padID`.
    private func externalChange(_ padID: String) {
        if padID == selectedID { editorReload += 1 }
    }

    @discardableResult
    func appendToInbox(_ text: String) -> Pad {
        editor?.commitIfEditing(Pad.inboxID)
        let pad = store.appendToInbox(text)
        externalChange(pad.id)
        return pad
    }

    @discardableResult
    func append(_ text: String, to id: String) -> Pad? {
        editor?.commitIfEditing(id)
        let pad = store.append(text, to: id)
        if let pad { externalChange(pad.id) }
        return pad
    }

    /// Dropped files (on the panel or, as `action drop`, on MacHUD's dock button): one pad per
    /// file, see `PadImport`. The last one is selected. Returns the new pads.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [Pad] {
        var pads: [Pad] = []
        for url in urls {
            let draft = PadImport.draft(forFile: url)
            pads.append(store.create(body: draft.body, title: draft.title))
        }
        if let last = pads.last {
            searchText = ""
            selectedID = last.id
            show(urls.count == 1 ? "Added “\(last.title)”" : "Added \(urls.count) pads")
        }
        return pads
    }

    func importText(_ text: String) {
        guard !text.isEmpty else { return }
        newPad(body: text)
        show("New pad from dropped text")
    }

    // MARK: - Editing commands

    func applyTransform(_ transform: Transform) {
        guard let editor else { return }
        do {
            try editor.apply(transform)
        } catch {
            show("\(error)", error: true)
        }
    }

    /// Cmd-Shift-C: the whole pad onto the clipboard.
    func copyPad() {
        guard let id = selectedID else { return }
        editor?.commitIfEditing(id)
        guard let pad = store.pad(id) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pad.body, forType: .string)
        show("Copied “\(pad.title)” (\(TextStats(pad.body).summary))")
    }

    func toggleMonospace() { monospace.toggle() }

    var sidebarVisible: Bool { settings.sidebarVisible }

    /// Cmd-Shift-L or the header chevron; remembered as the `sidebar.visible` setting.
    func toggleSidebar() {
        try? updateSettings(["sidebar.visible": sidebarVisible ? "false" : "true"])
    }
    func focusSearch() { searchFocusRequest += 1 }

    // MARK: - Settings

    func updateSettings(_ values: [String: String]) throws {
        let next = try settings.applying(values)
        if next.defaultMonospace != settings.defaultMonospace { monospace = next.defaultMonospace }
        settings = next
        store.autosaveDelay = next.autosaveDelay
        store.inboxPosition = next.inbox
        do { try next.save(to: settingsURL) } catch { show("Could not save settings: \(error.localizedDescription)", error: true) }
    }

    // MARK: - Flash

    func show(_ text: String, error: Bool = false, undo: (() -> Void)? = nil, duration: TimeInterval? = nil) {
        flashTask?.cancel()
        flash = Flash(text: text, isError: error, undo: undo)
        let task = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (duration ?? (undo == nil ? 3 : 6)), execute: task)
    }
}
