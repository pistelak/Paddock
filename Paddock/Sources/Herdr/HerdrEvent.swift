import Foundation

/// The kind of one stream event and nothing else — what the store actually
/// consumes.
///
/// Nothing downstream reads an event's payload (see `WorkspaceEventPolicy`
/// for why herdr's replayed backlog makes that the only safe rule), so nothing
/// on the hot path decodes one either. Decoding only the top-level `event`
/// string means a herdr that reshapes an event's *payload* — renames a field,
/// drops one, nests it differently — still produces the invalidation the
/// indicator depends on. The full-payload `HerdrEvent` below stays as the record
/// of herdr's shapes and is exercised by the protocol tests, but production
/// never decodes it.
///
/// Two envelope dialects arrive on the same connection: global events use an
/// underscored kind (`workspace_created`), parameterised subscriptions use the
/// dotted subscription name (`pane.agent_status_changed`). The kind is
/// normalised to underscores so both compare equal to the subscription that
/// produced them.
struct HerdrEventKind: Hashable, Sendable, Decodable, CustomStringConvertible {
    /// The kind with dots normalised to underscores.
    let rawValue: String

    init(wire kind: String) {
        rawValue = kind.replacingOccurrences(of: ".", with: "_")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wire: try container.decode(String.self, forKey: .event))
    }

    private enum CodingKeys: String, CodingKey {
        case event
    }

    var description: String { rawValue }
}

/// A stream event, decoded from herdr's `{"event": kind, "data": {…}}`
/// envelope down to the parts Paddock once reacted to.
///
/// **Not used on the hot path.** `HerdrSocketClient` streams `HerdrEventKind`;
/// this type documents herdr's payload shapes and is what the protocol tests
/// decode captured lines into, so drift shows up in tests without ever being
/// able to drop an invalidation in production.
///
/// Two envelope dialects arrive on the same connection. Global events name the
/// kind twice — `{"event":"workspace_created","data":{"type":"workspace_created",
/// "workspace":{…}}}` — and nest their payload under `workspace` / `pane`.
/// Events from a parameterised subscription use the dotted subscription name
/// and put the fields straight into `data`:
/// `{"event":"pane.agent_status_changed","data":{"pane_id":…,"agent_status":…}}`.
/// The kind is normalised (dots to underscores) so both decode to the same case.
///
/// An unknown kind decodes to `.other` rather than throwing: herdr streams
/// kinds Paddock never subscribed to (and future ones it does not know), and a
/// single unexpected line must not kill the event loop.
enum HerdrEvent: Decodable, Hashable, Sendable {
    case workspaceCreated(WorkspaceInfo)
    /// `workspace_updated` and `workspace_metadata_updated` carry the same
    /// full `WorkspaceInfo` and are treated as one upsert.
    case workspaceUpdated(WorkspaceInfo)
    case workspaceRenamed(id: WorkspaceID, label: String)
    case workspaceClosed(id: WorkspaceID)
    /// Both moved and reordered ship the complete, newly ordered list, so the
    /// reducer replaces its array instead of replaying the move.
    case workspaceMoved([WorkspaceInfo])
    case workspaceReordered([WorkspaceInfo])
    case workspaceFocused(id: WorkspaceID)
    case paneCreated(PaneInfo)
    case paneClosed(paneID: PaneID, workspaceID: WorkspaceID)
    case paneExited(paneID: PaneID, workspaceID: WorkspaceID)
    /// Fires when an agent is detected in a pane and again when it is
    /// released (`released: true`), never in between.
    case paneAgentDetected(paneID: PaneID, workspaceID: WorkspaceID, agent: String?, released: Bool)
    case paneAgentStatusChanged(paneID: PaneID, workspaceID: WorkspaceID, status: AgentStatus, agent: String?)
    case other(kind: String)

    private enum CodingKeys: String, CodingKey {
        case event
        case data
    }

