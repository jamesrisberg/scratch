import Foundation

/// Markdown to plain text: keeps the words, drops the markup.
///
/// - Headings, blockquote markers and horizontal rules are removed.
/// - `**bold**`, `__bold__`, `*em*`, `_em_`, `~~strike~~` and `` `code` `` keep their text.
/// - Links `[text](url)` become `text`; images `![alt](url)` become `alt`; `<https://x>` becomes the URL.
/// - Fenced code blocks keep their content without the fences.
/// - List markers `*`/`+` become `-`; numbered lists and indentation are kept.
/// - Inline HTML tags are removed.
public enum Markdown {
    public static func plainText(_ markdown: String) -> String {
        var out: [String] = []
        var inFence = false
        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { out.append(line); continue }
            if isRule(trimmed) { continue }
            out.append(inline(block(line)))
        }
        return out.joined(separator: "\n")
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Line-level markers: headings, quotes, bullets.
    static func block(_ line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var rest = Substring(line.dropFirst(indent.count))
        while rest.hasPrefix(">") {
            rest = rest.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        }
        if rest.hasPrefix("#") {
            let hashes = rest.prefix { $0 == "#" }
            let after = rest.dropFirst(hashes.count)
            if hashes.count <= 6, after.isEmpty || after.hasPrefix(" ") {
                var text = after.trimmingCharacters(in: .whitespaces)
                // Closing hashes: `## Title ##`
                while text.hasSuffix("#") { text.removeLast() }
                return indent + text.trimmingCharacters(in: .whitespaces)
            }
        }
        for marker in ["* ", "+ "] where rest.hasPrefix(marker) {
            rest = "- " + rest.dropFirst(2)
        }
        // Task list boxes.
        for box in ["- [ ] ", "- [x] ", "- [X] "] where rest.hasPrefix(box) {
            rest = "- " + rest.dropFirst(box.count)
        }
        return indent + rest
    }

    static func inline(_ text: String) -> String {
        // Backslash escapes are hidden as private-use characters first, so `\*` never
        // takes part in emphasis, then restored as the bare character.
        var s = ""
        var escaping = false
        for scalar in text.unicodeScalars {
            if escaping {
                escaping = false
                if scalar.isASCII, escapable.contains(Character(scalar)), let hidden = Unicode.Scalar(0xE000 + scalar.value) {
                    s.unicodeScalars.append(hidden)
                } else {
                    s.unicodeScalars.append("\\")
                    s.unicodeScalars.append(scalar)
                }
            } else if scalar == "\\" {
                escaping = true
            } else {
                s.unicodeScalars.append(scalar)
            }
        }
        if escaping { s += "\\" }
        // Images before links, both before emphasis (URLs contain underscores).
        s = replace(s, #"!\[([^\]]*)\]\([^)]*\)"#, "$1")
        s = replace(s, #"\[([^\]]+)\]\([^)]*\)"#, "$1")
        s = replace(s, #"\[([^\]]+)\]\[[^\]]*\]"#, "$1")
        s = replace(s, #"<(https?://[^>]+)>"#, "$1")
        s = replace(s, #"</?[A-Za-z][^>]*>"#, "")
        s = replace(s, #"`([^`]+)`"#, "$1")
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2")
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#, "$1")
        s = replace(s, #"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])"#, "$1")
        s = replace(s, #"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])"#, "$1")
        return String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            (0xE000..<0xE080).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xE000)! : scalar
        }))
    }

    static let escapable = Set("\\`*_{}[]()#+-.!>~|")

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
