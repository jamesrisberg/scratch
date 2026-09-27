import Foundation

/// One scratch pad. The title comes from the first non-empty line of the body unless an
/// explicit `titleOverride` was given (e.g. `new title=...`, a dropped file's name, the inbox).
public struct Pad: Identifiable, Equatable, Hashable, Sendable {
    public static let inboxID = "inbox"
    public static let untitled = "Untitled"
    static let maxTitleLength = 80

    public var id: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var titleOverride: String?

    public init(id: String = Pad.newID(), body: String = "", createdAt: Date = Date(), updatedAt: Date? = nil,
                pinned: Bool = false, titleOverride: String? = nil) {
        self.id = id
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.pinned = pinned
        self.titleOverride = titleOverride.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isInbox: Bool { id == Pad.inboxID }

    public var title: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        return Pad.deriveTitle(from: body)
    }

    /// First non-empty line with markdown heading, list and quote markers removed, capped at 80 characters.
    public static func deriveTitle(from body: String) -> String {
        for raw in body.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#>".contains(first) { line.removeFirst() }
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { line.removeFirst(2) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.count > maxTitleLength { line = String(line.prefix(maxTitleLength - 1)) + "…" }
            return line
        }
        return untitled
    }

    // MARK: - Clearing

    /// Pads at least this long get an inline "Cleared — Undo" toast when cleared; shorter
    /// ones are cleared silently (Cmd-Z still undoes). Neither asks for confirmation.
    public static let clearToastThreshold = 2_000

    /// Whether clearing `body` warrants the undo toast.
    public static func clearNeedsToast(_ body: String) -> Bool { body.count >= clearToastThreshold }

    /// The pad with an empty body. An explicit title (`titleOverride`, e.g. the inbox's or one
    /// typed into the header) is kept; a title derived from the body goes back to "Untitled".
    public func cleared() -> Pad {
        var pad = self
        pad.body = ""
        return pad
    }

    /// Short, sortable, filename-safe: `20260926-140305-a1b2c3`.
    public static func newID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        return "\(f.string(from: date))-\(suffix)"
    }

    /// Ids are file names, so only allow a safe alphabet.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