    private enum DataKeys: String, CodingKey {
        case workspace
        case workspaces
        case workspaceID = "workspace_id"
        case label
        case pane
        case paneID = "pane_id"
        case agent
        case agentStatus = "agent_status"
        case released
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .event)
        // Subscription events spell the kind as the dotted subscription name.
        let normalized = kind.replacingOccurrences(of: ".", with: "_")
        // Falling back to `.other` when `data` is not an object at all keeps a
        // reshaped payload from throwing; a known kind whose fields are missing
        // still fails loudly, so drift shows up in tests.
        guard let data = try? container.nestedContainer(keyedBy: DataKeys.self, forKey: .data) else {
            self = .other(kind: kind)
            return
        }

        switch normalized {
        case "workspace_created":
            self = .workspaceCreated(try data.decode(WorkspaceInfo.self, forKey: .workspace))
        case "workspace_updated", "workspace_metadata_updated":
            self = .workspaceUpdated(try data.decode(WorkspaceInfo.self, forKey: .workspace))
        case "workspace_renamed":
            self = .workspaceRenamed(
                id: try data.decode(WorkspaceID.self, forKey: .workspaceID),
                label: try data.decode(String.self, forKey: .label)
            )
        case "workspace_closed":
            self = .workspaceClosed(id: try data.decode(WorkspaceID.self, forKey: .workspaceID))
        case "workspace_moved":
            self = .workspaceMoved(try data.decode([WorkspaceInfo].self, forKey: .workspaces))
        case "workspace_reordered":
            self = .workspaceReordered(try data.decode([WorkspaceInfo].self, forKey: .workspaces))
        case "workspace_focused":
            self = .workspaceFocused(id: try data.decode(WorkspaceID.self, forKey: .workspaceID))
        case "pane_created":
            self = .paneCreated(try data.decode(PaneInfo.self, forKey: .pane))
        case "pane_closed":
            self = .paneClosed(
                paneID: try data.decode(PaneID.self, forKey: .paneID),
                workspaceID: try data.decode(WorkspaceID.self, forKey: .workspaceID)
            )
        case "pane_exited":
            self = .paneExited(
                paneID: try data.decode(PaneID.self, forKey: .paneID),
                workspaceID: try data.decode(WorkspaceID.self, forKey: .workspaceID)
            )
        case "pane_agent_detected":
            self = .paneAgentDetected(
                paneID: try data.decode(PaneID.self, forKey: .paneID),
                workspaceID: try data.decode(WorkspaceID.self, forKey: .workspaceID),
                agent: try data.decodeIfPresent(String.self, forKey: .agent),
                released: try data.decodeIfPresent(Bool.self, forKey: .released) ?? false
            )
        case "pane_agent_status_changed":
            self = .paneAgentStatusChanged(
                paneID: try data.decode(PaneID.self, forKey: .paneID),
                workspaceID: try data.decode(WorkspaceID.self, forKey: .workspaceID),
                status: try data.decode(AgentStatus.self, forKey: .agentStatus),
                agent: try data.decodeIfPresent(String.self, forKey: .agent)
            )
        default:
            self = .other(kind: kind)
        }
    }
}

/// One line read from the events connection.
///
/// The subscribe acknowledgement is not an event but the ordinary reply to the
/// `events.subscribe` request — `{"id":"sub","result":{"type":"subscription_started"}}`
/// — and a rejected subscription comes back as an ordinary error response on
/// the same connection. Modelling the ack as an event kind would hide that;
/// keeping the two apart lets the client await the reply, throw on its error,
/// and then treat every following line as an event.
///
/// An event line yields only its kind: the payload is never looked at, so a
/// payload herdr has reshaped cannot make a known kind fail to decode.
enum HerdrEventLine: Sendable {
    case response(HerdrResponse)
    case event(HerdrEventKind)

    init(line: Data) throws {
        if let kind = try JSONDecoder().decode(Probe.self, from: line).event {
            self = .event(HerdrEventKind(wire: kind))
        } else {
            self = .response(try HerdrResponse(line: line))
        }
    }

    private struct Probe: Decodable {
        let event: String?
    }
}
