import Foundation

/// User settings (schema: Sources/Scratch/Resources/settings.json), stored as JSON at `<base>/preferences.json`.
public struct ScratchSettings: Codable, Equatable, Sendable {
    /// New editors start in a monospaced font.
    public var defaultMonospace: Bool = true
    /// Seconds without typing before a pad is written.
    public var autosaveDelay: Double = 0.75
    /// `append` (newest at the bottom) or `prepend` (newest at the top).
    public var inboxPosition: String = InboxPosition.append.rawValue
    /// The paste-to-Scratch hotkey shows the panel for a moment.
    public var inboxShowsPanel: Bool = true
    /// The pad list beside the editor (`sidebar.visible`). Off by default: Scratch is one pad
    /// you type into; the Pads menu in the header switches pads when the list is hidden.
    public var sidebarVisible: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case defaultMonospace, autosaveDelay, inboxPosition, inboxShowsPanel
        case sidebarVisible = "sidebar.visible"
    }

    /// Saved values are merged over the defaults key by key: a missing key (an older file) or
    /// one that no longer decodes keeps its default, and every other saved value is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScratchSettings()
        defaultMonospace = Self.value(c, .defaultMonospace, default: d.defaultMonospace)
        autosaveDelay = Self.value(c, .autosaveDelay, default: d.autosaveDelay)
        inboxPosition = Self.value(c, .inboxPosition, default: d.inboxPosition)
        inboxShowsPanel = Self.value(c, .inboxShowsPanel, default: d.inboxShowsPanel)
        sidebarVisible = Self.value(c, .sidebarVisible, default: d.sidebarVisible)
    }

    private static func value<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, default fallback: T) -> T {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    public static let autosaveRange: ClosedRange<Double> = 0.1...10

    public var inbox: InboxPosition { InboxPosition(rawValue: inboxPosition) ?? .append }

    public var json: [String: Any] {
        ["defaultMonospace": defaultMonospace, "autosaveDelay": autosaveDelay,
         "inboxPosition": inboxPosition, "inboxShowsPanel": inboxShowsPanel,
         "sidebar.visible": sidebarVisible]
    }

    public enum SettingsError: Error, CustomStringConvertible, Equatable {
        case invalid(String)
        public var description: String { if case .invalid(let s) = self { return s }; return "" }
    }

    /// Applies string values (from `settings set`), validating all before changing any.
    public func applying(_ values: [String: String]) throws -> ScratchSettings {
        var copy = self
        for (key, value) in values {
            switch key {
            case "defaultMonospace": copy.defaultMonospace = try Self.bool(value, key)
            case "inboxShowsPanel": copy.inboxShowsPanel = try Self.bool(value, key)
            case "sidebar.visible": copy.sidebarVisible = try Self.bool(value, key)
            case "autosaveDelay":
                guard let d = Double(value), Self.autosaveRange.contains(d) else {
                    throw SettingsError.invalid("autosaveDelay must be a number of seconds between 0.1 and 10")
                }
                copy.autosaveDelay = d
            case "inboxPosition":
                guard InboxPosition(rawValue: value) != nil else {
                    throw SettingsError.invalid("inboxPosition must be append or prepend")
                }
                copy.inboxPosition = value
            default:
                throw SettingsError.invalid("unknown setting \(key)")
            }
        }
        return copy
    }

    static func bool(_ value: String, _ key: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw SettingsError.invalid("\(key) must be true or false")
        }
    }

    public static func load(from url: URL) -> ScratchSettings {
        guard let data = try? Data(contentsOf: url) else { return ScratchSettings() }
        return (try? JSONDecoder().decode(ScratchSettings.self, from: data)) ?? ScratchSettings()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
