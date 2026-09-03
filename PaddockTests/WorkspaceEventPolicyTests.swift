import Foundation
import Testing
@testable import Paddock

/// The classifier is the whole event vocabulary now: an event kind either asks
/// for a snapshot or is ignored, and there is no payload to read. So the suite
/// is a coverage check — every kind Paddock subscribes to must invalidate the
/// rows, and only kinds it never asked for must not.
struct WorkspaceEventPolicyTests {
    /// One of every subscription Paddock makes — `HerdrSubscription`'s
    /// workspace kinds, its pane kinds, and the per-pane status subscription.
    static let subscriptions: [HerdrSubscription] =
        HerdrSubscription.workspaceKinds
            + HerdrSubscription.paneKinds
            + [.paneAgentStatusChanged(paneID: "w4:p1")]

    // MARK: - Effects

    @Test(arguments: WorkspaceEventPolicyTests.subscriptions)
    func everySubscribedKindAsksForASnapshot(subscription: HerdrSubscription) {
        #expect(WorkspaceEventPolicy.effect(of: subscription.eventKind) == .resync)
    }

    /// herdr spells the same kind two ways on the wire; both must resync.
    @Test(arguments: [
        "workspace_created", "workspace.created",
        "workspace_metadata_updated", "workspace.metadata_updated",
        "pane_agent_status_changed", "pane.agent_status_changed",
    ])
    func bothWireSpellingsAreTheSameKind(wire: String) {
        #expect(WorkspaceEventPolicy.effect(of: HerdrEventKind(wire: wire)) == .resync)
    }

    /// A kind nothing subscribed to cannot be about the rows, and answering it
    /// with a snapshot would let an unrelated chatty kind drive the request
    /// rate.
    @Test(arguments: ["session_renamed", "tab_focused", "tab.created", "something_herdr_0_9_adds", ""])
    func unsubscribedKindsAreIgnored(wire: String) {
        #expect(WorkspaceEventPolicy.effect(of: HerdrEventKind(wire: wire)) == .ignore)
    }

    /// The resync set is *derived* from the subscription list, so adding a
    /// subscription cannot forget to add its kind.
    @Test func resyncKindsMatchTheSubscriptionsExactly() {
        #expect(WorkspaceEventPolicy.resyncKinds == Set(Self.subscriptions.map(\.eventKind)))
        #expect(WorkspaceEventPolicy.resyncKinds.count == 13)
    }
}
