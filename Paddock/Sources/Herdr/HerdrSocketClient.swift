import Foundation
import os

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
/// A plain value: there is nothing to serialise. Every call has a connection
/// of its own, and the request id herdr echoes back is never matched against
/// anything (see `HerdrResponse`), so `HerdrRequest`'s default id is enough.
struct HerdrSocketClient: HerdrTransport, Sendable {
    /// Matches herdrm's per-request budget. Long enough that a busy herdr
    /// still answers, short enough that a wedged session surfaces in the UI.
    static let requestTimeout: Duration = .seconds(15)

    private static let log = Logger(subsystem: "com.radekpistelak.Paddock", category: "herdr-socket")

    /// The socket this client is bound to.
    let socketPath: String

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
        _ method: HerdrMethod,
        params: some Encodable & Sendable
    ) async throws -> R {
        let line = try HerdrRequest(method: method, params: params).encodedLine()
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

    // MARK: - Events

    /// Subscribes to `subscriptions` on a long-lived connection and streams the
    /// *kinds* of the events that follow.
    ///
    /// Only kinds, never payloads: the store treats every event as "something
    /// may have moved" and refetches a snapshot (see `WorkspaceEventPolicy`),
    /// so decoding a payload could only ever *fail* — and a herdr that reshaped
    /// an event's payload would then silently freeze the indicator. Reading just
    /// the top-level `event` string cannot be broken that way.
    ///
    /// Returns only once herdr has acknowledged the subscription, so a rejected
    /// subscription throws here rather than deep inside the caller's `for try
    /// await` loop. Right after the ack herdr replays a backlog of historical
    /// events (34 on an idle session in the spike, including workspaces long
    /// since closed); they are passed through unchanged for the store to
    /// reconcile against a snapshot.
    ///
    /// The stream ends with `finish()` when herdr closes the connection, so a
    /// consumer sees a clean end of iteration rather than an error. Breaking
    /// out of the loop, cancelling the consuming task or dropping the stream
    /// all tear the connection down through `onTermination`.
    func events(_ subscriptions: [HerdrSubscription]) async throws -> AsyncThrowingStream<HerdrEventKind, Error> {
        let line = try HerdrRequest(
            method: .eventsSubscribe,
            params: EventsSubscribeParams(subscriptions)
        ).encodedLine()
        let connection = try UnixSocketConnection(path: socketPath)

        let (stream, events) = AsyncThrowingStream<HerdrEventKind, Error>.makeStream()
        // A one-shot channel for the ack instead of a `CheckedContinuation`:
        // finishing it twice is harmless, so the timeout below can give up on
        // the handshake without risking a continuation-misuse crash.
        let (acknowledgement, acked) = AsyncThrowingStream<Void, Error>.makeStream()

        // Unstructured on purpose: the read loop lives as long as the
        // subscription, which outlives this call by design. It is ended by
        // the stream's `onTermination` below, never leaked. `events(_:)` is
        // not isolated to anything, so there is no actor for the task to
        // inherit and nothing it could block.
        let socketPath = socketPath
        let reader = Task {
            var isAcknowledged = false
            var skippedLines = 0
            do {
                try connection.writeLine(line)
                for try await data in try connection.makeLines() {
                    guard !data.isEmpty else { continue }
                    if isAcknowledged {
                        // A line that is not an event after the ack — a stray
                        // reply, or JSON herdr never finished — is skipped,
                        // never fatal: the stream outlives whatever produced
                        // it. It is counted and logged so that a herdr change
                        // that makes *every* line unreadable is visible
                        // somewhere, instead of surfacing as an indicator that
                        // quietly stops updating. The line itself stays out
                        // of the log: it is whatever the daemon wrote, which
                        // can carry paths or prompt text.
                        if let kind = Self.decodeEventKind(data) {
                            events.yield(kind)
                        } else {
                            skippedLines += 1
                            Self.log.debug(
                                "skipped non-event line #\(skippedLines) (\(data.count) bytes) on \(socketPath, privacy: .private)"
                            )
                        }
                        continue
                    }
                    switch try HerdrEventLine(line: data) {
                    case let .response(response):
                        if let error = response.error {
                            throw PaddockError.herdrRPC(
                                method: .eventsSubscribe,
                                code: error.code,
                                message: error.message
                            )
                        }
                        isAcknowledged = true
                        acked.yield(())
                        acked.finish()
                    case let .event(kind):
                        // Not observed, but harmless: an event that beats the
                        // ack is delivered and the handshake keeps waiting.
                        events.yield(kind)
                    }
                }
                acked.finish(
                    throwing: isAcknowledged
                        ? nil
                        : PaddockError.herdrConnectionClosed(method: .eventsSubscribe)
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
            try await Self.withTimeout(method: .eventsSubscribe, interrupt: { connection.shutdown() }) {
                var iterator = acknowledgement.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    throw PaddockError.herdrConnectionClosed(method: .eventsSubscribe)
                }
            }
        } catch {
            events.finish(throwing: error)
            throw error
        }
        return stream
    }

    // MARK: - Line plumbing

    /// The kind of one stream line, or `nil` for a line that is not an event —
    /// malformed JSON, or a stray reply. Skipping keeps one bad line from
    /// ending a subscription. A known kind whose *payload* herdr has reshaped
    /// still decodes, because only the `event` field is read.
    static func decodeEventKind(_ line: Data) -> HerdrEventKind? {
        guard case let .event(kind) = try? HerdrEventLine(line: line) else { return nil }
        return kind
    }

    /// Reads the first non-empty line, or throws if herdr closes first.
    private static func firstLine(from connection: UnixSocketConnection, method: HerdrMethod) async throws -> Data {
        try await withTimeout(method: method, interrupt: { connection.shutdown() }) {
            for try await line in try connection.makeLines() where !line.isEmpty {
                return line
            }
            throw PaddockError.herdrConnectionClosed(method: method)
        }
    }

    /// `Timeout.race` with `requestTimeout` and herdr's error vocabulary: a
    /// blocked socket read ignores cancellation, so `interrupt` shuts the
    /// descriptor down for it to finish.
    private static func withTimeout<T: Sendable>(
        method: HerdrMethod,
        interrupt: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await Timeout.race(requestTimeout, interrupt: interrupt, operation: operation)
        } catch is Timeout.Expired {
            throw PaddockError.herdrTimeout(method: method)
        }
    }
}
