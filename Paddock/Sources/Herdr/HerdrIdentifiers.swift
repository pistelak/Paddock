import Foundation

/// The identifier of one herdr workspace, as herdr issues it (`"w4"`).
///
/// A newtype so that a workspace id and a pane id can never be handed to each
/// other's APIs — the two are spelled identically on the wire (`"w4"` and
/// `"w4:p1"`) and both used to travel as `String` from the socket to the
/// outline view's item cache. Non-empty by construction: decoding `""` fails,
/// and there is no way to write the sentinel id the column once used as a
/// placeholder. `SessionName` is the same idea with a stricter alphabet.
///
/// String literals are accepted so fixtures read as `"w4"`; a literal is a
/// compile-time constant, which is not the mistake this type exists to catch.
struct WorkspaceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        precondition(!value.isEmpty, "a workspace id literal cannot be empty")
        rawValue = value
    }

    var description: String { rawValue }
}

/// The identifier of one herdr pane (`"w4:p1"`). See `WorkspaceID`.
struct PaneID: Hashable, Sendable, Codable, RawRepresentable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        precondition(!value.isEmpty, "a pane id literal cannot be empty")
        rawValue = value
    }

    /// Ordered by the wire string, so a subscription list built from a set of
    /// panes always comes out the same way.
    static func < (lhs: PaneID, rhs: PaneID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { rawValue }
}
