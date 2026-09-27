import Foundation

/// Where pasted or piped text lands in the inbox pad.
public enum InboxPosition: String, CaseIterable, Sendable {
    /// Newest entry at the bottom (a log).
    case append
    /// Newest entry at the top.
    case prepend
}

/// All pads, persisted as one markdown file per pad (see `PadFile`) in `directory`.
///
/// Not thread-safe: use it from one thread (the app uses the main thread). Body edits go
/// through `update(_:body:)`, which marks the pad dirty and writes it after `autosaveDelay`
/// seconds without further edits; structural changes (create, pin, delete, restore) write at
/// once. `flush()` writes everything pending (call it on quit).
public final class PadStore {
    /// `~/Library/Application Support/Scratch`.
    public static var defaultBaseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Scratch", isDirectory: true)
    }

    /// `<base>/pads`.
    public static func padsDirectory(base: URL = defaultBaseDirectory) -> URL {
        base.appendingPathComponent("pads", isDirectory: true)
    }

    public let directory: URL
    public var autosaveDelay: TimeInterval
    public var inboxPosition: InboxPosition = .append
    /// Time zone for inbox separators (injectable for tests).
    public var timeZone: TimeZone = .current
    /// Called after any change to the set of pads or their contents (not for saves).
    public var onChange: (() -> Void)?
    /// The last write or read error, for display.
    public private(set) var lastError: Error?

    public private(set) var pads: [String: Pad] = [:]
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private let now: () -> Date
    private let fm = FileManager.default

    public init(directory: URL = PadStore.padsDirectory(), autosaveDelay: TimeInterval = 0.75,
                now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.autosaveDelay = autosaveDelay
        self.now = now
    }

    deinit {
        for item in pendingSaves.values { item.cancel() }
    }

    // MARK: - Loading

    /// Reads every `*.md` file in the directory (creating the directory if needed).
    public func load() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var loaded: [String: Pad] = [:]
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                              options: [.skipsHiddenFiles])
        for url in urls where url.pathExtension == PadFile.fileExtension {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now()
            let stem = url.deletingPathExtension().lastPathComponent
            var pad = PadFile.decode(text, fallbackID: Pad.isValidID(stem) ? stem : Pad.newID(date: modified),
                                     fallbackDate: modified)
            // The file name is authoritative so edits land back in the same file.
            if Pad.isValidID(stem) { pad.id = stem }
            loaded[pad.id] = pad
        }
        pads = loaded
        onChange?()
    }

    // MARK: - Queries

    public var count: Int { pads.count }

    public func pad(_ id: String) -> Pad? { pads[id] }

    /// Pinned first, then most recently updated.
    public var sorted: [Pad] { Self.order(Array(pads.values)) }

    static func order(_ list: [Pad]) -> [Pad] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id > b.id
        }
    }

    /// Full-text search. Every whitespace-separated term must appear (case and diacritic
    /// insensitive) in the title or body. Pads whose title matches every term come first;
    /// otherwise the usual order holds. An empty query returns `sorted`.
    public func search(_ query: String) -> [Pad] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return sorted }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func containsAll(_ text: String) -> Bool { terms.allSatisfy { text.range(of: $0, options: options) != nil } }
        let hits = sorted.filter { containsAll($0.title + "\n" + $0.body) }
        return hits.filter { containsAll($0.title) } + hits.filter { !containsAll($0.title) }
    }

    /// The line of `body` containing the first term of `query`, trimmed to about `width`
    /// characters around the match (for a sidebar subtitle).
    public static func snippet(_ body: String, query: String, width: Int = 60) -> String? {
        guard let term = query.split(whereSeparator: \.isWhitespace).first,
              let hit = body.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let lineStart = body[..<hit.lowerBound].lastIndex(where: \.isNewline).map(body.index(after:)) ?? body.startIndex
        let lineEnd = body[hit.upperBound...].firstIndex(where: \.isNewline) ?? body.endIndex
        let line = body[lineStart..<lineEnd]
        guard line.count > width else { return line.trimmingCharacters(in: .whitespaces) }
        let lead = max(0, body.distance(from: lineStart, to: hit.lowerBound) - width / 3)
        let start = line.index(line.startIndex, offsetBy: lead)
        let end = line.index(start, offsetBy: width, limitedBy: line.endIndex) ?? line.endIndex
        return (lead > 0 ? "…" : "") + line[start..<end].trimmingCharacters(in: .whitespaces) + (end < line.endIndex ? "…" : "")
    }

    // MARK: - Changes

    /// Creates and writes a pad.
    @discardableResult
    public func create(body: String = "", title: String? = nil, pinned: Bool = false, id: String? = nil) -> Pad {
        let date = now()
        var padID = id.flatMap { Pad.isValidID($0) ? $0 : nil } ?? Pad.newID(date: date)
        while pads[padID] != nil { padID = Pad.newID(date: date) }
        let pad = Pad(id: padID, body: body, createdAt: date, pinned: pinned, titleOverride: title)
        pads[pad.id] = pad
        write(pad)
        onChange?()
        return pad
    }

    /// Replaces a pad's body and schedules an autosave. No-op if the body is unchanged.
    public func update(_ id: String, body: String) {
        guard var pad = pads[id], pad.body != body else { return }
        pad.body = body
        pad.updatedAt = now()
        pads[id] = pad
        scheduleSave(id)
        onChange?()
    }

    public func setTitle(_ id: String, _ title: String?) {
        guard var pad = pads[id] else { return }
        pad.titleOverride = title.flatMap { $0.isEmpty ? nil : $0 }
        pad.updatedAt = now()
        pads[id] = pad
        write(pad)
        onChange?()
    }

    public func setPinned(_ id: String, _ pinned: Bool) {
        guard var pad = pads[id], pad.pinned != pinned else { return }
        pad.pinned = pinned
        pads[id] = pad
        write(pad)
        onChange?()
    }

    /// Empties a pad's body, keeping the pad (and any explicit title), and writes it at once.
    /// Returns the pad as it was so the caller can `restore` it (undo), or nil when there is no
    /// such pad or it was already empty.
    @discardableResult
    public func clear(_ id: String) -> Pad? {
        guard let before = pads[id], !before.body.isEmpty else { return nil }
        var pad = before.cleared()
        pad.updatedAt = now()
        pads[id] = pad
        pendingSaves.removeValue(forKey: id)?.cancel()
        write(pad)
        onChange?()
        return before
    }

    /// Removes a pad and its file; returns it so the caller can `restore` it (undo).
    @discardableResult
    public func delete(_ id: String) -> Pad? {
        guard let pad = pads.removeValue(forKey: id) else { return nil }
        pendingSaves.removeValue(forKey: id)?.cancel()
        do { try fm.removeItem(at: fileURL(for: id)) } catch CocoaError.fileNoSuchFile {} catch { lastError = error }
        onChange?()
        return pad
    }

    /// Puts a deleted (or cleared) pad back exactly as it was.
    public func restore(_ pad: Pad) {
        pendingSaves.removeValue(forKey: pad.id)?.cancel()
        pads[pad.id] = pad
        write(pad)
        onChange?()
    }

    // MARK: - Inbox

    /// The inbox pad, created (pinned, titled "Inbox") on first use.
    @discardableResult
    public func inbox() -> Pad {
        if let pad = pads[Pad.inboxID] { return pad }
        return create(title: "Inbox", pinned: true, id: Pad.inboxID)
    }

    /// `--- 2026-09-26 14:03:05 ---`
    public func separator(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "--- \(f.string(from: date)) ---"
    }

    /// Adds `text` to the inbox under a timestamp separator, at the end or the top according
    /// to `inboxPosition`. Written at once (pastes should never be lost to a crash).
    @discardableResult
    public func appendToInbox(_ text: String) -> Pad {
        var pad = inbox()
        let date = now()
        let entry = separator(for: date) + "\n" + text.trimmingCharacters(in: .newlines)
        let existing = pad.body.trimmingCharacters(in: .newlines)
        switch inboxPosition {
        case .append: pad.body = existing.isEmpty ? entry + "\n" : existing + "\n\n" + entry + "\n"
        case .prepend: pad.body = existing.isEmpty ? entry + "\n" : entry + "\n\n" + existing + "\n"
        }
        pad.updatedAt = date
        pads[pad.id] = pad
        pendingSaves.removeValue(forKey: pad.id)?.cancel()
        write(pad)
        onChange?()
        return pad
    }

    /// Appends `text` to the end of any pad on a new line (no separator). Written at once.
    @discardableResult
    public func append(_ text: String, to id: String) -> Pad? {
        guard var pad = pads[id] else { return nil }
        if id == Pad.inboxID { return appendToInbox(text) }
        let needsBreak = !pad.body.isEmpty && !pad.body.hasSuffix("\n")
        pad.body += (needsBreak ? "\n" : "") + text
        pad.updatedAt = now()
        pads[id] = pad
        pendingSaves.removeValue(forKey: id)?.cancel()
        write(pad)
        onChange?()
        return pad
    }

    // MARK: - Persistence

    public func fileURL(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(PadFile.fileExtension)
    }

    public var hasPendingSaves: Bool { !pendingSaves.isEmpty }

    /// Writes every pad with a pending autosave now.
    public func flush() {
        let ids = Array(pendingSaves.keys)
        for id in ids {
            pendingSaves.removeValue(forKey: id)?.cancel()
            if let pad = pads[id] { write(pad) }
        }
    }

    private func scheduleSave(_ id: String) {
        pendingSaves.removeValue(forKey: id)?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSaves[id] = nil
            if let pad = self.pads[id] { self.write(pad) }
        }
        pendingSaves[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDelay, execute: item)
    }

    private func write(_ pad: Pad) {
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try PadFile.encode(pad).write(to: fileURL(for: pad.id), atomically: true, encoding: .utf8)
        } catch {
            lastError = error
        }
    }
}
