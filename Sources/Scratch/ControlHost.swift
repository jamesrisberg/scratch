import AppKit
import HUDKit
import ScratchKit

/// Scratch's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/scratch.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    static let panelID = "pad"
    static let actions = ["append", "new", "open", "list", "get", "clear", "drop", "show", "hide", "toggle"]
    static let verbs = ["show", "hide", "toggle", "frame", "mode", "append", "new", "open", "list", "get", "clear", "drop"]

    /// Used when running outside a bundle (e.g. `swift run`); mirrors Sources/Scratch/Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.scratch", name: "Scratch", socket: "scratch", panels: [
        HUDManifest.Panel(id: panelID, title: "Scratch", symbol: "note.text",
                          defaultSize: HUDSize(PanelController.fullSize), compactSize: HUDSize(PanelController.compactSize),
                          capabilities: ["acceptsFileDrop", "acceptsTextDrop"],
                          verbs: verbs, settingsSchema: "settings.json", kind: .hover, order: 1),
    ])

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    private let model: AppModel
    private let panel: PanelController
    private var lastPublished: String?
    private var routerWillPublish = false
    private var pendingPublish: DispatchWorkItem?
    /// Pad edits arrive per keystroke; state events for them are coalesced over this interval.
    static let publishDelay: TimeInterval = 0.4

    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: HUDSocket.path(for: ScratchEnvironment.socketName(default: manifest.socket)),
                                 label: "scratch.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("Scratch: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.publishIfChanged() }
        model.onPadsChange = { [weak self] in self?.schedulePublish() }
        model.onSelectionChange = { [weak self] in self?.schedulePublish() }
    }

    func stop() { server.stop() }

    /// Debounced `state` push for pad changes (typing, appends, pins, deletes).
    func schedulePublish() {
        pendingPublish?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.publishIfChanged() }
        pendingPublish = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.publishDelay, execute: task)
    }

    /// Pushes `state` to subscribers when anything they can see changed.
    func publishIfChanged() {
        pendingPublish?.cancel()
        pendingPublish = nil
        let signature = panelStates.map { "\($0.visible)|\($0.mode)|\($0.badge ?? "")|\($0.status ?? "")" }.joined()
        guard signature != lastPublished else { return }
        lastPublished = signature
        if !routerWillPublish { router.publishState() }
    }

    private func routed(_ body: () throws -> Void) rethrows {
        routerWillPublish = true
        defer { routerWillPublish = false }
        try body()
        publishIfChanged()
    }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    var panelStates: [HUDPanelState] {
        [HUDPanelState(id: Self.panelID, visible: panel.isShown, mode: panel.mode,
                       badge: String(model.store.count), status: model.selectedPad?.title)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    /// MacHUD shows a hover panel while the pointer is over its dock button, so a socket show
    /// never takes focus: the editor is ready and the panel becomes key when clicked.
    func showPanel(_ id: String) throws { try check(id); routed { panel.show(takeFocus: false) } }
    func togglePanel(_ id: String) throws { try check(id); routed { panel.toggle(takeFocus: false) } }
    func hidePanel(_ id: String) throws { try check(id); routed { panel.hide() } }

    /// MacHUD's dock: `from=`/`anchor=` place the pad next to its button (or at the frame
    /// `panel frame` gave), `reason=hover` fades it in within 0.08 s without taking focus,
    /// `reason=click|summon` make it key so typing lands in the pad (the app is not activated).
    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.show(HUDPanelTransition(options)) }
    }

    /// `to=<edge>` slides toward the dock while fading out in 0.1 s; a show that arrives
    /// before it finishes (moving between hover buttons) wins.
    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.hide(HUDPanelTransition(options)) }
    }

    func togglePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.toggle(HUDPanelTransition(options)) }
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 30 else { throw HUDControlError.invalid("frame too small") }
        routed { panel.setFrame(frame) }
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    /// `parked` honours the edge/peek MacHUD passes (HUDKit 0.2) and remembers them.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        routed { panel.setMode(mode, options: options) }
    }

    // MARK: Settings

    /// Resources/settings.json from the bundle; tests set it from the source file. The router
    /// checks `settings set` values against it before `updateSettings`.
    var schema: HUDSettingsSchema? = HUDSettingsSchema.main
    var settingsSchema: HUDSettingsSchema? { schema }

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        do {
            try model.updateSettings(values)
        } catch let error as ScratchSettings.SettingsError {
            throw HUDControlError.invalid(error.description)
        }
    }

    // MARK: Actions

    static func summary(_ pad: Pad) -> [String: Any] {
        ["id": pad.id, "title": pad.title, "pinned": pad.pinned, "inbox": pad.isInbox,
         "created": ISO8601DateFormatter().string(from: pad.createdAt),
         "updated": ISO8601DateFormatter().string(from: pad.updatedAt),
         "chars": pad.body.count]
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        do {
            switch name {
            case "show", "hide", "toggle":
                switch name {
                case "show": panel.show(takeFocus: false)
                case "hide": panel.hide()
                default: panel.toggle(takeFocus: false)
                }
                done(["ok": true, "visible": panel.isShown])
            case "append":
                guard let text = args["text"], !text.isEmpty else { throw HUDControlError.invalid("text= required") }
                let pad: Pad
                if let id = args["id"], !id.isEmpty {
                    guard let appended = model.append(text, to: id) else { throw HUDControlError.invalid("no pad \(id)") }
                    pad = appended
                } else {
                    pad = model.appendToInbox(text)
                }
                if Self.flag(args["show"]) { model.select(pad.id); panel.showBriefly() }
                done(["ok": true, "pad": Self.summary(pad)])
            case "new":
                let text = args["text"] ?? ""
                let title = args["title"].flatMap { $0.isEmpty ? nil : $0 }
                let pad = model.newPad(body: text, title: title, select: true)
                if Self.flag(args["show"]) { panel.show(takeFocus: false) }
                done(["ok": true, "pad": Self.summary(pad)])
            case "open":
                guard let id = args["id"], !id.isEmpty else { throw HUDControlError.invalid("id= required") }
                guard model.store.pad(id) != nil else { throw HUDControlError.invalid("no pad \(id)") }
                model.select(id)
                if panel.mode == .parked { panel.setMode(.full) }
                panel.show(takeFocus: false)
                done(["ok": true, "pad": Self.summary(model.store.pad(id)!)])
            case "clear":
                let id = args["id"].flatMap { $0.isEmpty ? nil : $0 } ?? model.selectedID ?? ""
                guard let pad = model.clear(id) else { throw HUDControlError.invalid(id.isEmpty ? "id= required" : "no pad \(id)") }
                done(["ok": true, "pad": Self.summary(pad)])
            case "list":
                let pads = (args["query"].map { model.store.search($0) } ?? model.store.sorted)
                done(["ok": true, "count": pads.count, "pads": pads.map(Self.summary)])
            case HUDDrop.action:
                // Files dropped on MacHUD's dock button: the same as dropping them on the panel.
                let urls = HUDDrop.urls(from: args)
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !urls.isEmpty else { throw HUDControlError.invalid("paths= needs at least one existing file") }
                let pads = model.importFiles(urls)
                done(["ok": true, "count": pads.count, "pads": pads.map(Self.summary)])
            case "get":
                let id = args["id"] ?? model.selectedID ?? ""
                guard let pad = model.store.pad(id) else { throw HUDControlError.invalid(id.isEmpty ? "id= required" : "no pad \(id)") }
                var result = Self.summary(pad)
                result["body"] = pad.body
                done(["ok": true, "pad": result])
            default:
                throw HUDControlError.invalid("unknown action \(name) (\(Self.actions.joined(separator: ", ")))")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    func quit() { NSApp.terminate(nil) }
}
