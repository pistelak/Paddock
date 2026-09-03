import Foundation

/// The main window's title, derived from the selected tab and what its
/// terminal last said. A pure function so the three cases are testable.
///
/// An empty terminal title counts as no title. The coordinator used to join
/// with `compactMap`, which kept `""` and produced "Work — " with nothing
/// after the dash; that was a bug, not a behaviour to preserve.
enum WindowTitle {
    static let appName = "Paddock"

    static func text(tab: SessionTab?, terminalTitle: String?) -> String {
        guard let tab else { return appName }
        guard let terminalTitle, !terminalTitle.isEmpty else { return tab.displayName }
        return "\(tab.displayName) — \(terminalTitle)"
    }
}
