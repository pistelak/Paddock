import Foundation

/// Talks to one herdr session over its Unix socket.
///
/// herdr answers **exactly one request per connection**: a second line written
/// to a connection that has already been answered (or subscribed) gets no
/// reply and the server drops the socket. So `request(_:params:)` opens a
/// connection, writes one line, reads one line and closes, while `events(_:)`
/// keeps a connection of its own for the whole subscription. That also means a
/// subscription list cannot be extended in place — the caller tears the stream
/// down and asks for a new one with the full list.
///
/// The actor exists to serialise request-id minting, not the I/O: every call
/// suspends on its own connection, so a long-lived event stream never keeps
/// `request(_:params:)` waiting.
actor HerdrSocketClient {
    /// Matches herdrm's per-request budget. Long enough that a busy herdr
    /// still answers, short enough that a wedged session surfaces in the UI.
    static let requestTimeout: Duration = .seconds(15)

    private static let subscribeMethod = "events.subscribe"

    /// The socket this client is bound to. `nonisolated` so a caller can name
    /// it in an error or a log line without awaiting the actor.
    nonisolated let socketPath: String

    private var requestCount = 0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: - Requests

    /// Performs one request on a connection of its own.
    ///
    /// Throws `PaddockError.herdrSocketUnavailable` when the session is not
    /// running, `.herdrRPC` for a server-side error reply, `.herdrTimeout` if
    /// no line arrives within `requestTimeout`, `.herdrConnectionClosed` if
    /// herdr hangs up without answering, and a `DecodingError` if the reply
    /// does not fit `R`.
    func request<R: Decodable & Sendable>(
        _ method: String,
        params: some Encodable & Sendable
    ) async throws -> R {
        let line = try HerdrRequest(id: nextRequestID(), method: method, params: params).encodedLine()
        let connection = try UnixSocketConnection(path: socketPath)
        defer { connection.close() }

        try connection.writeLine(line)
        let reply = try await Self.firstLine(from: connection, method: method)
        let response = try HerdrResponse(line: reply)
        do {
            return try response.decodeResult()
        } catch let error as HerdrRPCError {
            throw PaddockError.herdrRPC(method: method, code: error.code, message: error.message)
        }
    }

    /// `request(_:params:)` for the many methods that take no parameters.
    /// herdr rejects a request without `params`, so `{}` still goes on the wire.
    func request<R: Decodable & Sendable>(_ method: String) async throws -> R {
        try await request(method, params: EmptyParams())
    }

    // MARK: - Events

    /// Subscribes to `subscriptions` on a long-lived connection and streams the
    /// events that follow.
    ///
    /// Returns only once herdr has acknowledged the subscription, so a rejected
    /// subscription throws here rather than deep inside the caller's `for try
    /// await` loop. Right after the ack herdr replays a backlog of historical
    /// events (34 on an idle session in the spike, including workspaces long
    /// since closed); they are passed through unchanged for the reducer to
    /// reconcile against a snapshot.
    ///
    /// The stream ends with `finish()` when herdr closes the connection, so a
    /// consumer sees a clean end of iteration rather than an error. Breaking
    /// out of the loop, cancelling the consuming task or dropping the stream
    /// all tear the connection down through `onTermination`.
    func events(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEvent, Error> {
        let line = try HerdrRequest(
            id: nextRequestID(),
            method: Self.subscribeMethod,
            params: EventsSubscribeParams(subscriptions)
        ).encodedLine()
        let connection = try UnixSocketConnection(path: socketPath)

        let (stream, events) = AsyncThrowingStream<HerdrEvent, Error>.makeStream()
        // A one-shot channel for the ack instead of a `CheckedContinuation`:
        // finishing it twice is harmless, so the timeout below can give up on
        // the handshake without risking a continuation-misuse crash.
        let (acknowledgement, acked) = AsyncThrowingStream<Void, Error>.makeStream()

        // Detached on purpose: a `Task {}` here would inherit this actor's
        // isolation and run the whole long-lived read loop on the actor,
        // where it would sit between every `request(_:)` call. The loop
        // touches nothing but the connection and the two continuations.
        let reader = Task.detached {
            var isAcknowledged = false
            do {
                try connection.writeLine(line)
                for try await data in connection.lines {
                    guard !data.isEmpty else { continue }
                    if isAcknowledged {
                        // A malformed line after the ack is skipped, never
                        // fatal: the stream outlives whatever produced it.
                        if let event = Self.decodeEvent(data) { events.yield(event) }
                        continue
                    }
                    switch try HerdrEventLine(line: data) {
                    case let .response(response):
                        if let error = response.error {
                            throw PaddockError.herdrRPC(
                                method: Self.subscribeMethod,
                                code: error.code,
                                message: error.message
                            )
                        }
                        isAcknowledged = true
                        acked.yield(())
                        acked.finish()
                    case let .event(event):
                        // Not observed, but harmless: an event that beats the
                        // ack is delivered and the handshake keeps waiting.
                        events.yield(event)
                    }
                }
                acked.finish(
                    throwing: isAcknowledged
                        ? nil
                        : PaddockError.herdrConnectionClosed(method: Self.subscribeMethod)
                )
                events.finish()
            } catch {
                acked.finish(throwing: error)
                events.finish(throwing: error)
            }
            // The loop has ended, so the descriptor is nobody's any more.
            connection.close()
        }

        events.onTermination = { _ in
            // `shutdown` first: cancellation alone cannot interrupt a blocked
            // read, but a half-closed socket ends it with a clean EOF, and the
            // reader then closes the descriptor itself.
            connection.shutdown()
            reader.cancel()
        }

        do {
            try await Self.withTimeout(method: Self.subscribeMethod, interrupt: { connection.shutdown() }) {
                var iterator = acknowledgement.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    throw PaddockError.herdrConnectionClosed(method: Self.subscribeMethod)
                }
            }
        } catch {
            events.finish(throwing: error)
            throw error
        }
        return stream
    }

    // MARK: - Line plumbing

    /// Decodes one stream line, or `nil` for a line that is not an event —
    /// malformed JSON, or a stray reply. Skipping keeps one bad line from
    /// ending a subscription; unknown *kinds* never get here, `HerdrEvent`
    /// already folds those into `.other`.
    static func decodeEvent(_ line: Data) -> HerdrEvent? {
        guard case let .event(event) = try? HerdrEventLine(line: line) else { return nil }
        return event
    }

    /// Reads the first non-empty line, or throws if herdr closes first.
    private static func firstLine(from connection: UnixSocketConnection, method: String) async throws -> Data {
        try await withTimeout(method: method, interrupt: { connection.shutdown() }) {
            for try await line in connection.lines where !line.isEmpty {
                return line
            }
            throw PaddockError.herdrConnectionClosed(method: method)
        }
    }

    /// Races `operation` against `requestTimeout`, running `interrupt` on
    /// timeout or on cancellation of the calling task — a blocked socket read
    /// ignores cancellation, so something has to shut the descriptor down for
    /// it to finish.
    private static func withTimeout<T: Sendable>(
        method: String,
        interrupt: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: TimedOutcome<T>.self) { group in
                group.addTask { .value(try await operation()) }
                group.addTask {
                    // `try?` around the sleep would swallow cancellation and
                    // interrupt a perfectly healthy connection.
                    do { try await Task.sleep(for: requestTimeout) } catch { return .cancelled }
                    guard !Task.isCancelled else { return .cancelled }
                    interrupt()
                    return .timedOut
                }
                defer { group.cancelAll() }

                while let outcome = try await group.next() {
                    switch outcome {
                    case let .value(value): return value
                    case .timedOut: throw PaddockError.herdrTimeout(method: method)
                    case .cancelled: continue
                    }
                }
                throw CancellationError()
            }
        } onCancel: {
            interrupt()
        }
    }

    /// Which arm of the `withTimeout` race finished first.
    private enum TimedOutcome<Value: Sendable>: Sendable {
        case value(Value)
        case timedOut
        case cancelled
    }

    /// herdr echoes the id back but never matches it against anything, and a
    /// connection only ever carries one request, so a counter is enough.
    private func nextRequestID() -> String {
        requestCount += 1
        return String(requestCount)
    }
}
