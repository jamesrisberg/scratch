import Foundation

/// A pad on disk: a markdown file with a small YAML-style front matter block.
///
/// ```
/// ---
/// id: 20260926-140305-a1b2c3
/// created: 2026-09-26T14:03:05Z
/// updated: 2026-09-26T14:10:00Z
/// pinned: false
/// title: Optional explicit title
/// ---
/// body…
/// ```
///
/// The body is written verbatim after the closing `---` line, so the file reads as ordinary
/// markdown in any editor. A file without front matter is accepted (the whole file is the
/// body, the id comes from the file name and the dates from the file's attributes).
public enum PadFile {
    public static let fileExtension = "md"

    public static func encode(_ pad: Pad) -> String {
        var lines = ["---", "id: \(pad.id)", "created: \(format(pad.createdAt))",
                     "updated: \(format(pad.updatedAt))", "pinned: \(pad.pinned)"]
        if let title = pad.titleOverride {
            lines.append("title: \(title.replacingOccurrences(of: "\n", with: " "))")
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + pad.body
    }

    public static func decode(_ text: String, fallbackID: String, fallbackDate: Date = Date()) -> Pad {
        var fields: [String: String] = [:]
        var body = text
        if text.hasPrefix("---\n") {
            let rest = text.dropFirst(4)
            if let close = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) {
                for line in rest[..<close.lowerBound].split(separator: "\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    fields[key] = value
                }
                body = String(rest[close.upperBound...])
            } else if rest.hasPrefix("---\n") || rest == "---" {
                body = String(rest.dropFirst(min(4, rest.count)))
            }
        }
        let id = fields["id"].flatMap { Pad.isValidID($0) ? $0 : nil } ?? fallbackID
        let created = fields["created"].flatMap(parse) ?? fallbackDate
        return Pad(id: id, body: body, createdAt: created,
                   updatedAt: fields["updated"].flatMap(parse) ?? created,
                   pinned: fields["pinned"] == "true", titleOverride: fields["title"])
    }

    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func parse(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
