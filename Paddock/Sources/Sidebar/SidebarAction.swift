import Foundation

/// What the sidebar asks the coordinator to do on a tab's behalf.
enum SidebarAction: Sendable {
    case select
    case rename
    case recolor(TabColorID)
    case remove
    case stopSession
}
