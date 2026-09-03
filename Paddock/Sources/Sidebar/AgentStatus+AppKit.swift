import AppKit

extension TileIndicator.Mark {
    /// Red for a request that is waiting on the user, so it reads as urgent
    /// next to the green and blue, and the numeral carries the meaning for
    /// anyone who does not see the colour.
    var color: NSColor {
        switch self {
        case .attention: .systemRed
        case .done: .systemGreen
        case .working: .systemBlue
        }
    }
}
