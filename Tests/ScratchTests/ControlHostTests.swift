import AppKit
import HUDKit
@testable import Scratch
import ScratchKit
import XCTest

/// The socket side of the single-pad experience: `action clear`, and the manifest MacHUD reads.
@MainActor
final class ControlHostTests: XCTestCase {
    private var dir: URL!
    private var model: AppModel!
    private var control: ControlHost!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchHostTests-\(UUID().uuidString)")
        let store = PadStore(directory: dir.appendingPathComponent("pads"), autosaveDelay: 0.05)
        model = AppModel(store: store, settingsURL: dir.appendingPathComponent("preferences.json"))
        control = ControlHost(model: model, panel: PanelController(model: model))
    }

    override func tearDown() async throws {
        control = nil
        model = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func send(_ verb: String, _ args: [String: String]) -> [String: Any] {
        var response: [String: Any] = [:]
        control.router.handle(verb, args: args) { response = $0 }
        return response
    }

    func testStartsOnOneEmptyPadWithTheSidebarHidden() {
        XCTAssertEqual(model.store.count, 1, "there is always a pad to type into")
        XCTAssertNotNil(model.selectedPad)
        XCTAssertFalse(model.sidebarVisible)
        XCTAssertEqual(send("settings", ["action": "set", "sidebar.visible": "true"])["ok"] as? Bool, true)
        XCTAssertTrue(model.sidebarVisible)
        model.toggleSidebar()
        XCTAssertFalse(model.sidebarVisible)
        XCTAssertFalse(ScratchSettings.load(from: dir.appendingPathComponent("preferences.json")).sidebarVisible)
    }

    func testRouterClearEmptiesThePadAndKeepsIt() throws {
        let created = send("action", ["_": "new", "text": "hello\nworld"])
        let id = try XCTUnwrap((created["pad"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(model.selectedID, id)
        let count = model.store.count

        let cleared = send("action", ["_": "clear"])
        XCTAssertEqual(cleared["ok"] as? Bool, true)
        let summary = try XCTUnwrap(cleared["pad"] as? [String: Any])
        XCTAssertEqual(summary["id"] as? String, id)
        XCTAssertEqual(summary["chars"] as? Int, 0)
        XCTAssertEqual(summary["title"] as? String, Pad.untitled, "a derived title resets")
        XCTAssertEqual(model.store.count, count, "clear keeps the pad")
        let got = send("action", ["name": "get", "id": id])
        XCTAssertEqual((got["pad"] as? [String: Any])?["body"] as? String, "")

        // One undoable step.
        model.listUndo.undo()
        XCTAssertEqual(model.store.pad(id)?.body, "hello\nworld")
    }

    /// The pad in the editor is cleared through the text system: one Cmd-Z brings it back.
    func testClearInTheEditorIsOneUndoableStep() throws {
        let pad = model.newPad(body: "first line\nsecond")
        let editor = EditorCoordinator(model: model)
        let textView = ScratchTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        textView.allowsUndo = true
        textView.delegate = editor
        editor.textView = textView
        model.editor = editor
        editor.sync(force: true)
        XCTAssertEqual(textView.string, "first line\nsecond")

        model.clear(pad.id)
        XCTAssertEqual(textView.string, "")
        XCTAssertEqual(model.store.pad(pad.id)?.body, "")
        XCTAssertEqual(model.store.pad(pad.id)?.title, Pad.untitled)
        let undo = model.undoManager(for: pad.id)
        XCTAssertEqual(undo.undoActionName, AppModel.clearActionName)
        undo.undo()
        XCTAssertEqual(textView.string, "first line\nsecond")
        XCTAssertEqual(model.store.pad(pad.id)?.body, "first line\nsecond", "the undo reaches the store")
        undo.redo()
        XCTAssertEqual(model.store.pad(pad.id)?.body, "")
    }

    func testRouterClearByIDKeepsAnExplicitTitle() throws {
        let other = model.newPad(body: "log line", title: "Build log", select: false)
        let response = send("action", ["_": "clear", "id": other.id])
        XCTAssertEqual((response["pad"] as? [String: Any])?["title"] as? String, "Build log")
        XCTAssertEqual(model.store.pad(other.id)?.body, "")
        XCTAssertEqual(send("action", ["_": "clear", "id": "missing"])["ok"] as? Bool, false)
    }

    private static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testDropMakesAPadPerFileLikeAPanelDrop() throws {
        let files = dir.appendingPathComponent("dropped")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let text = files.appendingPathComponent("a b|c.txt")
        try "hello from a file\n".write(to: text, atomically: true, encoding: .utf8)
        let binary = files.appendingPathComponent("blob.bin")
        try Data([0, 1, 2, 0]).write(to: binary)
        let before = model.store.count
        // What MacHUD sends, and what the CLI's `scratch action drop paths=...` sends.
        let response = send("action", ["name": "drop", "paths": HUDDrop.encode([text, binary])])
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)")
        XCTAssertEqual(response["count"] as? Int, 2)
        XCTAssertEqual(model.store.count, before + 2)
        let pads = try XCTUnwrap(response["pads"] as? [[String: Any]])
        XCTAssertEqual(pads.map { $0["title"] as? String }, ["a b|c.txt", "blob.bin"])
        let textPad = try XCTUnwrap(model.store.pad(pads[0]["id"] as! String))
        XCTAssertEqual(textPad.body, PadImport.draft(forFile: text).body, "the same pad a panel drop makes")
        XCTAssertTrue(textPad.body.contains("hello from a file"))
        let binPad = try XCTUnwrap(model.store.pad(pads[1]["id"] as! String))
        XCTAssertFalse(PadImport.draft(forFile: binary).inlined)
        XCTAssertEqual(binPad.body, "[blob.bin](\(binary.absoluteString))\n", "other files become a link")
        XCTAssertEqual(model.selectedID, binPad.id, "the last dropped pad is selected")
        let cli = HUDSocketClient.parseArguments(["drop", "paths=\(HUDDrop.encode([text]))"])
        XCTAssertEqual(send("action", cli)["count"] as? Int, 1)
        XCTAssertEqual(send("action", ["name": "drop", "paths": "/no/such/file"])["ok"] as? Bool, false)
        XCTAssertEqual(send("action", ["name": "drop"])["ok"] as? Bool, false)
    }

    func testAutosaveDelayIsANumberSettingWithBounds() throws {
        control.schema = try HUDSettingsSchema.decode(Data(contentsOf: Self.repo
            .appendingPathComponent("Sources/Scratch/Resources/settings.json")))
        let served = try XCTUnwrap((send("settings", ["action": "schema"])["schema"] as? [String: Any])?["settings"] as? [[String: Any]])
        let field = try XCTUnwrap(served.first { $0["key"] as? String == "autosaveDelay" })
        XCTAssertEqual(field["type"] as? String, "number")
        XCTAssertEqual(field["min"] as? Double, ScratchSettings.autosaveRange.lowerBound)
        XCTAssertEqual(field["max"] as? Double, ScratchSettings.autosaveRange.upperBound)
        XCTAssertEqual(field["step"] as? Double, 0.05)
        XCTAssertEqual(field["default"] as? Double, ScratchSettings().autosaveDelay)
        let set = send("settings", ["action": "set", "autosaveDelay": "0.5"])
        XCTAssertEqual(set["ok"] as? Bool, true, "\(set)")
        XCTAssertEqual((set["settings"] as? [String: Any])?["autosaveDelay"] as? Double, 0.5)
        XCTAssertEqual(send("settings", ["action": "set", "autosaveDelay": "12"])["error"] as? String,
                       "autosaveDelay must be at most 10")
        XCTAssertEqual(send("settings", ["action": "set", "autosaveDelay": "0.05"])["ok"] as? Bool, false)
        XCTAssertEqual(send("settings", ["action": "set", "autosaveDelay": "soon"])["ok"] as? Bool, false)
        XCTAssertEqual(model.settings.autosaveDelay, 0.5, "rejected values change nothing")
        // Without the schema (swift run) Scratch's own validation agrees with the bounds.
        XCTAssertThrowsError(try ScratchSettings().applying(["autosaveDelay": "10.01"]))
        XCTAssertNoThrow(try ScratchSettings().applying(["autosaveDelay": "0.1"]))
    }

    func testBuiltinManifestMirrorsTheBundledOne() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Scratch/Resources/machud.json")
        let bundled = try HUDManifest.decode(Data(contentsOf: url))
        XCTAssertEqual(ControlHost.builtinManifest, bundled)
        XCTAssertEqual(bundled.panel(id: "pad")?.kind, .hover)
    }
}
