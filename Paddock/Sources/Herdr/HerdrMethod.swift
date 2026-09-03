import Foundation

/// The name of one herdr RPC method, as it goes on the wire.
///
/// A newtype rather than bare strings so that a method is spelled once, here,
/// and a typo is a compile error instead of an `invalid_request` reply at
/// runtime — the same treatment `HerdrSubscription` already gives the other
/// half of the wire vocabulary. A struct rather than an enum so a test can
/// still construct a method herdr does not know (`HerdrMethod(rawValue:)`) to
/// see how a rejection is reported.
struct HerdrMethod: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let ping = HerdrMethod(rawValue: "ping")
    static let sessionSnapshot = HerdrMethod(rawValue: "session.snapshot")
    static let workspaceList = HerdrMethod(rawValue: "workspace.list")
    /// Only the QA live test creates workspaces; Paddock itself never mutates one.
    static let workspaceCreate = HerdrMethod(rawValue: "workspace.create")
    static let eventsSubscribe = HerdrMethod(rawValue: "events.subscribe")

    var description: String { rawValue }
}
