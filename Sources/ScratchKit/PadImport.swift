import Foundation

/// What a dropped file becomes: a pad titled with the file name whose body is a `file:` link
/// followed by the file's contents when it is UTF-8 text under `maxInlineBytes`.
public enum PadImport {
    public static let maxInlineBytes = 1_000_000

    public struct Draft: Equatable, Sendable {
        public var title: String
        public var body: String
        public var inlined: Bool
    }

    public static func draft(forFile url: URL) -> Draft {
        let name = url.lastPathComponent
        let link = "[\(name)](\(url.absoluteString))"
        var body = link + "\n"
        var inlined = false
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory != true, let size = values?.fileSize, size < maxInlineBytes,
           let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
           !text.contains("\u{0}") {
            body += "\n" + text
            if !text.hasSuffix("\n") { body += "\n" }
            inlined = true
        }
        return Draft(title: name, body: body, inlined: inlined)
    }
}
