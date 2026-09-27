import AppKit
import HUDKit
@testable import Scratch
import ScratchKit
import XCTest

/// MacHUD's dock transitions: `panel show from= anchor= reason=` and `panel hide to=`.
@MainActor
final class PanelTransitionTests: XCTestCase {
    private var dir: URL!
    private var model: AppModel!
    private var controller: PanelController!
    private var control: ControlHost!

    override func setUp() async throws {
        _ = NSApplication.shared
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScratchTransitionTests-\(UUID().uuidString)")
        let store = PadStore(directory: dir.appendingPathComponent("pads"), autosaveDelay: 0.05)
        model = AppModel(store: store, settingsURL: dir.appendingPathComponent("preferences.json"))
        controller = PanelController(model: model)
        control = ControlHost(model: model, panel: controller)
    }

    override func tearDown() async throws {
        controller.panel.orderOut(nil)
        control = nil
        controller = nil
        model = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func send(_ verb: String, _ args: [String: String]) -> [String: Any] {
        var response: [String: Any] = [:]
        control.router.handle(verb, args: args) { response = $0 }
        return response
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A dock button near the bottom middle of the main screen.
    private var anchor: CGRect {
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: visible.midX - 20, y: visible.minY, width: 40, height: 40)
    }

    private func hoverShow() -> [String: Any] {
        send("panel", ["id": "pad", "action": "show", "from": "bottom",
                       "anchor": HUDPanelTransition.formatAnchor(anchor), "reason": "hover"])
    }

    // MARK: Plans

    func testShowPlanByReason() {
        typealias T = HUDPanelTransition
        let hover = PanelController.showPlan(for: T(from: .bottom, anchor: anchor, reason: .hover))
        XCTAssertEqual(hover, .init(motion: .fade, duration: 0.08, takeFocus: false), "hover: quick fade, never key")
        XCTAssertEqual(PanelController.showPlan(for: T(from: .left, reason: .click)),
                       .init(motion: .slide(from: .left), duration: HUDAnimation.revealDuration, takeFocus: true))
        XCTAssertEqual(PanelController.showPlan(for: T(from: .top, reason: .summon)).takeFocus, true)
        XCTAssertEqual(PanelController.showPlan(for: T(from: .top)),
                       .init(motion: .slide(from: .top), duration: HUDAnimation.revealDuration, takeFocus: false))
        XCTAssertEqual(PanelController.showPlan(for: T()),
                       .init(motion: .fade, duration: HUDAnimation.revealDuration, takeFocus: false))
        XCTAssertEqual(PanelController.showPlan(for: T(reason: .click)).takeFocus, true)
    }

    func testHidePlanByOptions() {
        typealias T = HUDPanelTransition
        XCTAssertEqual(PanelController.hidePlan(for: T(to: .bottom)), .init(motion: .slide(toward: .bottom), duration: 0.1))
        XCTAssertEqual(PanelController.hidePlan(for: T(to: .right, reason: .hover)), .init(motion: .slide(toward: .right), duration: 0.1))
        XCTAssertEqual(PanelController.hidePlan(for: T(reason: .hover)), .init(motion: .fade, duration: 0.1))
        XCTAssertEqual(PanelController.hidePlan(for: T()), .init(motion: .fade, duration: HUDAnimation.concealDuration))
    }

    // MARK: Router → host

    func testHoverShowSitsNextToTheAnchorWithoutTakingFocus() throws {
        let size = controller.panel.frame.size
        let response = hoverShow()
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["visible"] as? Bool, true)
        settle()
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let expected = HUDDockLayout.panelFrame(size: size, anchor: anchor, from: .bottom, in: visible)
        XCTAssertEqual(controller.panel.frame, expected)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        XCTAssertFalse(controller.panel.isKeyWindow, "a hover show never takes focus")
        XCTAssertFalse(NSApp.isActive)
    }

    func testPanelFrameFromMacHUDWinsOverTheAnchor() {
        let assigned = CGRect(x: 200, y: 180, width: 500, height: 320)
        XCTAssertEqual(send("panel", ["id": "pad", "action": "frame", "x": "200", "y": "180", "w": "500", "h": "320"])["ok"] as? Bool, true)
        _ = hoverShow()
        settle()
        XCTAssertEqual(controller.panel.frame, assigned)
        XCTAssertEqual(controller.assignedFrame, assigned)
    }

    func testMalformedOptionsAreRejected() {
        let bad = send("panel", ["id": "pad", "action": "show", "from": "sideways"])
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertFalse(controller.isShown)
        XCTAssertEqual(send("panel", ["id": "pad", "action": "hide", "anchor": "1,2,3"])["ok"] as? Bool, false)
    }

    func testHideToEdgeOrdersOutAndRestoresTheFrame() {
        _ = hoverShow()
        settle()
        let rest = controller.panel.frame
        let response = send("panel", ["id": "pad", "action": "hide", "to": "bottom", "reason": "hover"])
        XCTAssertEqual(response["visible"] as? Bool, false)
        settle()
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.frame, rest, "the next show starts from the rest frame")
        XCTAssertEqual(controller.panel.alphaValue, 1)
    }

    /// Moving between hover buttons: MacHUD hides and immediately shows again. The show wins.
    func testShowDuringHideLeavesThePanelVisible() {
        _ = hoverShow()
        settle()
        let rest = controller.panel.frame
        _ = send("panel", ["id": "pad", "action": "hide", "to": "bottom", "reason": "hover"])
        let shown = hoverShow()
        XCTAssertEqual(shown["visible"] as? Bool, true)
        settle()
        XCTAssertTrue(controller.panel.isVisible, "the stale hide completion must not order the panel out")
        XCTAssertTrue(controller.isShown)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        XCTAssertEqual(controller.panel.frame, rest)
    }

    /// The same race with the slide-in path (a click from the dock).
    func testSlideShowDuringHideLeavesThePanelVisible() {
        _ = send("panel", ["id": "pad", "action": "show", "from": "bottom", "anchor": HUDPanelTransition.formatAnchor(anchor)])
        settle()
        let rest = controller.panel.frame
        _ = send("panel", ["id": "pad", "action": "hide", "to": "bottom"])
        _ = send("panel", ["id": "pad", "action": "show", "from": "bottom", "anchor": HUDPanelTransition.formatAnchor(anchor)])
        settle()
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1)
        XCTAssertEqual(controller.panel.frame, rest)
    }

    func testToggleWithOptionsHidesTowardTheDockEdge() {
        _ = send("panel", ["id": "pad", "action": "toggle", "from": "bottom", "anchor": HUDPanelTransition.formatAnchor(anchor), "reason": "hover"])
        XCTAssertTrue(controller.isShown)
        _ = send("panel", ["id": "pad", "action": "toggle", "from": "bottom", "reason": "hover"])
        XCTAssertFalse(controller.isShown)
        settle()
        XCTAssertFalse(controller.panel.isVisible)
    }
}
