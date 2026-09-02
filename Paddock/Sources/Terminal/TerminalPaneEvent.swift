import Foundation

/// What a pane reports upward. One enum instead of one closure per
/// concern, so bell and notification events can join without new plumbing.
enum TerminalPaneEvent: Sendable {
    /// The terminal title changed; `nil` after a reattach cleared it.
    case titleChanged(String?)
}
