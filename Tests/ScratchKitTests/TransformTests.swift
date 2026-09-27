import Foundation
import XCTest
@testable import ScratchKit

final class TransformTests: XCTestCase {
    private func t(_ transform: Transform, _ input: String) throws -> String { try transform.apply(input) }

    func testEveryTransformHasATestAndTitle() {
        // Guards against adding a transform without covering it below.
        let covered: Set<Transform> = [.trim, .trimLines, .dedupeLines, .sortLines, .sortLinesDescending, .reverseLines,
                                       .stripFormatting, .jsonPretty, .jsonMinify, .base64Encode, .base64Decode,
                                       .urlEncode, .urlDecode, .uppercase, .lowercase, .titleCase, .sentenceCase,
                                       .camelCase, .snakeCase, .kebabCase, .markdownToPlain]
        XCTAssertEqual(Set(Transform.allCases), covered)
        for transform in Transform.allCases { XCTAssertFalse(transform.title.isEmpty) }
    }

    func testTrim() throws {
        XCTAssertEqual(try t(.trim, "  \n hello world \n\t"), "hello world")
        XCTAssertEqual(try t(.trimLines, "  a  \n\tb\t\n"), "a\nb\n")
    }

    func testDedupeLines() throws {
        XCTAssertEqual(try t(.dedupeLines, "b\na\nb\nc\na\n"), "b\na\nc\n")
        XCTAssertEqual(try t(.dedupeLines, "x\nX\nx"), "x\nX", "case sensitive, keeps first occurrence")
    }

    func testSortAndReverseLines() throws {
        XCTAssertEqual(try t(.sortLines, "item10\nItem2\nitem1\n"), "item1\nItem2\nitem10\n", "natural, case-insensitive")
        XCTAssertEqual(try t(.sortLinesDescending, "b\nc\na"), "c\nb\na")
        XCTAssertEqual(try t(.reverseLines, "1\n2\n3\n"), "3\n2\n1\n")
    }

    func testStripFormatting() throws {
        let input = "\u{201C}Smart\u{201D} \u{2018}quotes\u{2019} \u{2014} dash\u{00A0}nbsp\u{200B}zw   \r\nnext\u{2026}"
        XCTAssertEqual(try t(.stripFormatting, input), "\"Smart\" 'quotes' -- dash nbspzw\nnext...")
        XCTAssertEqual(try t(.stripFormatting, "tab\tkept\n"), "tab\tkept\n")
    }

    func testJSON() throws {
        XCTAssertEqual(try t(.jsonPretty, #"{"b":[1,2],"a":"x/y"}"#), """
        {
          "a" : "x/y",
          "b" : [
            1,
            2
          ]
        }
        """)
        XCTAssertEqual(try t(.jsonMinify, "{\n  \"b\" : 1,\n  \"a\" : [ true, null ]\n}\n"), #"{"a":[true,null],"b":1}"#)
        XCTAssertEqual(try t(.jsonMinify, " 42 "), "42")
        XCTAssertThrowsError(try t(.jsonPretty, "{not json")) { error in
            guard case TransformError.invalidJSON = error else { return XCTFail("\(error)") }
        }
    }

    func testBase64() throws {
        XCTAssertEqual(try t(.base64Encode, "hello, wörld"), "aGVsbG8sIHfDtnJsZA==")
        XCTAssertEqual(try t(.base64Decode, "aGVsbG8sIHfDtnJsZA=="), "hello, wörld")
        XCTAssertEqual(try t(.base64Decode, "aGVs\nbG8"), "hello", "whitespace and missing padding tolerated")
        XCTAssertEqual(try t(.base64Decode, "Pz8_"), "???", "URL-safe alphabet")
        XCTAssertThrowsError(try t(.base64Decode, "!!!!")) { XCTAssertEqual($0 as? TransformError, .invalidBase64) }
    }

    func testURLEncoding() throws {
        XCTAssertEqual(try t(.urlEncode, "a b&c=d/é~"), "a%20b%26c%3Dd%2F%C3%A9~")
        XCTAssertEqual(try t(.urlDecode, "a%20b%26c%3Dd%2F%C3%A9~"), "a b&c=d/é~")
        XCTAssertEqual(try t(.urlDecode, "q=hello+world"), "q=hello world")
        XCTAssertThrowsError(try t(.urlDecode, "%E0%A4%A")) { XCTAssertEqual($0 as? TransformError, .invalidPercentEncoding) }
    }

    func testCases() throws {
        XCTAssertEqual(try t(.uppercase, "Hello ß"), "HELLO SS")
        XCTAssertEqual(try t(.lowercase, "HeLLo"), "hello")
        XCTAssertEqual(try t(.titleCase, "the lord of the rings on iPhone"), "The Lord of the Rings on iPhone")
        XCTAssertEqual(try t(.titleCase, "WHAT is up\ngone with the wind"), "What Is Up\nGone with the Wind")
        XCTAssertEqual(try t(.sentenceCase, "HELLO THERE. how are you? fine!\nnew line"), "Hello there. How are you? Fine!\nNew line")
        XCTAssertEqual(try t(.camelCase, "Hello world-foo_bar"), "helloWorldFooBar")
        XCTAssertEqual(try t(.camelCase, "parseHTTPServer"), "parseHttpServer")
        XCTAssertEqual(try t(.snakeCase, "parseHTTPServer v2"), "parse_http_server_v2")
        XCTAssertEqual(try t(.kebabCase, "Some Title\n  fooBar"), "some-title\n  foo-bar")
        XCTAssertEqual(try t(.snakeCase, "---"), "---", "nothing to join leaves the line alone")
    }

    func testMarkdownToPlain() throws {
        let md = """
        # Title ##
        > quoted **bold** and _em_ and *star*
        * item with [a link](https://example.com/a_b) and ![img](x.png)
        - [x] done task
        1. `code` ~~gone~~ <b>html</b> <https://x.dev>
        ---
        ```swift
        let x = **not bold**
        ```
        snake_case_word and 2*3*4 stay \\*escaped\\*
        """
        XCTAssertEqual(try t(.markdownToPlain, md), """
        Title
        quoted bold and em and star
        - item with a link and img
        - done task
        1. code gone html https://x.dev
        let x = **not bold**
        snake_case_word and 2*3*4 stay *escaped*
        """)
    }
}
