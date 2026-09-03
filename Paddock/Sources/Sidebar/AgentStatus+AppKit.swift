import AppKit

extension AgentStatus {
    /// The dot colour for a status, shared by the space rows and the tile
    /// badge so the two never disagree about what "blocked" looks like.
    var dotColor: NSColor {
        switch self {
        case .idle: .tertiaryLabelColor
        case .working: .systemBlue
        case .blocked: .systemOrange
        case .done: .systemGreen
        case .unknown: .quaternaryLabelColor
        }
    }

    /// Whether a tile badge is worth drawing: the two "nothing is happening"
    /// statuses are the resting state and get no dot.
    var deservesBadge: Bool {
        switch self {
        case .working, .blocked, .done: true
        case .idle, .unknown: false
        }
    }
}
