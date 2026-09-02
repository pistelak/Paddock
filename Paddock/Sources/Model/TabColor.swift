import Foundation

/// A tile colour as persisted: a stable name, never a palette index, so
/// reordering or extending the palette cannot recolour saved tabs.
enum TabColorID: String, Codable, CaseIterable, Hashable, Sendable {
    case blue, green, pink, yellow, peach, mauve, teal, red

    var color: TabColor {
        switch self {
        case .blue: TabColor(red: 0.545, green: 0.667, blue: 0.918)
        case .green: TabColor(red: 0.647, green: 0.851, blue: 0.655)
        case .pink: TabColor(red: 0.961, green: 0.761, blue: 0.906)
        case .yellow: TabColor(red: 0.961, green: 0.882, blue: 0.549)
        case .peach: TabColor(red: 0.929, green: 0.612, blue: 0.435)
        case .mauve: TabColor(red: 0.792, green: 0.627, blue: 0.965)
        case .teal: TabColor(red: 0.580, green: 0.886, blue: 0.835)
        case .red: TabColor(red: 0.929, green: 0.529, blue: 0.573)
        }
    }

    var displayName: String {
        rawValue.capitalized
    }

    /// The least-used colour, earliest in palette order winning ties.
    static func leastUsed(among used: [TabColorID]) -> TabColorID {
        var counts: [TabColorID: Int] = [:]
        for id in used {
            counts[id, default: 0] += 1
        }
        return allCases.min { counts[$0, default: 0] < counts[$1, default: 0] } ?? .blue
    }

    /// Maps a tabs.json version 1 palette index onto today's palette.
    static func fromLegacyIndex(_ index: Int) -> TabColorID {
        let count = allCases.count
        return allCases[((index % count) + count) % count]
    }
}

struct TabColor: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}
