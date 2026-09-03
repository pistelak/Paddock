import Foundation

/// How prominent a status is when several have to collapse into one dot.
///
/// The order is `blocked > done > working > idle > unknown`: a space that needs
/// the user beats one that just finished, and `unknown` ("nothing has told us
/// anything") always loses. Used to fold a workspace's panes into one status
/// and, later, several workspaces into one tile badge.
extension AgentStatus {
    var displayPriority: Int {
        switch self {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }
}

/// One space as Paddock knows it: the part of a `WorkspaceInfo` the indicator
/// is derived from, and nothing that only the wire cares about.
///
/// Deliberately without a `focused` flag. Which space is focused is one fact
/// about the *list*, so it is stored once on `WorkspaceListState` and anyone
/// asks `state.focusedID == id`; a flag per space could only ever disagree
/// with it.
struct Workspace: Hashable, Sendable, Identifiable {
    let id: WorkspaceID
    let number: Int
    let label: String
    let agentStatus: AgentStatus

    init(id: WorkspaceID, number: Int, label: String, agentStatus: AgentStatus) {
        self.id = id
        self.number = number
        self.label = label
        self.agentStatus = agentStatus
    }

    init(_ info: WorkspaceInfo) {
        self.init(id: info.workspaceID, number: info.number, label: info.label, agentStatus: info.agentStatus)
    }
}

/// The part of a pane the indicator needs.
///
/// Panes are tracked at all because agent status only ever arrives through the
/// per-pane `pane.agent_status_changed` subscription (the spike found that
/// workspace events never carry it), so the store has to know every pane id to
/// subscribe, and `status(of:)` has to fold the panes back into a per-workspace
/// status. Geometry, titles and tab ids are not modelled: nothing reads them.
struct PaneSummary: Equatable, Hashable, Sendable {
    /// Immutable: a pane never migrates between workspaces; herdr closes and
    /// recreates it instead.
    let workspaceID: WorkspaceID
    var agent: String?
    var agentStatus: AgentStatus

    init(workspaceID: WorkspaceID, agent: String? = nil, agentStatus: AgentStatus) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.agentStatus = agentStatus
    }

    init(_ info: PaneInfo) {
        self.init(workspaceID: info.workspaceID, agent: info.agent, agentStatus: info.agentStatus)
    }
}

/// Everything Paddock knows about one herdr session's spaces: the ordered
/// workspaces exactly as herdr lists them, which one is focused, plus the panes
/// that supply their live agent status.
///
/// The type is a plain value so the store can diff two versions with `==` and
/// skip a render. Order is herdr's — never sorted here — because
/// `workspace.moved` / `workspace.reordered` ship the full ordered list.
///
/// A state is only ever built from a `session.snapshot`, through
/// `init(snapshot:)`, which is where herdr's wire shape is *checked* as well
/// as translated: duplicate ids, a pane in an unlisted workspace or a focused
/// id naming no workspace are refused rather than counted: the tile's
/// indicator is derived from this list and must not be built on a snapshot
/// that contradicts itself.
struct WorkspaceListState: Equatable, Sendable {
    let workspaces: [Workspace]
    /// Keyed by pane id, the identifier the per-pane subscription needs.
    let panes: [PaneID: PaneSummary]
    /// Stored once, for the whole list. `nil` for an empty list.
    let focusedID: WorkspaceID?
    /// The status each workspace draws, folded from its panes once here so a
    /// render is one lookup per space instead of one scan of every pane per space.
    /// A workspace with no listed panes falls back to its own `agentStatus`.
    let statusByWorkspace: [WorkspaceID: AgentStatus]

    init() {
        self.init(workspaces: [], panes: [:], focusedID: nil)
    }

