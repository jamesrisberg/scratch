import Foundation

public enum TransformError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)
    case invalidBase64
    case invalidPercentEncoding

    public var description: String {
        switch self {
        case .invalidJSON(let why): return "Not valid JSON: \(why)"
        case .invalidBase64: return "Not valid base64"
        case .invalidPercentEncoding: return "Not valid URL (percent) encoding"
        }
    }
}

/// Pure text transforms applied to a selection or a whole pad.
public enum Transform: String, CaseIterable, Identifiable, Sendable {
    case trim
    case trimLines
    case dedupeLines
    case sortLines
    case sortLinesDescending
    case reverseLines
    case stripFormatting
    case jsonPretty
    case jsonMinify
    case base64Encode
    case base64Decode
    case urlEncode
    case urlDecode
    case uppercase
    case lowercase
    case titleCase
    case sentenceCase
    case camelCase
    case snakeCase
    case kebabCase
    case markdownToPlain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .trim: "Trim Whitespace"
        case .trimLines: "Trim Each Line"
        case .dedupeLines: "Remove Duplicate Lines"
        case .sortLines: "Sort Lines"
        case .sortLinesDescending: "Sort Lines Descending"
        case .reverseLines: "Reverse Lines"
        case .stripFormatting: "Strip Formatting"
        case .jsonPretty: "JSON: Pretty Print"
        case .jsonMinify: "JSON: Minify"
        case .base64Encode: "Base64 Encode"
        case .base64Decode: "Base64 Decode"
        case .urlEncode: "URL Encode"
        case .urlDecode: "URL Decode"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .titleCase: "Title Case"
        case .sentenceCase: "Sentence case"
        case .camelCase: "camelCase"
        case .snakeCase: "snake_case"
        case .kebabCase: "kebab-case"
        case .markdownToPlain: "Markdown to Plain Text"
        }
    }

    /// Menu grouping (a separator goes between groups).
    public var group: Int {
        switch self {
        case .trim, .trimLines, .dedupeLines, .sortLines, .sortLinesDescending, .reverseLines: 0
        case .stripFormatting, .markdownToPlain: 1
        case .jsonPretty, .jsonMinify, .base64Encode, .base64Decode, .urlEncode, .urlDecode: 2
        case .uppercase, .lowercase, .titleCase, .sentenceCase, .camelCase, .snakeCase, .kebabCase: 3
        }
    }

    public func apply(_ text: String) throws -> String {
        switch self {
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .trimLines: return Self.mapLines(text) { $0.trimmingCharacters(in: .whitespaces) }
        case .dedupeLines:
            var seen = Set<Substring>()
            return Self.withLines(text) { $0.filter { seen.insert($0).inserted } }
        case .sortLines:
            return Self.withLines(text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        case .sortLinesDescending:
            return Self.withLines(text) { $0.sorted { $0.localizedStandardCompare($1) == .orderedDescending } }
        case .reverseLines: return Self.withLines(text) { $0.reversed() }
        case .stripFormatting: return Self.stripFormatting(text)
        case .jsonPretty: return try Self.json(text, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        case .jsonMinify: return try Self.json(text, options: [.sortedKeys, .withoutEscapingSlashes])
        case .base64Encode: return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            var compact = text.filter { !$0.isWhitespace }
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if compact.count % 4 != 0 { compact += String(repeating: "=", count: 4 - compact.count % 4) }
            guard let data = Data(base64Encoded: compact), let s = String(data: data, encoding: .utf8) else {
                throw TransformError.invalidBase64
            }
            return s
        case .urlEncode:
            return text.addingPercentEncoding(withAllowedCharacters: Self.urlUnreserved) ?? text
        case .urlDecode:
            guard let s = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                throw TransformError.invalidPercentEncoding
            }
            return s
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return Self.mapLines(text) { Self.titleCase(String($0)) }
        case .sentenceCase: return Self.sentenceCase(text)
        case .camelCase: return Self.mapLines(text) { Self.joinWords(String($0), camel: true, separator: "") }
        case .snakeCase: return Self.mapLines(text) { Self.joinWords(String($0), camel: false, separator: "_") }
        case .kebabCase: return Self.mapLines(text) { Self.joinWords(String($0), camel: false, separator: "-") }
        case .markdownToPlain: return Markdown.plainText(text)
        }
    }

    // MARK: - Lines

    /// Applies `body` to the lines, keeping a trailing newline if there was one.
    static func withLines(_ text: String, _ body: ([Substring]) -> [Substring]) -> String {
        let trailing = text.hasSuffix("\n")
        let content = trailing ? String(text.dropLast()) : text
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        return body(lines).joined(separator: "\n") + (trailing ? "\n" : "")
    }

    static func mapLines(_ text: String, _ transform: (Substring) -> String) -> String {
        withLines(text) { $0.map { Substring(transform($0)) } }
    }

    // MARK: - Formatting

    static let urlUnreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Plain-text cleanup for pasted text: smart quotes and dashes become ASCII, non-breaking
    /// and other exotic spaces become spaces, zero-width and control characters (except tab
    /// and newline) are removed, CRLF/CR become LF, and trailing spaces on each line go.
    static func stripFormatting(_ text: String) -> String {
        let replacements: [Character: String] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{2032}": "'",
            "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{2033}": "\"",
            "\u{2013}": "-", "\u{2014}": "--", "\u{2212}": "-", "\u{2026}": "...",
            "\u{2022}": "-", "\u{00A0}": " ", "\u{2007}": " ", "\u{202F}": " ", "\u{2009}": " ", "\u{200A}": " ",
            "\u{2002}": " ", "\u{2003}": " ",
        ]
        var out = ""
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for ch in normalized {
            if let r = replacements[ch] { out += r; continue }
            if ch == "\n" || ch == "\t" { out.append(ch); continue }
            let scalars = ch.unicodeScalars
            if scalars.allSatisfy({ $0.properties.generalCategory == .format || $0.properties.generalCategory == .control }) { continue }
            out.append(ch)
        }
        return mapLines(out) { line in
            var s = Substring(line)
            while let last = s.last, last == " " || last == "\t" { s.removeLast() }
            return String(s)
        }
    }

    static func json(_ text: String, options: JSONSerialization.WritingOptions) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        } catch {
            let info = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw TransformError.invalidJSON(info ?? "parse error")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed))
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Case

    static let smallWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of",
                                          "on", "or", "so", "the", "to", "up", "via", "vs", "with", "yet"]

    /// Capitalises each word except short joining words (unless first or last); mixed-case
    /// words with an inner capital (iPhone, macOS) are left alone, all-caps words are recased.
    static func titleCase(_ line: String) -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        let lastIndex = words.lastIndex { !$0.isEmpty } ?? 0
        let firstIndex = words.firstIndex { !$0.isEmpty } ?? 0
        return words.enumerated().map { i, word -> String in
            guard let first = word.first else { return "" }
            if word.dropFirst().contains(where: \.isUppercase), word.contains(where: \.isLowercase) { return String(word) }
            let lower = word.lowercased()
            if i != firstIndex, i != lastIndex, smallWords.contains(lower) { return lower }
            return String(first).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    /// Lowercases everything, then capitalises the first letter of each sentence.
    static func sentenceCase(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext, ch.isLetter {
                out += String(ch).uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
            }
            if ".!?\n".contains(ch) { capitalizeNext = true }
        }
        return out
    }

    /// Splits on non-alphanumerics and lower-to-upper boundaries (`fooBar`, `HTTPServer`).
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(line)
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if let prev = current.last, ch.isUppercase {
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static func joinWords(_ line: String, camel: Bool, separator: String) -> String {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let parts = words(line).map { $0.lowercased() }
        guard !parts.isEmpty else { return line }
        if camel {
            return leading + parts[0] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        return leading + parts.joined(separator: separator)
    }
}
