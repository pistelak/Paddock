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

/// The part of a pane the spaces column needs.
///
/// Panes are tracked at all because agent status only ever arrives through the
/// per-pane `pane.agent_status_changed` subscription (the spike found that
/// workspace events never carry it), so the store has to know every pane id to
/// subscribe, and the reducer has to fold the panes back into a per-workspace
/// status. Geometry, titles and tab ids are not modelled: nothing reads them.
struct PaneSummary: Equatable, Hashable, Sendable {
    /// Immutable: a pane never migrates between workspaces; herdr closes and
    /// recreates it instead.
    let workspaceID: String
    var agent: String?
    var agentStatus: AgentStatus

    init(workspaceID: String, agent: String? = nil, agentStatus: AgentStatus) {
        self.workspaceID = workspaceID
        self.agent = agent
        self.agentStatus = agentStatus
    }

    init(_ info: PaneInfo) {
        self.init(workspaceID: info.workspaceID, agent: info.agent, agentStatus: info.agentStatus)
    }
}

/// Everything the spaces column draws for one herdr session: the ordered
/// workspaces exactly as herdr lists them, plus the panes that supply their
/// live agent status.
///
/// The type is a plain value so the store can diff two versions with `==` and
/// skip a render. Order is herdr's — never sorted here — because
/// `workspace.moved` / `workspace.reordered` ship the full ordered list.
struct WorkspaceListState: Equatable, Sendable {
    var workspaces: [WorkspaceInfo]
    /// Keyed by pane id, the identifier the per-pane subscription needs.
    var panes: [String: PaneSummary]

    init() {
        workspaces = []
        panes = [:]
    }

    /// Replace-all from a `session.snapshot`, the authoritative starting point.
    ///
    /// `focused_workspace_id` is deliberately ignored: the per-workspace
    /// `focused` flag says the same thing, and keeping one source of truth
    /// means `focusedID` can be derived instead of maintained.
    init(snapshot: SessionSnapshot) {
        self.init(workspaces: snapshot.workspaces, panes: snapshot.panes)
    }

    /// Replace-all from a `workspace.list` resync (panes optional, because
    /// `workspace.list` does not carry them; the store keeps its pane set).
    init(workspaces: [WorkspaceInfo], panes: [PaneInfo] = []) {
        self.workspaces = workspaces
        self.panes = Dictionary(
            panes.map { ($0.paneID, PaneSummary($0)) },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Derived, not stored: the `focused` flag on the rows is what the column
    /// draws, so a second stored copy could only ever disagree with it. The
    /// reducer keeps at most one row flagged.
    var focusedID: String? {
        workspaces.first(where: \.focused)?.workspaceID
    }

    /// Sorted so that two equal pane sets always produce the same subscription
    /// list and the store can compare them to decide whether to reconnect.
    var paneIDs: [String] {
        panes.keys.sorted()
    }

    func index(of workspaceID: String) -> Int? {
        workspaces.firstIndex { $0.workspaceID == workspaceID }
    }

    func workspace(_ workspaceID: String) -> WorkspaceInfo? {
        index(of: workspaceID).map { workspaces[$0] }
    }

    /// The status to draw for one workspace.
    ///
    /// Pane-derived (highest `displayPriority` among its panes) as soon as any
    /// pane of that workspace is known, because pane events are the only live
    /// source of status. Falls back to `WorkspaceInfo.agentStatus`, which is
    /// authoritative at snapshot/list time but then goes stale.
    func status(of workspaceID: String) -> AgentStatus {
        var derived: AgentStatus?
        for pane in panes.values where pane.workspaceID == workspaceID {
            if pane.agentStatus.displayPriority > (derived?.displayPriority ?? -1) {
                derived = pane.agentStatus
            }
        }
        return derived ?? workspace(workspaceID)?.agentStatus ?? .unknown
    }

    /// The one status that stands for the whole session — the tile badge.
    var aggregateStatus: AgentStatus {
        var result = AgentStatus.unknown
        for workspace in workspaces {
            let status = status(of: workspace.workspaceID)
            if status.displayPriority > result.displayPriority {
                result = status
            }
        }
        return result
    }
}

/// `WorkspaceInfo` is decoded straight off the wire and has only `let` fields,
/// but two events (`workspace_renamed`, `workspace_focused`) change exactly one
/// of them. These produce the edited copy instead of making the wire type
/// mutable, so a row can still only be built from a complete herdr payload.
extension WorkspaceInfo {
    func with(label: String) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: focused,
            paneCount: paneCount,
            tabCount: tabCount,
            activeTabID: activeTabID,
            agentStatus: agentStatus,
            tokens: tokens,
            worktree: worktree
        )
    }

    func with(focused: Bool) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: workspaceID,
            number: number,
            label: label,
            focused: focused,
            paneCount: paneCount,
            tabCount: tabCount,
            activeTabID: activeTabID,
            agentStatus: agentStatus,
            tokens: tokens,
            worktree: worktree
        )
    }
}
