import Foundation

/// What `WorkspaceStore` needs from a herdr session: one-shot requests and a
/// subscription stream. `HerdrSocketClient` is the real one.
///
/// The seam exists so the store's connection machine — connect, subscribe,
/// snapshot, coalesce, retry, back off, resubscribe — can be driven through
/// every one of its transitions in milliseconds by a scripted peer and a
/// manual clock, instead of only against a live herdr with wall-clock waits.
/// It is a *transport* seam: a fake speaks herdr's protocol back, it does not
/// assert on how the store calls it.
protocol HerdrTransport: Sendable {
    /// Performs one request on a connection of its own and decodes the
    /// `result` as `R`. Throws `PaddockError.herdrRPC` for a server-side
    /// error reply.
    func request<R: Decodable & Sendable>(
        _ method: HerdrMethod,
        params: some Encodable & Sendable
    ) async throws -> R

    /// Subscribes and streams the kinds of the events that follow, returning
    /// once the subscription is acknowledged.
    func events(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEventKind, Error>
}

extension HerdrTransport {
    /// `request(_:params:)` for the many methods that take no parameters.
    /// herdr rejects a request without `params`, so `{}` still goes on the wire.
    func request<R: Decodable & Sendable>(_ method: HerdrMethod) async throws -> R {
        try await request(method, params: EmptyParams())
    }

    /// A mutation whose reply nothing reads: the column follows the events the
    /// mutation causes, never its response. Only the result's `type` tag is
    /// decoded, and even that is optional, so an enriched or reshaped reply
    /// cannot make a mutation that worked look like a failure.
    func send(_ method: HerdrMethod, params: some Encodable & Sendable) async throws {
        let _: HerdrResultTag = try await request(method, params: params)
    }
}
