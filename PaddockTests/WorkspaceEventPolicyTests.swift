import Foundation
import Testing
@testable import Paddock

/// The classifier is the whole event vocabulary now: an event either asks for
/// a snapshot or is ignored, and nothing reads its payload. So the suite is a
/// coverage check — every kind Paddock subscribes to must invalidate the rows,
/// and only `.other` must not.
struct WorkspaceEventPolicyTests {
    // MARK: - Fixtures

    private static func ws(_ id: String) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: id,
            number: 1,
            label: id.uppercased(),
            focused: false,
            paneCount: 1,
            tabCount: 1,
            activeTabID: "t-\(id)",
            agentStatus: .idle
        )
    }

    private static func pane(_ id: String, in workspaceID: String) -> PaneInfo {
        PaneInfo(paneID: id, workspaceID: workspaceID, tabID: "t-\(workspaceID)", agentStatus: .idle, focused: false)
    }

    /// One of every case Paddock subscribes to — `HerdrSubscription`'s
    /// workspace kinds, its pane kinds, and the per-pane status subscription.
    static let subscribedEvents: [HerdrEvent] = [
        .workspaceCreated(ws("w1")),
        .workspaceUpdated(ws("w1")),
        .workspaceRenamed(id: "w1", label: "renamed"),
        .workspaceClosed(id: "w1"),
        .workspaceMoved([ws("w2"), ws("w1")]),
        .workspaceReordered([ws("w1"), ws("w2")]),
        .workspaceFocused(id: "w1"),
        .paneCreated(pane("p1", in: "w1")),
        .paneClosed(paneID: "p1", workspaceID: "w1"),
        .paneExited(paneID: "p1", workspaceID: "w1"),
        .paneAgentDetected(paneID: "p1", workspaceID: "w1", agent: "claude", released: false),
        .paneAgentStatusChanged(paneID: "p1", workspaceID: "w1", status: .working, agent: "claude"),
    ]

    // MARK: - Effects

    @Test(arguments: WorkspaceEventPolicyTests.subscribedEvents)
    func everySubscribedKindAsksForASnapshot(event: HerdrEvent) {
        #expect(WorkspaceEventPolicy.effect(of: event) == .resync)
    }

    /// A kind nothing subscribed to cannot be about the rows, and answering it
    /// with a snapshot would let an unrelated chatty kind drive the request
    /// rate.
    @Test(arguments: ["session_renamed", "tab_focused", "something_herdr_0_9_adds"])
    func unsubscribedKindsAreIgnored(kind: String) {
        #expect(WorkspaceEventPolicy.effect(of: .other(kind: kind)) == .ignore)
    }

    /// The point of the classifier: what an event *says* never matters, so two
    /// events of the same kind carrying opposite content are indistinguishable
    /// to the store. This is what makes herdr's replayed backlog — whose
    /// payloads are stale by construction — harmless.
    @Test
    func theEffectIgnoresThePayload() {
        let stale = HerdrEvent.workspaceFocused(id: "w-closed-hours-ago")
        let live = HerdrEvent.workspaceFocused(id: "w1")
        #expect(WorkspaceEventPolicy.effect(of: stale) == WorkspaceEventPolicy.effect(of: live))
    }
}
