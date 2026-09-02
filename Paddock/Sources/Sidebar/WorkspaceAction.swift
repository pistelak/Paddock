import Foundation

/// What the spaces column asks the coordinator to do on a workspace's behalf.
///
/// Mirrors `SidebarAction`: the column never talks to a `WorkspaceStore`
/// itself, it reports intent and the coordinator turns it into a herdr call.
enum WorkspaceAction: Sendable {
    case focus
    case rename
    case close
}
