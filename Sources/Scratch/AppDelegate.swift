import AppKit
import HUDKit
import ScratchKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var control: ControlHost!
    static let toggleHotKey = HUDHotKey(key: "n", modifiers: ["control", "option"])
    static let pasteHotKey = HUDHotKey(key: "v", modifiers: ["control", "option", "shift"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "Scratch")
        let store = PadStore(directory: ScratchEnvironment.padsDirectory)
        model = AppModel(store: store, settingsURL: ScratchEnvironment.settingsURL)
        panel = PanelController(model: model)
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        // A `--snapshot` run only draws: no control socket (a running app owns that name), no
        // announcement, no hotkey, no menu bar item.
        let snapshotting = value("--snapshot") != nil
        control = ControlHost(model: model, panel: panel)
        if !snapshotting {
            control.start()
            setupStatusItem()
            // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
            control.router.menuProvider = { [weak self] in self?.statusItem?.menu }
            // The menuBar.consumed opt-out lives in <home>/menubar.json, so SCRATCH_HOME isolates it.
            HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(ScratchEnvironment.baseDirectory))
            if ScratchEnvironment.hotKeysEnabled {
                if HUDHotKeyCenter.shared.register(Self.toggleHotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                    model.show("⌃⌥N is taken by another app; use the menu bar icon", error: true)
                }
                if HUDHotKeyCenter.shared.register(Self.pasteHotKey, onPress: { [weak self] in self?.pasteToScratch() }) == nil {
                    model.show("⌃⌥⇧V is taken by another app", error: true)
                }
            }
        }
        // `--select <id>`: start on that pad (used with --snapshot).
        if let id = value("--select") { model.select(id) }
        // `--search <query>`: start with a sidebar search (used with --snapshot).
        if let query = value("--search") { model.searchText = query }
        panel.show()

        // `--snapshot <path.png>`: write a PNG of the panel after it settles (for docs and for
        // verifying the UI without Screen Recording permission). `--snapshot-mode compact`
        // pictures the strip.
        if let path = value("--snapshot") {
            if value("--snapshot-mode") == "compact" { panel.setMode(.compact) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.panel.writeSnapshot(to: URL(fileURLWithPath: path))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.store.flush()
        control?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    /// ⌃⌥⇧V: the clipboard's text (or file paths) onto the inbox pad, and a glimpse of it.
    /// Reads the pasteboard only; never writes it.
    private func pasteToScratch() {
        let pb = NSPasteboard.general
        var text = pb.string(forType: .string)
        if text?.isEmpty ?? true,
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            text = urls.map(\.path).joined(separator: "\n")
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            model.show("Nothing to paste: the clipboard has no text", error: true)
            if model.settings.inboxShowsPanel { panel.showBriefly() }
            return
        }
        let pad = model.appendToInbox(text)
        model.select(pad.id)
        model.show("Added to Inbox (\(TextStats(text).summary))")
        if model.settings.inboxShowsPanel { panel.showBriefly() }
    }

    // MARK: - Status item

    private enum Tag: Int { case toggle = 1, compact, monospace, sidebar }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "note.text", accessibilityDescription: "Scratch")

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Show Scratch", action: #selector(togglePanel), keyEquivalent: "n")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.tag = Tag.toggle.rawValue
        menu.addItem(toggle)
        let paste = NSMenuItem(title: "Paste to Inbox", action: #selector(pasteFromMenu), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = [.control, .option, .shift]
        menu.addItem(paste)
        menu.addItem(NSMenuItem(title: "New Pad", action: #selector(newPad), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Pad", action: #selector(clearPad), keyEquivalent: ""))
        menu.addItem(.separator())
        let sidebar = NSMenuItem(title: "Pad List", action: #selector(toggleSidebar), keyEquivalent: "")
        sidebar.tag = Tag.sidebar.rawValue
        menu.addItem(sidebar)
        let compact = NSMenuItem(title: "Compact Strip", action: #selector(toggleCompact), keyEquivalent: "")
        compact.tag = Tag.compact.rawValue
        menu.addItem(compact)
        let mono = NSMenuItem(title: "Monospaced Font", action: #selector(toggleMonospace), keyEquivalent: "")
        mono.tag = Tag.monospace.rawValue
        menu.addItem(mono)
        let transforms = NSMenuItem(title: "Transform Pad", action: nil, keyEquivalent: "")
        transforms.submenu = TransformMenu.make(target: self, action: #selector(transformChosen(_:)))
        menu.addItem(transforms)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reveal Pads Folder", action: #selector(revealPads), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Scratch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) && item.target == nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch Tag(rawValue: item.tag) {
            case .toggle: item.title = panel.isVisible ? "Hide Scratch" : "Show Scratch"
            case .compact: item.state = panel.mode == .compact ? .on : .off
            case .monospace: item.state = model.monospace ? .on : .off
            case .sidebar: item.state = model.sidebarVisible ? .on : .off
            case nil: break
            }
        }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func pasteFromMenu() { pasteToScratch() }
    @objc private func newPad() {
        if panel.mode != .full { panel.setMode(.full, takeFocus: true) }
        panel.show()
        model.newPad()
    }
    @objc private func toggleCompact() { panel.setMode(panel.mode == .compact ? .full : .compact, takeFocus: true) }
    @objc private func clearPad() {
        if panel.mode != .full { panel.setMode(.full, takeFocus: true) }
        panel.show()
        if let id = model.selectedID { model.clear(id) }
    }
    @objc private func toggleSidebar() { model.toggleSidebar() }
    @objc private func toggleMonospace() { model.toggleMonospace() }
    @objc private func transformChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let transform = Transform(rawValue: raw) else { return }
        if panel.mode != .full { panel.setMode(.full, takeFocus: true) }
        panel.show()
        // Menu-bar transforms apply to the whole pad: clear any selection first.
        model.editor?.textView?.setSelectedRange(NSRange(location: 0, length: 0))
        model.applyTransform(transform)
    }
    @objc private func revealPads() {
        let dir = model.store.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
