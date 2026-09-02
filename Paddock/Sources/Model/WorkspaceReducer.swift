import Foundation

/// Applies one herdr stream event to a `WorkspaceListState`.
///
/// Pure and synchronous so the whole event vocabulary is testable without a
/// socket; the store owns the connection, the coalescing and the resync.
///
/// Two spike findings shape every rule here:
///
/// - **Subscribing replays a backlog.** After the ack herdr repeats historical
///   events, including `workspace_created` for workspaces that closed long ago.
///   So an event naming an id the state does not have is never trusted to
///   insert: it asks for a resync, and the `workspace.list` that follows brings
///   the truth. That costs one cheap request in the rare genuine-creation case
///   and removes a whole class of ghost rows.
/// - **Agent status only arrives per pane.** Workspace events never carry it,
///   so the pane map has to be maintained and `status(of:)` derives the row's
///   dot from it.
enum WorkspaceReducer {
    /// What the store must do after an event.
    ///
    /// An option set rather than an enum because "the rows changed" and "the
    /// pane set changed, resubscribe" happen together and are two different
    /// jobs: a render is cheap and coalesced, a resubscribe tears the events
    /// connection down and reopens it (herdr allows one request per
    /// connection, so subscriptions cannot be added incrementally).
    ///
    /// - `unchanged`: nothing to do — the empty set.
    /// - `changed`: re-render.
    /// - `panesChanged`: `[.changed, .resubscribe]`; re-render *and* reopen the
    ///   events connection with `state.paneIDs`.
    /// - `needsResync`: the state is missing something; run the debounced
    ///   `workspace.list` (and `pane.list`). May arrive combined with the others.
    struct Outcome: OptionSet, Sendable, CustomStringConvertible {
        let rawValue: Int

        init(rawValue: Int) {
            self.rawValue = rawValue
        }

        static let changed = Outcome(rawValue: 1 << 0)
        static let resubscribe = Outcome(rawValue: 1 << 1)
        static let needsResync = Outcome(rawValue: 1 << 2)

        static let unchanged: Outcome = []
        /// The pane set itself changed: render and resubscribe.
        static let panesChanged: Outcome = [.changed, .resubscribe]

        var description: String {
            if isEmpty { return "unchanged" }
            var parts: [String] = []
            if contains(.changed) { parts.append("changed") }
            if contains(.resubscribe) { parts.append("resubscribe") }
            if contains(.needsResync) { parts.append("needsResync") }
            return "[\(parts.joined(separator: ", "))]"
        }
    }

