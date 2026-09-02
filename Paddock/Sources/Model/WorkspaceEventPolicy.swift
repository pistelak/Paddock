import Foundation

/// What one herdr stream event means for the spaces column.
///
/// **An event is a signal that something may have changed, never a description
/// of what it changed to.** herdr replays an unmarked historical backlog after
/// every `events.subscribe` ack, paced at exactly one event per 100 ms —
/// measured 2026-09-02 against the live `default` session: 89
/// `workspace_focused` events over 9.1 s, inter-arrival gaps min/median/max
/// 0.10/0.10/0.11 s, the identical sequence on every fresh connection. Nothing
/// distinguishes a replayed event from a live one: the protocol carries no
/// cursor, no `seq`, no timestamp and no way to opt out of the replay (herdr
/// 0.8.0; `EventsSubscribeParams` has only `subscriptions`).
///
/// And a replayed event's *content* is stale — an old label, an old focus, a
/// pane that closed hours ago. Applying it walks the rows backwards through the
/// session's history: that is what marched the focused pill across the column
/// for the first ten seconds of every connection, and what once inserted panes
/// that no longer existed until the store resubscribed itself into an ~11k
/// stream loop.
///
/// So nothing here reads a payload. Every event Paddock subscribed to answers
/// one question — *might the world have moved?* — and `session.snapshot`, which
/// can only ever describe the present, answers *how*. A replayed event costs at
/// most one redundant snapshot; `WorkspaceListState` is `Equatable`, so a
/// snapshot that says nothing new is not even a render.
enum WorkspaceEventPolicy {
    /// What the store does about an event.
    enum Effect: Equatable, Sendable {
        /// Nothing the column draws depends on this kind.
        case ignore
        /// Refetch `session.snapshot` (debounced by the store).
        case resync
    }

    /// Every kind Paddock subscribes to invalidates the rows; nothing else can
    /// arrive, because a subscription is the only way an event reaches the
    /// stream at all.
    static func effect(of event: HerdrEvent) -> Effect {
        switch event {
        case .workspaceCreated, .workspaceUpdated, .workspaceRenamed, .workspaceClosed,
             .workspaceMoved, .workspaceReordered, .workspaceFocused,
             .paneCreated, .paneClosed, .paneExited,
             .paneAgentDetected, .paneAgentStatusChanged:
            .resync

        // A kind Paddock never subscribed to, or one a future herdr adds. It
        // cannot be about the rows, and a snapshot per unknown line would let
        // an unrelated chatty kind drive the request rate.
        case .other:
            .ignore
        }
    }
}
