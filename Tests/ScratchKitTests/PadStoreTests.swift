import Foundation
import XCTest
@testable import ScratchKit

final class PadStoreTests: TempDirTestCase {
    private func makeStore(_ clock: Clock = Clock(), delay: TimeInterval = 0.05) -> PadStore {
        let store = PadStore(directory: dir.appendingPathComponent("pads"), autosaveDelay: delay, now: clock.now)
        store.timeZone = TimeZone(identifier: "UTC")!
        return store
    }

    func testRoundTripThroughDisk() throws {
        let clock = Clock()
        let store = makeStore(clock)
        try store.load()
        let a = store.create(body: "Alpha\nfirst pad")
        clock.advance(10)
        let b = store.create(body: "ignored first line", title: "Beta")
        store.setPinned(a.id, true)
        clock.advance(10)
        store.update(b.id, body: "Beta body edited")
        store.flush()

        let reloaded = makeStore()
        try reloaded.load()
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.pad(a.id), store.pad(a.id))
        XCTAssertEqual(reloaded.pad(b.id), store.pad(b.id))
        XCTAssertEqual(reloaded.pad(b.id)?.title, "Beta")
        XCTAssertEqual(reloaded.pad(a.id)?.pinned, true)
        // Files are plain markdown named by id.
        let text = try String(contentsOf: store.fileURL(for: a.id), encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("\n---\nAlpha\nfirst pad"))
    }

    func testForeignMarkdownFileIsLoaded() throws {
        let pads = dir.appendingPathComponent("pads")
        try FileManager.default.createDirectory(at: pads, withIntermediateDirectories: true)
        try "# Notes from elsewhere\nhello".write(to: pads.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: pads.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let store = makeStore()
        try store.load()
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.pad("notes")?.title, "Notes from elsewhere")
    }

    func testAutosaveIsDebounced() throws {
        let store = makeStore(delay: 0.2)
        try store.load()
        let pad = store.create(body: "v0")
        let url = store.fileURL(for: pad.id)
        store.update(pad.id, body: "v1")
        store.update(pad.id, body: "v2")
        XCTAssertTrue(store.hasPendingSaves)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("v0"), "not written before the delay")
        let saved = expectation(description: "autosave")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        XCTAssertFalse(store.hasPendingSaves)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("v2"))
    }

    func testUnchangedBodyIsNoOp() throws {
        let clock = Clock()
        let store = makeStore(clock)
        let pad = store.create(body: "same")
        clock.advance(100)
        store.update(pad.id, body: "same")
        XCTAssertEqual(store.pad(pad.id)?.updatedAt, pad.updatedAt)
        XCTAssertFalse(store.hasPendingSaves)
    }

    func testDeleteAndRestore() throws {
        let store = makeStore()
        try store.load()
        let pad = store.create(body: "doomed")
        store.update(pad.id, body: "doomed, edited")
        let removed = try XCTUnwrap(store.delete(pad.id))
        XCTAssertFalse(store.hasPendingSaves, "a pending save must not resurrect the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: pad.id).path))
        XCTAssertNil(store.pad(pad.id))
        store.restore(removed)
        XCTAssertEqual(store.pad(pad.id)?.body, "doomed, edited")
        let reloaded = makeStore()
        try reloaded.load()
        XCTAssertEqual(reloaded.pad(pad.id)?.body, "doomed, edited")
        XCTAssertNil(store.delete("nope"))
    }

    func testOrderPinnedThenRecent() throws {
        let clock = Clock()
        let store = makeStore(clock)
        let old = store.create(body: "old")
        clock.advance(1)
        let mid = store.create(body: "mid")
        clock.advance(1)
        let new = store.create(body: "new")
        store.setPinned(old.id, true)
        XCTAssertEqual(store.sorted.map(\.id), [old.id, new.id, mid.id])
        clock.advance(1)
        store.update(mid.id, body: "mid edited")
        XCTAssertEqual(store.sorted.map(\.id), [old.id, mid.id, new.id])
    }

    func testChangeCallback() throws {
        let store = makeStore()
        var calls = 0
        store.onChange = { calls += 1 }
        let pad = store.create(body: "x")
        store.update(pad.id, body: "y")
        store.setPinned(pad.id, true)
        store.delete(pad.id)
        XCTAssertEqual(calls, 4)
    }

    func testCreateWithRequestedIDAvoidsCollision() {
        let store = makeStore()
        let a = store.create(body: "a", id: "fixed")
        let b = store.create(body: "b", id: "fixed")
        XCTAssertEqual(a.id, "fixed")
        XCTAssertNotEqual(b.id, "fixed")
        XCTAssertNotEqual(store.create(body: "c", id: "../bad").id, "../bad")
    }

    // MARK: Inbox

    func testInboxAppendsWithSeparators() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000)) // 2026-09-21 14:13:20 UTC
        let store = makeStore(clock)
        try store.load()
        store.appendToInbox("first paste\n")
        clock.advance(65)
        let inbox = store.appendToInbox("second")
        XCTAssertEqual(inbox.id, Pad.inboxID)
        XCTAssertEqual(inbox.title, "Inbox")
        XCTAssertTrue(inbox.pinned)
        XCTAssertEqual(inbox.body, """
        --- 2026-09-21 14:13:20 ---
        first paste

        --- 2026-09-21 14:14:25 ---
        second

        """)
        XCTAssertFalse(store.hasPendingSaves, "inbox appends are written at once")
        let reloaded = makeStore()
        try reloaded.load()
        XCTAssertEqual(reloaded.pad(Pad.inboxID)?.body, inbox.body)
    }

    func testInboxPrepend() {
        let clock = Clock(Date(timeIntervalSince1970: 1_790_000_000))
        let store = makeStore(clock)
        store.inboxPosition = .prepend
        store.appendToInbox("older")
        clock.advance(1)
        let inbox = store.appendToInbox("newer")
        XCTAssertTrue(inbox.body.hasPrefix("--- 2026-09-21 14:13:21 ---\nnewer\n\n--- 2026-09-21 14:13:20 ---\nolder"))
    }

    func testAppendToPad() {
        let store = makeStore()
        let pad = store.create(body: "line one")
        XCTAssertEqual(store.append("line two", to: pad.id)?.body, "line one\nline two")
        XCTAssertEqual(store.append("line three\n", to: pad.id)?.body, "line one\nline two\nline three\n")
        XCTAssertEqual(store.append("four", to: pad.id)?.body, "line one\nline two\nline three\nfour")
        XCTAssertNil(store.append("x", to: "missing"))
    }

    // MARK: Search

    func testSearch() {
        let clock = Clock()
        let store = makeStore(clock)
        let recipe = store.create(body: "Pancake recipe\nflour, eggs, milk")
        clock.advance(1)
        let log = store.create(body: "Server log\nerror: eggs not found")
        clock.advance(1)
        let other = store.create(body: "Café notes\nnothing here")
        XCTAssertEqual(Set(store.search("eggs").map(\.id)), [recipe.id, log.id])
        XCTAssertEqual(store.search("EGGS flour").map(\.id), [recipe.id], "every term must match")
        XCTAssertEqual(store.search("cafe").map(\.id), [other.id], "diacritic insensitive")
        XCTAssertEqual(store.search("   ").count, 3)
        XCTAssertTrue(store.search("zebra").isEmpty)
        // Title matches rank above body-only matches even when older.
        clock.advance(1)
        store.update(log.id, body: "Server log\npancake machine is broken")
        XCTAssertEqual(store.search("pancake").map(\.id), [recipe.id, log.id])
    }

    func testSnippet() {
        XCTAssertEqual(PadStore.snippet("title\nthe needle line\nafter", query: "NEEDLE"), "the needle line")
        XCTAssertNil(PadStore.snippet("nothing", query: "needle"))
        let long = String(repeating: "a ", count: 60) + "needle" + String(repeating: " b", count: 60)
        let s = PadStore.snippet(long, query: "needle", width: 30)!
        XCTAssertTrue(s.contains("needle"))
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
    }
}
