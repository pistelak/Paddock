import Foundation

/// One side tab: a herdr session plus how the tile shows it.
///
/// Deliberately *not* `Codable`. The on-disk shape lives in `TabsDocument`'s
/// frozen stored types, which build a `SessionTab` through this initialiser —
/// a synthesised `Decodable` would assign `displayName` directly and skip the
/// normalisation below, so a blank name in the file would become a blank tile.
struct SessionTab: Hashable, Identifiable, Sendable {
    let id: UUID
    let sessionName: SessionName
    private(set) var displayName: String
    private(set) var color: TabColorID

    init(id: UUID = UUID(), sessionName: SessionName, displayName: String? = nil, color: TabColorID) {
        self.id = id
        self.sessionName = sessionName
        self.displayName = Self.normalizedDisplayName(displayName, fallback: sessionName)
        self.color = color
    }

    /// Trims the name; an empty name falls back to the session name so a
    /// tile always has something to show.
    mutating func rename(_ name: String) {
        displayName = Self.normalizedDisplayName(name, fallback: sessionName)
    }

    mutating func recolor(_ color: TabColorID) {
        self.color = color
    }

    /// Up to two characters shown on the tile: first letters of the first
    /// two words, or the first two letters of a single word.
    var initials: String {
        let words = displayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
            .filter { !$0.isEmpty }
        let letters: String = switch words.count {
        case 0: ""
        case 1: String(words[0].prefix(2))
        default: words.prefix(2).compactMap(\.first).map { String($0) }.joined()
        }
        return letters.uppercased()
    }

    private static func normalizedDisplayName(_ name: String?, fallback: SessionName) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback.rawValue : trimmed
    }
}
