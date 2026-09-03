import Foundation
import os
import Testing
@testable import Paddock

/// A herdr that answers from a script.
///
/// A *transport* fake, not a mock: it speaks herdr's protocol back — queued
/// replies per method, subscriptions that are acknowledged or rejected, an
/// event stream the test pushes kinds into or ends — and records what it was
/// asked, so a test can drive `WorkspaceStore` through connect, snapshot,
/// coalesce, retry, resubscribe and reconnect in milliseconds. Replies are
/// JSON, decoded exactly as the socket client would decode a real line, so
/// the store's decoding path is exercised, not bypassed.
actor ScriptedHerdr: HerdrTransport {
    struct NoScriptedReply: Error {
        let method: HerdrMethod
    }

    /// What one `events.subscribe` does: succeed, or fail with an RPC error.
    enum SubscribeOutcome: Sendable {
        case accept
        case reject(code: String, message: String = "rejected")
    }

    private var replies: [HerdrMethod: [Result<Data, any Error>]] = [:]
    private var defaults: [HerdrMethod: Data] = [:]
    private var subscribeOutcomes: [SubscribeOutcome] = []

    private(set) var requests: [HerdrMethod] = []
    private(set) var subscriptions: [[HerdrSubscription]] = []
    private var streams: [UUID: AsyncThrowingStream<HerdrEventKind, Error>.Continuation] = [:]

    /// Methods whose replies are held back until `release(_:)`, so a test can
    /// put a request deliberately "in flight" and act while it is.
    private var gates: [HerdrMethod: Gate] = [:]

    init() {}

    // MARK: - Scripting

    /// Queues one reply for `method`; consumed in order. Falls back to the
    /// default reply for that method when the queue is empty.
    func reply(to method: HerdrMethod, with json: String) {
        replies[method, default: []].append(.success(Data(json.utf8)))
    }

    func fail(_ method: HerdrMethod, with error: any Error) {
        replies[method, default: []].append(.failure(error))
    }

    /// The reply for `method` whenever nothing is queued.
    func alwaysReply(to method: HerdrMethod, with json: String) {
        defaults[method] = Data(json.utf8)
    }

    /// Queues what the next `events.subscribe` does; `.accept` by default.
    func onSubscribe(_ outcome: SubscribeOutcome) {
        subscribeOutcomes.append(outcome)
    }

    /// Holds every request for `method` until `release(_:)`: the request is
    /// recorded at once (so a test can wait for it to arrive) but does not
    /// answer, which is how a snapshot is kept in flight on purpose.
    func gate(_ method: HerdrMethod) {
        gates[method] = Gate()
    }

    /// Answers everything held for `method` and stops holding new ones.
    func release(_ method: HerdrMethod) {
        gates.removeValue(forKey: method)?.releaseAll()
    }

    var heldRequestCount: Int {
        gates.values.reduce(0) { $0 + $1.heldCount }
    }

    /// A cancellation-aware turnstile for held requests. Lock-backed rather
    /// than actor state because a cancellation handler is synchronous and
    /// cannot hop to the actor; a cancelled holder is removed and resumed
    /// throwing, so a store stopped mid-request never leaves a task parked
    /// here.
    private final class Gate: Sendable {
        private struct State {
            var nextID = 0
            var held: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
            var isOpen = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        var heldCount: Int { state.withLock { $0.held.count } }

        func hold() async throws {
            let id = state.withLock { state -> Int in
                state.nextID += 1
                return state.nextID
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.isOpen { return true }
                        state.held.append((id, continuation))
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let parked = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                    guard let index = state.held.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.held.remove(at: index).continuation
                }
                parked?.resume(throwing: CancellationError())
            }
        }

        func releaseAll() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
                state.isOpen = true
                defer { state.held.removeAll() }
                return state.held.map(\.continuation)
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    // MARK: - Driving the stream

    /// Pushes one event kind into every open stream.
    func emit(_ wire: String) {
        for stream in streams.values {
            stream.yield(HerdrEventKind(wire: wire))
        }
    }

    /// herdr closed the socket: every open stream ends cleanly.
    func endStreams() {
        for stream in streams.values {
            stream.finish()
        }
        streams.removeAll()
    }

    var openStreamCount: Int { streams.count }

    func requestCount(of method: HerdrMethod) -> Int {
        requests.filter { $0 == method }.count
    }

    // MARK: - HerdrTransport

    func request<R: Decodable & Sendable>(
        _ method: HerdrMethod,
        params: some Encodable & Sendable
    ) async throws -> R {
        requests.append(method)
        if let gate = gates[method] {
            try await gate.hold()
        }
        let data: Data
        if var queue = replies[method], !queue.isEmpty {
            let next = queue.removeFirst()
            replies[method] = queue
            data = try next.get()
        } else if let fallback = defaults[method] {
            data = fallback
        } else {
            throw NoScriptedReply(method: method)
        }
        // Through `HerdrResponse`, exactly as the socket client does it, so
        // the envelope and the server-error mapping are the real ones.
        do {
            return try HerdrResponse(line: data).decodeResult()
        } catch let error as HerdrRPCError {
            throw PaddockError.herdrRPC(method: method, code: error.code, message: error.message)
        }
    }

    func events(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEventKind, Error> {
        self.subscriptions.append(subscriptions)
        let outcome = subscribeOutcomes.isEmpty ? .accept : subscribeOutcomes.removeFirst()
        if case let .reject(code, message) = outcome {
            throw PaddockError.herdrRPC(method: .eventsSubscribe, code: code, message: message)
        }
        let (stream, continuation) = AsyncThrowingStream<HerdrEventKind, Error>.makeStream()
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            // A stream the store dropped is no longer anyone to emit to.
            Task { await self?.forget(id) }
        }
        streams[id] = continuation
        return stream
    }

    private func forget(_ id: UUID) {
        streams[id] = nil
    }
}

// MARK: - Fixtures

extension ScriptedHerdr {
    static let pong = #"{"id":"1","result":{"type":"pong","version":"0.8.0","protocol":19,"capabilities":{}}}"#
    static let pongOtherProtocol = #"{"id":"1","result":{"type":"pong","version":"9.0.0","protocol":42,"capabilities":{}}}"#
    static let ok = #"{"id":"1","result":{"type":"ok"}}"#

    /// A `session.snapshot` reply with the given workspaces and panes.
    static func snapshot(
        workspaces: [(id: String, number: Int, label: String, focused: Bool)],
        panes: [(id: String, workspace: String, status: String)] = []
    ) -> String {
        let ws = workspaces.map {
            #"{"workspace_id":"\#($0.id)","number":\#($0.number),"label":"\#($0.label)","focused":\#($0.focused),"agent_status":"unknown"}"#
        }.joined(separator: ",")
        let ps = panes.map {
            #"{"pane_id":"\#($0.id)","workspace_id":"\#($0.workspace)","agent_status":"\#($0.status)"}"#
        }.joined(separator: ",")
        return #"{"id":"1","result":{"type":"session_snapshot","snapshot":{"workspaces":[\#(ws)],"panes":[\#(ps)]}}}"#
    }

    /// The store scripted to connect cleanly: pong, accept, one workspace.
    static func connectable(clock: ManualClock) async throws -> (ScriptedHerdr, WorkspaceStore) {
        let herdr = ScriptedHerdr()
        await herdr.alwaysReply(to: .ping, with: pong)
        await herdr.alwaysReply(to: .sessionSnapshot, with: snapshot(workspaces: [("w1", 1, "code", true)]))
        let store = await WorkspaceStore(
            sessionName: try SessionName("scripted"),
            socketPath: "/nonexistent/scripted.sock",
            transport: herdr,
            clock: clock
        )
        return (herdr, store)
    }
}