    static func apply(_ event: HerdrEvent, to state: inout WorkspaceListState) -> Outcome {
        switch event {
        // A creation for an id the state already has is a backlog replay of a
        // workspace that still exists: treat it as an update. An id the state
        // does not have is either a ghost or a genuinely new workspace, and
        // only `workspace.list` can tell the two apart.
        case let .workspaceCreated(info), let .workspaceUpdated(info):
            guard let index = state.index(of: info.workspaceID) else { return .needsResync }
            return replace(info, at: index, in: &state)

        case let .workspaceRenamed(id, label):
            guard let index = state.index(of: id) else { return .needsResync }
            guard state.workspaces[index].label != label else { return .unchanged }
            state.workspaces[index] = state.workspaces[index].with(label: label)
            return .changed

        case let .workspaceFocused(id):
            guard state.index(of: id) != nil else { return .needsResync }
            return focus(id, in: &state)

        // Both kinds ship the complete, newly ordered list, so the array is
        // replaced wholesale instead of replaying a move. A list whose id set
        // differs from the current one is a stale backlog replay (or a
        // creation/close this state has not seen yet); only `workspace.list`
        // can say which, so it must not overwrite what is known.
        case let .workspaceMoved(infos), let .workspaceReordered(infos):
            return reorder(to: infos, in: &state)

        // An unknown id here is a backlog replay of a close that already
        // happened: nothing to remove, nothing to resync.
        case let .workspaceClosed(id):
            guard let index = state.index(of: id) else { return .unchanged }
            state.workspaces.remove(at: index)
            let hadPanes = removePanes(ofWorkspace: id, in: &state)
            return hadPanes ? .panesChanged : .changed

        case let .paneCreated(pane):
            guard state.index(of: pane.workspaceID) != nil else { return .needsResync }
            return upsert(PaneSummary(pane), id: pane.paneID, in: &state)

        // herdr sends no `pane_closed` when a workspace closes, and sends both
        // `pane_exited` and `pane_closed` for a pane that dies, so removal has
        // to tolerate the pane already being gone.
        case let .paneClosed(paneID, _), let .paneExited(paneID, _):
            guard state.panes.removeValue(forKey: paneID) != nil else { return .unchanged }
            return .panesChanged

        // Paddock subscribes to *every* pane, not just panes running an agent:
        // the subscription list then depends on the pane set alone, so an agent
        // appearing or being released is a repaint and not a reconnect. A
        // release keeps the pane and clears what is known about it.
        case let .paneAgentDetected(paneID, workspaceID, agent, released):
            guard state.index(of: workspaceID) != nil else { return .needsResync }
            let known = state.panes[paneID]
            let summary = PaneSummary(
                workspaceID: workspaceID,
                agent: released ? nil : (agent ?? known?.agent),
                agentStatus: released ? .unknown : (known?.agentStatus ?? .unknown)
            )
            return upsert(summary, id: paneID, in: &state)

        // The only source of live status. The pane may be missing from a stale
        // pane list, so it is created here; the workspace, in contrast, has to
        // be known, or the row it would colour does not exist.
        case let .paneAgentStatusChanged(paneID, workspaceID, status, agent):
            guard state.index(of: workspaceID) != nil else { return .needsResync }
            let summary = PaneSummary(
                workspaceID: workspaceID,
                agent: agent ?? state.panes[paneID]?.agent,
                agentStatus: status
            )
            return upsert(summary, id: paneID, in: &state)

        // Kinds Paddock never subscribed to, and kinds a future herdr adds.
        case .other:
            return .unchanged
        }
    }

    // MARK: - Workspaces

    /// Replaces a row in place, keeping its position in herdr's order.
    ///
    /// The incoming `focused` flag is discarded in favour of the one already
    /// held: focus moves only on `workspace_focused` and on a full
    /// snapshot/list replacement, so a replayed backlog update cannot drag the
    /// pill onto a workspace the user is not in — and the "at most one focused
    /// row" invariant survives.
    private static func replace(_ info: WorkspaceInfo, at index: Int, in state: inout WorkspaceListState) -> Outcome {
        let merged = info.with(focused: state.workspaces[index].focused)
        guard merged != state.workspaces[index] else { return .unchanged }
        state.workspaces[index] = merged
        return .changed
    }

    private static func focus(_ id: String, in state: inout WorkspaceListState) -> Outcome {
        var outcome = Outcome.unchanged
        for index in state.workspaces.indices {
            let shouldFocus = state.workspaces[index].workspaceID == id
            guard state.workspaces[index].focused != shouldFocus else { continue }
            state.workspaces[index] = state.workspaces[index].with(focused: shouldFocus)
            outcome = .changed
        }
        return outcome
    }

    /// Replaces the whole ordered list and prunes the panes of workspaces that
    /// vanished from it — herdr guarantees no `pane_closed` for those.
    private static func reorder(to infos: [WorkspaceInfo], in state: inout WorkspaceListState) -> Outcome {
        guard Set(infos.map(\.workspaceID)) == Set(state.workspaces.map(\.workspaceID)) else {
            return .needsResync
        }
        guard state.workspaces != infos else { return .unchanged }
        state.workspaces = infos
        return .changed
    }

    // MARK: - Panes

    /// `panesChanged` only when a pane appears or disappears; editing a pane
    /// that is already subscribed is just a repaint.
    private static func upsert(_ summary: PaneSummary, id: String, in state: inout WorkspaceListState) -> Outcome {
        guard let existing = state.panes[id] else {
            state.panes[id] = summary
            return .panesChanged
        }
        guard existing != summary else { return .unchanged }
        state.panes[id] = summary
        return .changed
    }

    /// Returns whether anything was removed.
    private static func removePanes(ofWorkspace id: String, in state: inout WorkspaceListState) -> Bool {
        let doomed = state.panes.filter { $0.value.workspaceID == id }.keys
        guard !doomed.isEmpty else { return false }
        for paneID in doomed {
            state.panes.removeValue(forKey: paneID)
        }
        return true
    }
}