    /// Immutable by design: every field is derived from one snapshot, and the
    /// store replaces whole states, so nothing may edit one field and leave
    /// the others describing a different moment.
    init(workspaces: [Workspace], panes: [PaneID: PaneSummary] = [:], focusedID: WorkspaceID? = nil) {
        self.workspaces = workspaces
        self.panes = panes
        self.focusedID = focusedID

        var derived: [WorkspaceID: AgentStatus] = [:]
        for pane in panes.values {
            let current = derived[pane.workspaceID]
            if pane.agentStatus.displayPriority > (current?.displayPriority ?? -1) {
                derived[pane.workspaceID] = pane.agentStatus
            }
        }
        var statuses: [WorkspaceID: AgentStatus] = [:]
        statuses.reserveCapacity(workspaces.count)
        // First entry wins for a duplicated id, matching `workspace(_:)`. The
        // snapshot mapper never lets a duplicate through; this initialiser is
        // unchecked and must not disagree with the lookup next to it.
        for workspace in workspaces where statuses[workspace.id] == nil {
            statuses[workspace.id] = derived[workspace.id] ?? workspace.agentStatus
        }
        statusByWorkspace = statuses
    }

    /// Replace-all from a `session.snapshot`, the authoritative starting point.
    ///
    /// herdr says which space is focused twice — a top-level
    /// `focused_workspace_id` and a `focused` flag on the entries. The top-level
    /// id wins and has to name a listed workspace. Without it the flags are
    /// the fallback, and then exactly one entry must carry one: a non-empty
    /// list with no focused entry, or with two, contradicts itself and there is
    /// no basis for picking, so it is refused like any other inconsistency.
    /// An empty list has no focus, and says so with `nil`.
    init(snapshot: SessionSnapshot) throws {
        var seen = Set<WorkspaceID>()
        for workspace in snapshot.workspaces {
            guard seen.insert(workspace.workspaceID).inserted else {
                throw PaddockError.herdrSnapshotInvalid("workspace \(workspace.workspaceID) is listed twice")
            }
        }
        for pane in snapshot.panes where !seen.contains(pane.workspaceID) {
            throw PaddockError.herdrSnapshotInvalid("pane \(pane.paneID) belongs to unlisted workspace \(pane.workspaceID)")
        }

        let focusedID: WorkspaceID?
        if let authoritative = snapshot.focusedWorkspaceID {
            guard seen.contains(authoritative) else {
                throw PaddockError.herdrSnapshotInvalid("focused workspace \(authoritative) is not listed")
            }
            focusedID = authoritative
        } else if snapshot.workspaces.isEmpty {
            focusedID = nil
        } else {
            let flagged = snapshot.workspaces.filter(\.focused).map(\.workspaceID)
            guard flagged.count == 1 else {
                throw PaddockError.herdrSnapshotInvalid("expected exactly one focused workspace, found \(flagged.count)")
            }
            focusedID = flagged[0]
        }

        self.init(
            workspaces: snapshot.workspaces.map(Workspace.init),
            panes: Dictionary(
                snapshot.panes.map { ($0.paneID, PaneSummary($0)) },
                uniquingKeysWith: { _, last in last }
            ),
            focusedID: focusedID
        )
    }

    /// Sorted so that two equal pane sets always produce the same subscription
    /// list and the store can compare them to decide whether to reconnect.
    var paneIDs: [PaneID] {
        panes.keys.sorted()
    }

    func index(of workspaceID: WorkspaceID) -> Int? {
        workspaces.firstIndex { $0.id == workspaceID }
    }

    func workspace(_ workspaceID: WorkspaceID) -> Workspace? {
        index(of: workspaceID).map { workspaces[$0] }
    }

    /// The status to draw for one workspace.
    ///
    /// Pane-derived (highest `displayPriority` among its panes) as soon as any
    /// pane of that workspace is known, because the snapshot's panes carry the
    /// finer-grained status. Falls back to the workspace's own `agentStatus`
    /// for a workspace whose panes are not listed, and to `.unknown` for an id
    /// that is not in the list at all.
    func status(of workspaceID: WorkspaceID) -> AgentStatus {
        statusByWorkspace[workspaceID] ?? .unknown
    }

    /// The one status that stands for the whole session — the tile badge.
    var aggregateStatus: AgentStatus {
        statusByWorkspace.values.max { $0.displayPriority < $1.displayPriority } ?? .unknown
    }
}
