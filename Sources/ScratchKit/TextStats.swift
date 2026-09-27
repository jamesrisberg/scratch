import Foundation

/// Word, character and line counts for the editor footer.
public struct TextStats: Equatable, Sendable {
    public var words: Int
    public var characters: Int
    public var lines: Int

    public init(words: Int, characters: Int, lines: Int) {
        self.words = words
        self.characters = characters
        self.lines = lines
    }

    public init(_ text: String) {
        var words = 0
        var inWord = false
        for ch in text {
            if ch.isWhitespace { inWord = false } else if !inWord { inWord = true; words += 1 }
        }
        self.words = words
        characters = text.count
        lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// `12 words · 64 chars`
    public var summary: String {
        "\(words) \(words == 1 ? "word" : "words") · \(characters) \(characters == 1 ? "char" : "chars")"
    }
}
