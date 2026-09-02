import Foundation
import Testing
@testable import Paddock

/// Fixtures are lines captured from herdr 0.8.0 (protocol 19) on a real
/// session: RPC replies from `session.snapshot` / `workspace.list` / `ping`
/// and stream lines from an `events.subscribe` connection. The few kinds the
/// spike never triggered (updated, moved, reordered, pane_closed, pane_exited)
/// are written from `herdr api schema --json` and marked as such.
struct HerdrProtocolTests {
    // MARK: - Requests

    @Test func requestAlwaysCarriesAnEmptyParamsObject() throws {
        let data = try HerdrRequest(id: "1", method: "session.snapshot").encodedLine()
        #expect(data.last == UInt8(ascii: "\n"))

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == "1")
        #expect(object["method"] as? String == "session.snapshot")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params.isEmpty)
    }

    @Test func requestEncodesTypedParams() throws {
        let request = HerdrRequest(
            id: "sub",
            method: "events.subscribe",
            params: EventsSubscribeParams([.workspaceFocused, .paneAgentStatusChanged(paneID: "w4:p1")])
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: try request.encodedLine()) as? [String: Any]
        )
        let params = try #require(object["params"] as? [String: Any])
        let subscriptions = try #require(params["subscriptions"] as? [[String: Any]])
        #expect(subscriptions.count == 2)
        #expect(subscriptions[0]["type"] as? String == "workspace.focused")
        #expect(subscriptions[0]["pane_id"] == nil)
        #expect(subscriptions[1]["type"] as? String == "pane.agent_status_changed")
        #expect(subscriptions[1]["pane_id"] as? String == "w4:p1")
    }

    @Test func workspaceKindsCoverTheEightWorkspaceSubscriptions() {
        #expect(HerdrSubscription.workspaceKinds.map(\.type) == [
            "workspace.created",
            "workspace.updated",
            "workspace.metadata_updated",
            "workspace.renamed",
            "workspace.moved",
            "workspace.reordered",
            "workspace.closed",
            "workspace.focused",
        ])
    }

    // MARK: - Responses

    @Test func decodesTypedResult() throws {
        let response = try HerdrResponse(line: Self.line(
            #"{"id":"cli","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w3","number":1,"label":"~","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"unknown"}]}}"#
        ))
        #expect(response.id == "cli")
        #expect(response.error == nil)

        let workspaces = try response.decodeResult(WorkspaceListResult.self).workspaces
        #expect(workspaces == [
            WorkspaceInfo(
                workspaceID: "w3",
                number: 1,
                label: "~",
                focused: true,
                paneCount: 1,
                tabCount: 1,
                activeTabID: "w3:t1",
                agentStatus: .unknown
            ),
        ])
    }

    @Test func decodesPong() throws {
        let response = try HerdrResponse(line: Self.line(
            #"{"id":"cli","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{"live_handoff":true,"detached_server_daemon":true}}}"#
        ))
        let pong = try response.decodeResult(PingResult.self)
        #expect(pong.version == "0.8.0")
        #expect(pong.protocolVersion == HerdrProtocol.supported)
        #expect(pong.capabilities["live_handoff"] == true)
    }

    @Test func pingResultSurvivesUnexpectedCapabilityShapes() throws {
        let response = try HerdrResponse(line: Self.line(
            #"{"id":"cli","result":{"type":"pong","version":"9.9.9","protocol":42,"capabilities":{"live_handoff":"maybe"}}}"#
        ))
        let pong = try response.decodeResult(PingResult.self)
        #expect(pong.protocolVersion == 42)
        #expect(pong.capabilities.isEmpty)
    }

    /// herdr answers a request it could not parse with an empty id, so the
    /// error has to survive an id that matches nothing.
    @Test func errorResponseWithEmptyIdentifier() throws {
        let response = try HerdrResponse(line: Self.line(
            #"{"id":"","error":{"code":"invalid_request","message":"invalid request: missing field `id` at line 1 column 17"}}"#
        ))
        #expect(response.id == "")
        #expect(response.error?.code == "invalid_request")
        #expect(response.error?.message.hasPrefix("invalid request:") == true)

        let error = #expect(throws: HerdrRPCError.self) {
            try response.decodeResult(PingResult.self)
        }
        #expect(error == response.error)
    }

    @Test func decodesSessionSnapshotFromTheNestedResult() throws {
        let response = try HerdrResponse(line: Self.line(Self.snapshotLine))
        let snapshot = try response.decodeResult(SessionSnapshotResult.self).snapshot

        #expect(snapshot.version == "0.8.0")
        #expect(snapshot.protocolVersion == 19)
        #expect(snapshot.focusedWorkspaceID == "w3")
        #expect(snapshot.workspaces.map(\.id) == ["w3"])
        #expect(snapshot.workspaces.first?.label == "~")
        #expect(snapshot.panes == [
            PaneInfo(
                paneID: "w3:p1",
                workspaceID: "w3",
                tabID: "w3:t1",
                agentStatus: .unknown,
                focused: true
            ),
        ])
    }

    // MARK: - Workspace payloads

    @Test func workspaceInfoWithTokensAndWorktree() throws {
        let workspace = try Self.decode(WorkspaceInfo.self, #"""
        {"workspace_id":"w7","number":3,"label":"api","focused":false,"pane_count":2,
         "tab_count":1,"active_tab_id":"w7:t1","agent_status":"working",
         "tokens":{"branch":"main"},
         "worktree":{"repo_key":"k","repo_name":"paddock","repo_root":"/src/paddock",
                     "checkout_path":"/src/paddock-api","is_linked_worktree":true}}
        """#)
        #expect(workspace.tokens == ["branch": "main"])
        #expect(workspace.worktree?.repoName == "paddock")
        #expect(workspace.worktree?.isLinkedWorktree == true)
        #expect(workspace.agentStatus == .working)
    }

    @Test func workspaceInfoWithoutTokensOrWorktree() throws {
        let workspace = try Self.decode(WorkspaceInfo.self, #"""
        {"workspace_id":"w3","number":1,"label":"~","focused":true,"pane_count":1,
         "tab_count":1,"active_tab_id":"w3:t1","agent_status":"idle"}
        """#)
        #expect(workspace.tokens == nil)
        #expect(workspace.worktree == nil)
        #expect(workspace.id == workspace.workspaceID)
    }

    /// A worktree Paddock does not understand must not take the workspace with
    /// it, so its fields decode leniently.
    @Test func workspaceInfoToleratesAPartialWorktree() throws {
        let workspace = try Self.decode(WorkspaceInfo.self, #"""
        {"workspace_id":"w3","number":1,"label":"~","focused":true,"pane_count":1,
         "tab_count":1,"active_tab_id":"w3:t1","agent_status":"idle",
         "worktree":{"repo_name":"paddock"}}
        """#)
        #expect(workspace.worktree?.repoName == "paddock")
        #expect(workspace.worktree?.checkoutPath == nil)
    }

    @Test func unknownAgentStatusDecodesAsUnknown() throws {
        let workspace = try Self.decode(WorkspaceInfo.self, #"""
        {"workspace_id":"w3","number":1,"label":"~","focused":true,"pane_count":1,
         "tab_count":1,"active_tab_id":"w3:t1","agent_status":"thinking_very_hard"}
        """#)
        #expect(workspace.agentStatus == .unknown)
        #expect(AgentStatus.allCases.count == 5)
    }

    // MARK: - Events (captured)

    @Test func decodesWorkspaceCreated() throws {
        let event = try Self.event(
            #"{"data":{"type":"workspace_created","workspace":{"active_tab_id":"w4:t1","agent_status":"unknown","focused":false,"label":"paddock-spike","number":2,"pane_count":1,"tab_count":1,"workspace_id":"w4"}},"event":"workspace_created"}"#
        )
        #expect(event == .workspaceCreated(WorkspaceInfo(
            workspaceID: "w4",
            number: 2,
            label: "paddock-spike",
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "w4:t1",
            agentStatus: .unknown
        )))
    }

    @Test func decodesWorkspaceRenamed() throws {
        let event = try Self.event(
            #"{"data":{"label":"paddock-spike-2","type":"workspace_renamed","workspace_id":"w4"},"event":"workspace_renamed"}"#
        )
        #expect(event == .workspaceRenamed(id: "w4", label: "paddock-spike-2"))
    }

    @Test func decodesWorkspaceClosed() throws {
        let event = try Self.event(
            #"{"data":{"type":"workspace_closed","workspace":{"active_tab_id":"w4:t1","agent_status":"unknown","focused":false,"label":"paddock-spike-2","number":2,"pane_count":1,"tab_count":1,"workspace_id":"w4"},"workspace_id":"w4"},"event":"workspace_closed"}"#
        )
        #expect(event == .workspaceClosed(id: "w4"))
    }

    @Test func decodesPaneCreated() throws {
        let event = try Self.event(
            #"{"data":{"pane":{"agent_status":"unknown","cwd":"/Users/me","focused":false,"foreground_cwd":"/Users/me","pane_id":"w4:p1","revision":0,"scroll":{"max_offset_from_bottom":0,"offset_from_bottom":0,"viewport_rows":23},"tab_id":"w4:t1","terminal_id":"term_65a822cd140ec2","workspace_id":"w4"},"type":"pane_created"},"event":"pane_created"}"#
        )
        #expect(event == .paneCreated(PaneInfo(
            paneID: "w4:p1",
            workspaceID: "w4",
            tabID: "w4:t1",
            agentStatus: .unknown,
            focused: false
        )))
    }

    @Test func decodesPaneAgentDetectedAndReleased() throws {
        let detected = try Self.event(
            #"{"data":{"agent":"spikebot","pane_id":"w4:p1","type":"pane_agent_detected","workspace_id":"w4"},"event":"pane_agent_detected"}"#
        )
        #expect(detected == .paneAgentDetected(paneID: "w4:p1", workspaceID: "w4", agent: "spikebot", released: false))

        let released = try Self.event(
            #"{"data":{"agent":"spikebot","final_status":"unknown","pane_id":"w4:p1","released":true,"type":"pane_agent_detected","workspace_id":"w4"},"event":"pane_agent_detected"}"#
        )
        #expect(released == .paneAgentDetected(paneID: "w4:p1", workspaceID: "w4", agent: "spikebot", released: true))
    }

    /// The only envelope that arrives under its dotted subscription name and
    /// puts its fields straight into `data`.
    @Test func decodesPaneAgentStatusChangedFromASubscriptionEnvelope() throws {
        let event = try Self.event(
            #"{"data":{"agent":"spikebot","agent_status":"blocked","pane_id":"w4:p1","workspace_id":"w4"},"event":"pane.agent_status_changed"}"#
        )
        #expect(event == .paneAgentStatusChanged(
            paneID: "w4:p1",
            workspaceID: "w4",
            status: .blocked,
            agent: "spikebot"
        ))
    }

    @Test func decodesPaneAgentStatusChangedFromAGlobalEnvelope() throws {
        let event = try Self.event(
            #"{"data":{"agent_status":"working","pane_id":"w4:p1","type":"pane_agent_status_changed","workspace_id":"w4"},"event":"pane_agent_status_changed"}"#
        )
        #expect(event == .paneAgentStatusChanged(
            paneID: "w4:p1",
            workspaceID: "w4",
            status: .working,
            agent: nil
        ))
    }

    // MARK: - Events (schema-derived)

    @Test func decodesWorkspaceUpdatedAndMetadataUpdatedAsTheSameCase() throws {
        let workspace = #"{"workspace_id":"w3","number":1,"label":"~","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w3:t1","agent_status":"done"}"#
        let updated = try Self.event(
            #"{"event":"workspace_updated","data":{"type":"workspace_updated","workspace":\#(workspace)}}"#
        )
        let metadata = try Self.event(
            #"{"event":"workspace_metadata_updated","data":{"type":"workspace_metadata_updated","workspace":\#(workspace)}}"#
        )
        #expect(updated == metadata)
        guard case let .workspaceUpdated(info) = updated else {
            Issue.record("expected .workspaceUpdated")
            return
        }
        #expect(info.agentStatus == .done)
    }

    @Test func decodesWorkspaceMovedAndReorderedWithTheFullList() throws {
        let workspaces = #"[{"workspace_id":"w1","number":1,"label":"a","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"idle"},{"workspace_id":"w2","number":2,"label":"b","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"w2:t1","agent_status":"idle"}]"#
        let moved = try Self.event(
            #"{"event":"workspace_moved","data":{"type":"workspace_moved","workspace_id":"w2","insert_index":1,"workspaces":\#(workspaces)}}"#
        )
        guard case let .workspaceMoved(list) = moved else {
            Issue.record("expected .workspaceMoved")
            return
        }
        #expect(list.map(\.id) == ["w1", "w2"])

        let reordered = try Self.event(
            #"{"event":"workspace_reordered","data":{"type":"workspace_reordered","workspace_ids":["w1","w2"],"workspaces":\#(workspaces)}}"#
        )
        guard case let .workspaceReordered(list) = reordered else {
            Issue.record("expected .workspaceReordered")
            return
        }
        #expect(list.map(\.id) == ["w1", "w2"])
    }

    @Test func decodesWorkspaceFocused() throws {
        let event = try Self.event(
            #"{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w3"}}"#
        )
        #expect(event == .workspaceFocused(id: "w3"))
    }

    @Test func decodesPaneClosedAndExited() throws {
        let closed = try Self.event(
            #"{"event":"pane_closed","data":{"type":"pane_closed","pane_id":"w4:p1","workspace_id":"w4"}}"#
        )
        #expect(closed == .paneClosed(paneID: "w4:p1", workspaceID: "w4"))

        let exited = try Self.event(
            #"{"event":"pane_exited","data":{"type":"pane_exited","pane_id":"w4:p1","workspace_id":"w4"}}"#
        )
        #expect(exited == .paneExited(paneID: "w4:p1", workspaceID: "w4"))
    }

    // MARK: - Unknown events and stream lines

    @Test func unknownEventKindBecomesOther() throws {
        let event = try Self.event(
            #"{"data":{"tab":{"tab_id":"w4:t1","workspace_id":"w4"},"type":"tab_created"},"event":"tab_created"}"#
        )
        #expect(event == .other(kind: "tab_created"))
    }

    @Test func eventWithANonObjectPayloadBecomesOther() throws {
        let event = try Self.event(#"{"event":"workspace_focused","data":"gone"}"#)
        #expect(event == .other(kind: "workspace_focused"))
    }

    @Test func subscribeAcknowledgementIsAResponseNotAnEvent() throws {
        let ack = try HerdrEventLine(line: Self.line(
            #"{"id":"sub","result":{"type":"subscription_started"}}"#
        ))
        guard case let .response(response) = ack else {
            Issue.record("expected .response")
            return
        }
        #expect(response.id == "sub")
        #expect(response.error == nil)

        let rejected = try HerdrEventLine(line: Self.line(
            #"{"id":"","error":{"code":"invalid_request","message":"unknown variant `pane.nope`"}}"#
        ))
        guard case let .response(failure) = rejected else {
            Issue.record("expected .response")
            return
        }
        #expect(failure.error?.code == "invalid_request")

        let streamed = try HerdrEventLine(line: Self.line(
            #"{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w3"}}"#
        ))
        guard case let .event(event) = streamed else {
            Issue.record("expected .event")
            return
        }
        #expect(event == .workspaceFocused(id: "w3"))
    }

    // MARK: - Helpers

    private static func line(_ json: String) -> Data {
        Data(json.utf8)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: line(json))
    }

    private static func event(_ json: String) throws -> HerdrEvent {
        try decode(HerdrEvent.self, json)
    }

    /// A `session.snapshot` reply captured verbatim, reformatted for reading.
    /// `tabs`, `layouts` and `agents` are deliberately left in: they are the
    /// proof that unmodelled members do not break decoding.
    private static let snapshotLine = """
    {
      "id": "cli",
      "result": {
        "type": "session_snapshot",
        "snapshot": {
          "version": "0.8.0",
          "protocol": 19,
          "focused_workspace_id": "w3",
          "focused_tab_id": "w3:t1",
          "focused_pane_id": "w3:p1",
          "workspaces": [
            {
              "workspace_id": "w3", "number": 1, "label": "~", "focused": true,
              "pane_count": 1, "tab_count": 1, "active_tab_id": "w3:t1",
              "agent_status": "unknown"
            }
          ],
          "tabs": [
            {
              "tab_id": "w3:t1", "workspace_id": "w3", "number": 1, "label": "1",
              "focused": true, "pane_count": 1, "agent_status": "unknown"
            }
          ],
          "panes": [
            {
              "pane_id": "w3:p1", "terminal_id": "term_65a8078a2d2181",
              "workspace_id": "w3", "tab_id": "w3:t1", "focused": true,
              "cwd": "/Users/me", "foreground_cwd": "/Users/me",
              "agent_status": "unknown",
              "scroll": {
                "offset_from_bottom": 0, "max_offset_from_bottom": 0, "viewport_rows": 62
              },
              "revision": 0
            }
          ],
          "layouts": [
            {
              "workspace_id": "w3", "tab_id": "w3:t1", "zoomed": false,
              "area": { "x": 36, "y": 1, "width": 44, "height": 23 },
              "focused_pane_id": "w3:p1",
              "panes": [
                { "pane_id": "w3:p1", "focused": true,
                  "rect": { "x": 36, "y": 1, "width": 44, "height": 23 } }
              ],
              "splits": []
            }
          ],
          "agents": []
        }
      }
    }
    """
}
