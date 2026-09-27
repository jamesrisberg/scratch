import Foundation
import HUDKit
import XCTest

/// The shipped machud.json, settings.json and Info.plist are what MacHUD and Launch Services read
/// without launching Scratch; keep them valid.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Scratch/Resources")
    }

    func testManifestDecodes() throws {
        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appendingPathComponent(HUDManifest.fileName)))
        XCTAssertEqual(manifest.id, "xyz.machud.scratch")
        XCTAssertEqual(manifest.socket, "scratch")
        let panel = try XCTUnwrap(manifest.panel(id: "pad"))
        XCTAssertEqual(panel.kind, .hover, "MacHUD drops the pad down on hover and hides it on leave")
        XCTAssertEqual(panel.order, 1, "Scratch is the first hover button in the MacHUD dock")
        XCTAssertEqual(panel.defaultSize, HUDSize(width: 560, height: 400))
        XCTAssertEqual(panel.compactSize, HUDSize(width: 360, height: 44))
        for verb in ["show", "hide", "toggle", "frame", "mode", "append", "new", "open", "list", "get", "clear"] {
            XCTAssertTrue(panel.verbs.contains(verb), verb)
        }
        let schema = try XCTUnwrap(panel.settingsSchema)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent(schema))) as? [String: Any]
        let keys = (settings?["settings"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        // HUDKit's router serves `settings schema` from this file (HUDSettingsSchema.main), so it must decode.
        XCTAssertNoThrow(try HUDSettingsSchema.decode(Data(contentsOf: resources.appendingPathComponent(schema))))
        XCTAssertEqual(Set(keys ?? []), ["sidebar.visible", "defaultMonospace", "autosaveDelay", "inboxPosition", "inboxShowsPanel"])
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "xyz.machud.scratch")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Scratch")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}
