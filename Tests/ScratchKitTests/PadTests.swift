import Foundation
import XCTest
@testable import ScratchKit

final class PadTests: XCTestCase {
    func testTitleFromFirstNonEmptyLine() {
        XCTAssertEqual(Pad.deriveTitle(from: "\n\n  # Shopping list  \n- eggs"), "Shopping list")
        XCTAssertEqual(Pad.deriveTitle(from: "- first item\nsecond"), "first item")
        XCTAssertEqual(Pad.deriveTitle(from: "> quoted"), "quoted")
        XCTAssertEqual(Pad.deriveTitle(from: "   \n\t\n"), Pad.untitled)
        XCTAssertEqual(Pad.deriveTitle(from: ""), Pad.untitled)
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(Pad.deriveTitle(from: long).count, Pad.maxTitleLength)
        XCTAssertTrue(Pad.deriveTitle(from: long).hasSuffix("…"))
    }

    func testTitleOverrideWins() {
        XCTAssertEqual(Pad(body: "body line", titleOverride: "Explicit").title, "Explicit")
        XCTAssertEqual(Pad(body: "body line", titleOverride: "").title, "body line")
    }

    func testIDs() {
        let id = Pad.newID()
        XCTAssertTrue(Pad.isValidID(id))
        XCTAssertTrue(Pad.isValidID(Pad.inboxID))
        XCTAssertFalse(Pad.isValidID("../etc"))
        XCTAssertFalse(Pad.isValidID("a b"))
        XCTAssertFalse(Pad.isValidID(""))
        XCTAssertNotEqual(Pad.newID(), Pad.newID())
    }

    func testFrontMatterRoundTrip() {
        let created = Date(timeIntervalSince1970: 1_790_000_000.25)
        let pad = Pad(id: "abc", body: "# Hello\n---\nnot front matter\n", createdAt: created,
                      updatedAt: created.addingTimeInterval(60), pinned: true, titleOverride: "Greeting")
        let text = PadFile.encode(pad)
        XCTAssertTrue(text.hasPrefix("---\nid: abc\n"))
        XCTAssertEqual(PadFile.decode(text, fallbackID: "zzz"), pad)
    }

    func testDecodeEmptyBodyAndPlainMarkdown() {
        let pad = Pad(id: "e", body: "", createdAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(PadFile.decode(PadFile.encode(pad), fallbackID: "x"), pad)

        let date = Date(timeIntervalSince1970: 5_000)
        let plain = PadFile.decode("just text\nmore", fallbackID: "plain", fallbackDate: date)
        XCTAssertEqual(plain.id, "plain")
        XCTAssertEqual(plain.body, "just text\nmore")
        XCTAssertEqual(plain.createdAt, date)
        XCTAssertFalse(plain.pinned)
    }

    func testTextStats() {
        XCTAssertEqual(TextStats(""), TextStats(words: 0, characters: 0, lines: 0))
        XCTAssertEqual(TextStats("one two  three\nfour"), TextStats(words: 4, characters: 19, lines: 2))
        XCTAssertEqual(TextStats("é👍🏽"), TextStats(words: 1, characters: 2, lines: 1))
        XCTAssertEqual(TextStats("a").summary, "1 word · 1 char")
        XCTAssertEqual(TextStats("a b").summary, "2 words · 3 chars")
    }
}
