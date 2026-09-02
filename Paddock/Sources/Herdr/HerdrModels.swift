import Foundation

/// The status herdr reports for an agent, a pane, a tab or a workspace.
///
/// Unlisted strings decode as `.unknown` instead of failing: a new status in a
/// future herdr must not take the whole snapshot down with it. Note that an
/// agent reporting `idle` surfaces here as `done`; `idle` is what herdr uses
/// for "no agent has said anything".
enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case blocked
    case done
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

/// The git worktree a workspace was opened for.
///
/// Every field is optional even though the schema marks most of them required:
/// Paddock does not use them yet, and a workspace must not fail to decode
/// because herdr reshaped a part of the payload nothing here reads.
struct WorkspaceWorktreeInfo: Codable, Hashable, Sendable {
    let repoKey: String?
    let repoName: String?
    let repoRoot: String?
    let checkoutPath: String?
    let isLinkedWorktree: Bool?

    enum CodingKeys: String, CodingKey {
        case repoKey = "repo_key"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
        case checkoutPath = "checkout_path"
        case isLinkedWorktree = "is_linked_worktree"
    }
}

/// A herdr workspace — what Paddock's column calls a "space".
///
/// The same shape arrives from `workspace.list`, `session.snapshot` and the
/// `workspace_*` events, so it is decoded once here and used everywhere.
struct WorkspaceInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String { workspaceID }

    let workspaceID: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let tabCount: Int
    let activeTabID: String
    let agentStatus: AgentStatus
    let tokens: [String: String]?
    let worktree: WorkspaceWorktreeInfo?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case number
        case label
        case focused
        case paneCount = "pane_count"
        case tabCount = "tab_count"
        case activeTabID = "active_tab_id"
        case agentStatus = "agent_status"
        case tokens
        case worktree
    }

    init(
        workspaceID: String,
        number: Int,
        label: String,
        focused: Bool,
        paneCount: Int,
        tabCount: Int,
        activeTabID: String,
        agentStatus: AgentStatus,
        tokens: [String: String]? = nil,
        worktree: WorkspaceWorktreeInfo? = nil
    ) {
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
        self.focused = focused
        self.paneCount = paneCount
        self.tabCount = tabCount
        self.activeTabID = activeTabID
        self.agentStatus = agentStatus
        self.tokens = tokens
        self.worktree = worktree
    }
}

/// A pane, reduced to what the column needs: which workspace it belongs to,
/// which agent runs in it and how that agent is doing. Panes matter in phase 1
/// only because `pane.agent_status_changed` has to be subscribed per pane;
/// the geometry, scroll and terminal fields herdr also sends are ignored.
struct PaneInfo: Codable, Hashable, Sendable, Identifiable {
    var id: String { paneID }

    let paneID: String
    let workspaceID: String
    let tabID: String
    let agent: String?
    let agentStatus: AgentStatus
    let terminalTitleStripped: String?
    let title: String?
    let focused: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case tabID = "tab_id"
        case agent
        case agentStatus = "agent_status"
        case terminalTitleStripped = "terminal_title_stripped"
        case title
        case focused
    }

    init(
        paneID: String,
        workspaceID: String,
        tabID: String,
        agent: String? = nil,
        agentStatus: AgentStatus,
        terminalTitleStripped: String? = nil,
        title: String? = nil,
        focused: Bool
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agent = agent
        self.agentStatus = agentStatus
        self.terminalTitleStripped = terminalTitleStripped
        self.title = title
        self.focused = focused
    }
}

/// `result` of `ping`, the only way to learn the server's protocol version.
///
/// Capabilities are a bag of feature flags Paddock does not act on; a value
/// that is not a bool is dropped rather than failing the version check the
/// call exists for.
struct PingResult: Decodable, Sendable {
    let version: String
    let protocolVersion: Int
    let capabilities: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case capabilities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        capabilities = (try? container.decodeIfPresent([String: Bool].self, forKey: .capabilities)) ?? [:]
    }
}

/// The *inner* object of `session.snapshot`, whose result is
/// `{"type":"session_snapshot","snapshot":{…}}` — decode a
/// `SessionSnapshotResult` from the response and take its `snapshot`.
///
/// herdr also sends `tabs`, `layouts`, `agents`, `focused_tab_id` and
/// `focused_pane_id`; the column does not use them, so they are not modelled.
struct SessionSnapshot: Decodable, Hashable, Sendable {
    let version: String
    let protocolVersion: Int
    let workspaces: [WorkspaceInfo]
    let panes: [PaneInfo]
    let focusedWorkspaceID: String?

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case workspaces
        case panes
        case focusedWorkspaceID = "focused_workspace_id"
    }
}

struct SessionSnapshotResult: Decodable, Sendable {
    let snapshot: SessionSnapshot
}

/// `result` of `workspace.list`.
struct WorkspaceListResult: Decodable, Sendable {
    let workspaces: [WorkspaceInfo]
}

/// `result` of `pane.list`.
struct PaneListResult: Decodable, Sendable {
    let panes: [PaneInfo]
}
