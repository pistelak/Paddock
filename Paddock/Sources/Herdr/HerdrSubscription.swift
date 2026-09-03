import Foundation

/// One entry of `events.subscribe`'s `subscriptions` array.
///
/// Subscription names are dotted (`workspace.created`) while the event kinds
/// they produce are underscored (`workspace_created`); the two vocabularies
/// are unrelated strings, so both are spelled out rather than derived.
///
/// `pane.agent_status_changed` is the only kind Paddock needs that takes a
/// `pane_id`, and it is the only source of agent-status transitions: the spike
/// showed `workspace.updated` / `workspace.metadata_updated` stay silent when a
/// pane's agent changes state. Because herdr accepts exactly one request per
/// connection, a new pane means tearing the events connection down and
/// resubscribing with the full list.
enum HerdrSubscription: Encodable, Hashable, Sendable {
    case workspaceCreated
    case workspaceUpdated
    case workspaceMetadataUpdated
    case workspaceRenamed
    case workspaceMoved
    case workspaceReordered
    case workspaceClosed
    case workspaceFocused
    case paneCreated
    case paneClosed
    case paneExited
    case paneAgentDetected
    case paneAgentStatusChanged(paneID: PaneID)

    /// The wire value of the subscription's `type`.
    var type: String {
        switch self {
        case .workspaceCreated: "workspace.created"
        case .workspaceUpdated: "workspace.updated"
        case .workspaceMetadataUpdated: "workspace.metadata_updated"
        case .workspaceRenamed: "workspace.renamed"
        case .workspaceMoved: "workspace.moved"
        case .workspaceReordered: "workspace.reordered"
        case .workspaceClosed: "workspace.closed"
        case .workspaceFocused: "workspace.focused"
        case .paneCreated: "pane.created"
        case .paneClosed: "pane.closed"
        case .paneExited: "pane.exited"
        case .paneAgentDetected: "pane.agent_detected"
        case .paneAgentStatusChanged: "pane.agent_status_changed"
        }
    }

    /// The kind of the events this subscription produces. herdr streams a
    /// global event under its underscored name and a parameterised one under
    /// the dotted subscription name; `HerdrEventKind` normalises both, so the
    /// subscription's own `type` is enough to name what comes back.
    var eventKind: HerdrEventKind {
        HerdrEventKind(wire: type)
    }

    /// Every workspace kind, in schema order: the set a store subscribes to
    /// to keep its spaces current.
    static let workspaceKinds: [HerdrSubscription] = [
        .workspaceCreated,
        .workspaceUpdated,
        .workspaceMetadataUpdated,
        .workspaceRenamed,
        .workspaceMoved,
        .workspaceReordered,
        .workspaceClosed,
        .workspaceFocused,
    ]

    /// The global pane kinds that tell the store the pane set changed and the
    /// per-pane status subscriptions have to be rebuilt.
    static let paneKinds: [HerdrSubscription] = [
        .paneCreated,
        .paneClosed,
        .paneExited,
        .paneAgentDetected,
    ]

    enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        if case let .paneAgentStatusChanged(paneID) = self {
            try container.encode(paneID.rawValue, forKey: .paneID)
        }
    }
}

/// Params of `events.subscribe`.
struct EventsSubscribeParams: Encodable, Sendable {
    let subscriptions: [HerdrSubscription]

    init(_ subscriptions: [HerdrSubscription]) {
        self.subscriptions = subscriptions
    }
}
