import Foundation
import XCTest
@testable import ScratchKit

/// Clear: empty the pad, keep it, and be able to put it back.
final class ClearTests: TempDirTestCase {
    private func makeStore(_ clock: Clock = Clock()) throws -> PadStore {
        let store = PadStore(directory: dir.appendingPathComponent("pads"), autosaveDelay: 0.05, now: clock.now)
        try store.load()
        return store
    }

    func testClearEmptiesTheBodyAndKeepsThePad() throws {
        let clock = Clock()
        let store = try makeStore(clock)
        let pad = store.create(body: "Groceries\n- eggs")
        clock.advance(5)
        let before = try XCTUnwrap(store.clear(pad.id))
        XCTAssertEqual(before.body, "Groceries\n- eggs", "clear returns the pad as it was")
        XCTAssertEqual(store.count, 1)
        let cleared = try XCTUnwrap(store.pad(pad.id))
        XCTAssertEqual(cleared.body, "")
        XCTAssertEqual(cleared.createdAt, pad.createdAt)
        XCTAssertEqual(cleared.updatedAt, clock.date)
        // Written at once, not on the autosave timer.
        XCTAssertFalse(store.hasPendingSaves)
        let reloaded = try makeStore()
        XCTAssertEqual(reloaded.pad(pad.id)?.body, "")
    }

    func testClearIsUndoneByRestore() throws {
        let store = try makeStore()
        let pad = store.create(body: "keep me")
        store.update(pad.id, body: "keep me, edited")
        let before = try XCTUnwrap(store.clear(pad.id))
        store.restore(before)
        XCTAssertEqual(store.pad(pad.id), before)
        XCTAssertEqual(try makeStore().pad(pad.id)?.body, "keep me, edited", "the restore is on disk too")
    }

    func testClearingAnEmptyOrMissingPadIsANoOp() throws {
        let store = try makeStore()
        let pad = store.create()
        XCTAssertNil(store.clear(pad.id))
        XCTAssertNil(store.clear("nope"))
    }

    func testDerivedTitleResetsToUntitled() throws {
        let store = try makeStore()
        let pad = store.create(body: "# Meeting notes\nstuff")
        XCTAssertEqual(pad.title, "Meeting notes")
        store.clear(pad.id)
        XCTAssertEqual(store.pad(pad.id)?.title, Pad.untitled)
    }

    func testExplicitTitleSurvivesClear() throws {
        let store = try makeStore()
        let named = store.create(body: "lots of text", title: "Build log")
        store.clear(named.id)
        XCTAssertEqual(store.pad(named.id)?.title, "Build log")
        let inbox = store.appendToInbox("pasted")
        store.clear(inbox.id)
        XCTAssertEqual(store.pad(Pad.inboxID)?.title, "Inbox")
    }

    func testToastThreshold() {
        XCTAssertFalse(Pad.clearNeedsToast(String(repeating: "x", count: 1_999)))
        XCTAssertTrue(Pad.clearNeedsToast(String(repeating: "x", count: 2_000)))
    }
}
