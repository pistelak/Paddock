import Foundation

/// Everything a session tile shows beyond its colour and initials, decided in
/// one place from the session's state and connection so it can be tested
/// without a window.
///
/// One mark per tile, by precedence: a space whose agent is **waiting for the
/// user** beats everything and is shown as a count; a finished-but-unseen
/// space is a check; an agent still working is a quiet dot; idle and unknown
/// draw nothing. The number counts *spaces* (herdr folds panes into a space's
/// status), and only `blocked` ones — `done` clears itself the moment the user
/// focuses that agent, so mixing it into the number would make "3" ambiguous.
struct TileIndicator: Equatable, Sendable {
    enum Mark: Equatable, Sendable {
        /// `count` spaces are waiting for the user. Red badge with the number.
        case attention(count: Int)
        /// At least one space finished and has not been looked at. Green check.
        case done
        /// At least one agent is working. Blue dot.
        case working

        /// A pill with a number rather than a dot.
        var isBadge: Bool {
            if case .attention = self { return true }
            return false
        }
    }

    /// What to draw in the corner, if anything.
    let mark: Mark?
    /// The connection is not keeping the state current: draw the tile dimmed.
    let isDimmed: Bool
    /// The session name while live; what the connection is doing otherwise.
    let tooltip: String
    /// What VoiceOver reads: the name, then what is drawn and what was
    /// suppressed by precedence, then the connection if it is not live.
    let accessibilityLabel: String

    /// A tile whose session has no store yet: nothing to say, not dimmed.
    static func none(displayName: String, sessionName: String) -> TileIndicator {
        TileIndicator(mark: nil, isDimmed: false, tooltip: sessionName, accessibilityLabel: displayName)
    }

    init(mark: Mark?, isDimmed: Bool, tooltip: String, accessibilityLabel: String) {
        self.mark = mark
        self.isDimmed = isDimmed
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
    }

    init(
        displayName: String,
        sessionName: String,
        state: WorkspaceListState,
        connection: WorkspaceStore.ConnectionState
    ) {
        let blocked = state.count(of: .blocked)
        let done = state.count(of: .done)
        let working = state.count(of: .working)

        mark = if blocked > 0 {
            .attention(count: blocked)
        } else if done > 0 {
            .done
        } else if working > 0 {
            .working
        } else {
            nil
        }
        isDimmed = !connection.isConnected
        let connectionText = Self.text(for: connection)
        tooltip = connectionText ?? sessionName

        var parts = [displayName]
        if blocked > 0 { parts.append(Self.plural(blocked, "space") + " need" + (blocked == 1 ? "s" : "") + " your input") }
        if done > 0 { parts.append(Self.plural(done, "space") + " finished") }
        if working > 0 { parts.append(Self.plural(working, "space") + " working") }
        if let connectionText { parts.append(connectionText.lowercased()) }
        accessibilityLabel = parts.joined(separator: ", ")
    }

    /// The tooltip line for a connection that is not simply live; `nil` when it
    /// is, because then the session name says everything.
    static func text(for connection: WorkspaceStore.ConnectionState) -> String? {
        switch connection {
        case .live:
            nil
        case .idle, .connecting:
            "Connecting…"
        case .sessionNotRunning:
            "Session not running"
        case let .reconnecting(reason):
            "Reconnecting… \(text(for: reason))"
        case let .unsupportedProtocol(version):
            "herdr protocol \(version); expected \(HerdrProtocol.supported)"
        }
    }

    static func text(for reason: WorkspaceStore.ReconnectReason) -> String {
        switch reason {
        case .streamEnded:
            "herdr closed the connection."
        case let .failed(error):
            error.errorDescription ?? String(describing: error)
        case let .unexpected(description):
            description
        }
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
