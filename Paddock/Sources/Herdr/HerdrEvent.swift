import Foundation

/// A stream event, decoded from herdr's `{"event": kind, "data": {…}}`
/// envelope down to the parts the spaces column reacts to.
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
    case workspaceRenamed(id: String, label: String)
    case workspaceClosed(id: String)
    /// Both moved and reordered ship the complete, newly ordered list, so the
    /// reducer replaces its array instead of replaying the move.
    case workspaceMoved([WorkspaceInfo])
    case workspaceReordered([WorkspaceInfo])
    case workspaceFocused(id: String)
    case paneCreated(PaneInfo)
    case paneClosed(paneID: String, workspaceID: String)
    case paneExited(paneID: String, workspaceID: String)
    /// Fires when an agent is detected in a pane and again when it is
    /// released (`released: true`), never in between.
    case paneAgentDetected(paneID: String, workspaceID: String, agent: String?, released: Bool)
    case paneAgentStatusChanged(paneID: String, workspaceID: String, status: AgentStatus, agent: String?)
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
                id: try data.decode(String.self, forKey: .workspaceID),
                label: try data.decode(String.self, forKey: .label)
            )
        case "workspace_closed":
            self = .workspaceClosed(id: try data.decode(String.self, forKey: .workspaceID))
        case "workspace_moved":
            self = .workspaceMoved(try data.decode([WorkspaceInfo].self, forKey: .workspaces))
        case "workspace_reordered":
            self = .workspaceReordered(try data.decode([WorkspaceInfo].self, forKey: .workspaces))
        case "workspace_focused":
            self = .workspaceFocused(id: try data.decode(String.self, forKey: .workspaceID))
        case "pane_created":
            self = .paneCreated(try data.decode(PaneInfo.self, forKey: .pane))
        case "pane_closed":
            self = .paneClosed(
                paneID: try data.decode(String.self, forKey: .paneID),
                workspaceID: try data.decode(String.self, forKey: .workspaceID)
            )
        case "pane_exited":
            self = .paneExited(
                paneID: try data.decode(String.self, forKey: .paneID),
                workspaceID: try data.decode(String.self, forKey: .workspaceID)
            )
        case "pane_agent_detected":
            self = .paneAgentDetected(
                paneID: try data.decode(String.self, forKey: .paneID),
                workspaceID: try data.decode(String.self, forKey: .workspaceID),
                agent: try data.decodeIfPresent(String.self, forKey: .agent),
                released: try data.decodeIfPresent(Bool.self, forKey: .released) ?? false
            )
        case "pane_agent_status_changed":
            self = .paneAgentStatusChanged(
                paneID: try data.decode(String.self, forKey: .paneID),
                workspaceID: try data.decode(String.self, forKey: .workspaceID),
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
/// the same connection. Modelling the ack as a `HerdrEvent` case would hide
/// that; keeping the two apart lets the client await the reply, throw on its
/// error, and then treat every following line as an event.
enum HerdrEventLine: Sendable {
    case response(HerdrResponse)
    case event(HerdrEvent)

    init(line: Data) throws {
        if try JSONDecoder().decode(Probe.self, from: line).event == nil {
            self = .response(try HerdrResponse(line: line))
        } else {
            self = .event(try JSONDecoder().decode(HerdrEvent.self, from: line))
        }
    }

    private struct Probe: Decodable {
        let event: String?
    }
}
