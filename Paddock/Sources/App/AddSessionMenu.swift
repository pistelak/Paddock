import AppKit

/// The menu behind the "+" tile: every herdr session that has no tab yet,
/// then "New Session…".
///
/// `NSMenu.popUp` runs its own tracking loop and returns once the menu is
/// dismissed, so this is a plain synchronous call that hands back what the
/// user picked — or nothing.
@MainActor
enum AddSessionMenu {
    enum Choice: Equatable {
        case existing(SessionName)
        case create
    }

    static func present(from anchor: NSView, sessions: [SessionName]) -> Choice? {
        var choice: Choice?
        let menu = NSMenu()
        for name in sessions {
            menu.addItem(ClosureMenuItem(title: name.rawValue) { choice = .existing(name) })
        }
        if !sessions.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "New Session…") { choice = .create })
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.maxX + 4, y: anchor.bounds.midY), in: anchor)
        return choice
    }
}
