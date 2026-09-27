import Foundation
import XCTest
@testable import ScratchKit

final class ImportAndSettingsTests: TempDirTestCase {
    func testTextFileIsInlined() throws {
        let url = dir.appendingPathComponent("notes file.txt")
        try "hello\nworld".write(to: url, atomically: true, encoding: .utf8)
        let draft = PadImport.draft(forFile: url)
        XCTAssertEqual(draft.title, "notes file.txt")
        XCTAssertTrue(draft.inlined)
        XCTAssertEqual(draft.body, "[notes file.txt](\(url.absoluteString))\n\nhello\nworld\n")
        XCTAssertTrue(draft.body.contains("file://") && draft.body.contains("notes%20file.txt"))
    }

    func testBinaryAndLargeFilesAreLinkedOnly() throws {
        let bin = dir.appendingPathComponent("blob.bin")
        try Data([0xFF, 0x00, 0xFE, 0x01]).write(to: bin)
        XCTAssertFalse(PadImport.draft(forFile: bin).inlined)

        let big = dir.appendingPathComponent("big.txt")
        try String(repeating: "x", count: PadImport.maxInlineBytes).write(to: big, atomically: true, encoding: .utf8)
        let draft = PadImport.draft(forFile: big)
        XCTAssertFalse(draft.inlined)
        XCTAssertEqual(draft.body, "[big.txt](\(big.absoluteString))\n")

        XCTAssertFalse(PadImport.draft(forFile: dir).inlined, "folders are linked")
    }

    func testSettingsApplyValidatesAll() throws {
        let s = ScratchSettings()
        let changed = try s.applying(["defaultMonospace": "off", "autosaveDelay": "2", "inboxPosition": "prepend"])
        XCTAssertFalse(changed.defaultMonospace)
        XCTAssertEqual(changed.autosaveDelay, 2)
        XCTAssertEqual(changed.inbox, .prepend)
        XCTAssertThrowsError(try s.applying(["autosaveDelay": "0"]))
        XCTAssertThrowsError(try s.applying(["inboxPosition": "sideways"]))
        XCTAssertThrowsError(try s.applying(["defaultMonospace": "maybe"]))
        XCTAssertThrowsError(try s.applying(["nope": "1"]))
    }

    func testSettingsPersistAndTolerateMissingKeys() throws {
        let url = dir.appendingPathComponent("preferences.json")
        XCTAssertEqual(ScratchSettings.load(from: url), ScratchSettings())
        var s = ScratchSettings()
        s.autosaveDelay = 3
        s.inboxShowsPanel = false
        try s.save(to: url)
        XCTAssertEqual(ScratchSettings.load(from: url), s)
        try #"{"autosaveDelay": 5}"#.write(to: url, atomically: true, encoding: .utf8)
        let partial = ScratchSettings.load(from: url)
        XCTAssertEqual(partial.autosaveDelay, 5)
        XCTAssertTrue(partial.defaultMonospace)
    }

    func testLoadMergesSavedValuesKeyByKey() throws {
        let url = dir.appendingPathComponent("preferences.json")
        // One value of the wrong type (an older or hand-edited file) falls back alone.
        try #"{"autosaveDelay": "slow", "inboxShowsPanel": false, "sidebar.visible": true}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let loaded = ScratchSettings.load(from: url)
        XCTAssertEqual(loaded.autosaveDelay, ScratchSettings().autosaveDelay)
        XCTAssertFalse(loaded.inboxShowsPanel, "the other saved values are kept")
        XCTAssertTrue(loaded.sidebarVisible)
        try #"{"defaultMonospace": 1.5, "inboxPosition": "prepend", "unknownKey": 3}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let other = ScratchSettings.load(from: url)
        XCTAssertTrue(other.defaultMonospace)
        XCTAssertEqual(other.inbox, .prepend)
    }

    func testSidebarIsHiddenByDefaultAndSettable() throws {
        XCTAssertFalse(ScratchSettings().sidebarVisible, "Scratch opens as a single pad")
        XCTAssertEqual(ScratchSettings().json["sidebar.visible"] as? Bool, false)
        let shown = try ScratchSettings().applying(["sidebar.visible": "true"])
        XCTAssertTrue(shown.sidebarVisible)
        XCTAssertThrowsError(try ScratchSettings().applying(["sidebar.visible": "sometimes"]))

        let url = dir.appendingPathComponent("preferences.json")
        try shown.save(to: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""sidebar.visible" : true"#))
        XCTAssertTrue(ScratchSettings.load(from: url).sidebarVisible)
        try #"{"defaultMonospace": false}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(ScratchSettings.load(from: url).sidebarVisible, "older files get the default")
    }
}
