import Foundation
import os

/// One connected `AF_UNIX` stream socket, owned for the life of a single herdr
/// exchange (one request, or one events subscription).
///
/// Reading is a blocking `read(2)` loop on a thread of this connection's own,
/// published as an `AsyncThrowingStream` of NDJSON lines.
///
/// It used to be `FileHandle.bytes.lines`, the async-lines pattern
/// `Support/ProcessRunner.swift` uses for pipes, and that was wrong here:
/// Foundation drives every `AsyncBytes` iteration in a process through shared
/// machinery, so one reader parked in `read(2)` starves all the others. A pipe
/// is read to the end of a command and lets go; an events subscription is
/// parked for as long as its tab exists, which stalled the *next* herdr
/// request — and `ProcessRunner`'s pipes with it — for ever. A thread of its
/// own blocks nothing but itself. (`NWConnection`, the other option, would have
/// needed a `DispatchQueue` — against the project's Swift-Concurrency-only
/// rule — plus hand-rolled framing, which this now has anyway.)
///
/// Shutting down is deliberately two-phase. `shutdown(2)` ends a blocked read
/// with a clean EOF; only once the read loop has finished may the descriptor be
/// closed. Calling `close(2)` on a descriptor another thread is blocked in
/// throws `EBADF` and — worse — frees the number for immediate reuse, so
/// `close()` releases the descriptor itself only when no reader is running and
/// otherwise leaves that to the reader thread.
///
/// `@unchecked Sendable`: the descriptor's whole lifecycle is serialised by the
/// lock below, and the read buffer belongs to the one reader thread.
final class UnixSocketConnection: @unchecked Sendable {
    /// How the descriptor may still be used. Once it is released the number can
    /// be handed to an unrelated socket, so every syscall is gated on this to
    /// make a late `shutdown()` (from a stream's `onTermination`, say) a no-op
    /// instead of a wild write into someone else's connection.
    private struct Lifecycle {
        var isOpen = true
        /// A reader thread owns the descriptor and may be blocked in `read(2)`.
        var isReading = false
        /// A reader was handed out at some point. Sticky, unlike `isReading`:
        /// a connection carries exactly one exchange, so once its lines have
        /// been read to EOF there is nothing left for a second reader.
        var hasStartedReading = false
        /// `close()` came while a reader was running; the reader closes.
        var isCloseRequested = false
    }

    /// One `read(2)` at a time. Lines are single JSON objects and herdr's
    /// bursts are small, so this is comfortably more than one turn's worth.
    private static let readBufferSize = 16 * 1024

    let path: String

    private let descriptor: Int32
    /// An unfair lock, not an actor: these are three non-blocking syscalls that
    /// have to be callable from synchronous cancellation handlers.
    private let lifecycle = OSAllocatedUnfairLock(initialState: Lifecycle())

    /// Connects to `path`, or throws `PaddockError.herdrSocketUnavailable`
    /// when nothing is listening there (the session is not running, or only a
    /// stale socket file is left behind).
    init(path: String) throws {
        self.path = path

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.error(errno: errno, path: path) }

        // A write to a socket herdr has already closed must surface as EPIPE,
        // not as a SIGPIPE that kills the whole app.
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw PaddockError.herdrSocketUnavailable(path: path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Self.error(errno: code, path: path)
        }

        self.descriptor = descriptor
    }

    /// Starts the connection's one reader thread and returns the socket's
    /// newline-delimited lines.
    ///
    /// One per connection, enforced: a second call throws
    /// `PaddockError.herdrSocketAlreadyReading` — whether the first reader is
    /// still running or has already finished. Two concurrent readers would
    /// race for the same bytes and, worse, the first to finish would hand the
    /// descriptor back while the other was still blocked in `read(2)` on it,
    /// exactly the reuse hazard the lifecycle lock exists to prevent; a reader
    /// after EOF would read a connection herdr has already closed. A call on a
    /// closed connection throws `herdrSocketUnavailable`. Dropping the stream
    /// (or cancelling the task iterating it) shuts the socket down, which ends
    /// the thread with a clean EOF.
    func makeLines() throws -> AsyncThrowingStream<Data, Error> {
        // Claimed here, synchronously, rather than on the thread: a `close()`
        // in between would otherwise pull the descriptor out from under a
        // reader that has not started yet.
        try lifecycle.withLock { state in
            guard state.isOpen else { throw PaddockError.herdrSocketUnavailable(path: path) }
            guard !state.hasStartedReading else { throw PaddockError.herdrSocketAlreadyReading(path: path) }
            state.hasStartedReading = true
            state.isReading = true
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [self] _ in shutdown() }

            let thread = Thread { [self] in
                var pending = Data()
                do {
                    while let chunk = try readChunk() {
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                            continuation.yield(Data(pending[..<newline]))
                            pending = Data(pending[pending.index(after: newline)...])
                        }
                    }
                    // herdr terminates every line, but a last unterminated one
                    // is still a line and not worth losing.
                    if !pending.isEmpty { continuation.yield(pending) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                finishReading()
            }
            thread.name = "herdr-socket-reader"
            thread.stackSize = 256 * 1024
            thread.start()
        }
    }

    /// One blocking `read(2)`, or `nil` at end of stream — which is also what a
    /// `shutdown()` from another thread produces, so a torn-down connection
    /// ends its stream cleanly instead of throwing.
    ///
    /// Only the reader thread calls this, and `close()` never releases the
    /// descriptor while that thread runs, so it cannot read a reused number.
    private func readChunk() throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { return Data(buffer[0 ..< count]) }
            if count == 0 { return nil }
            let code = errno
            if code == EINTR { continue }
            throw Self.error(errno: code, path: path)
        }
    }

    /// Hands the descriptor back and honours a `close()` that arrived while the
    /// reader was running.
    private func finishReading() {
        let shouldClose = lifecycle.withLock { state -> Bool in
            state.isReading = false
            return state.isCloseRequested
        }
        guard shouldClose else { return }
        close()
    }

    /// Writes one already newline-terminated request line, looping over short
    /// writes and retrying `EINTR`. The descriptor is checked once rather than
    /// per iteration: a request is always written immediately after connecting,
    /// long before anything can shut the connection down, and holding the lock
    /// across `write(2)` would make `shutdown()` wait on a blocked socket.
    func writeLine(_ data: Data) throws {
        guard !data.isEmpty else { return }
        guard lifecycle.withLock({ $0.isOpen }) else {
            throw PaddockError.herdrSocketUnavailable(path: path)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base + written, buffer.count - written)
                if count < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw Self.error(errno: code, path: path)
                }
                written += count
            }
        }
    }

    /// Ends any blocked read with a clean EOF. Safe to call from a cancellation
    /// handler, more than once, or after `close()`.
    func shutdown() {
        lifecycle.withLock { state in
            guard state.isOpen else { return }
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    /// Ends the connection. Safe to call at any time and from any thread: while
    /// a reader thread is running the descriptor is only shut down, and the
    /// reader releases it when its loop ends a moment later.
    func close() {
        lifecycle.withLock { state in
            guard state.isOpen else { return }
            guard !state.isReading else {
                state.isCloseRequested = true
                _ = Darwin.shutdown(descriptor, SHUT_RDWR)
                return
            }
            state.isOpen = false
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            _ = Darwin.close(descriptor)
        }
    }

    /// Maps an `errno` onto Paddock's vocabulary: the codes that mean "no
    /// server on the other end" become `.herdrSocketUnavailable`, which the
    /// store reads as "session not running". That includes a stale socket file
    /// (`ECONNREFUSED`) and a path that is not a socket at all (`ENOTSOCK`).
    /// Anything else keeps its POSIX identity so an unexpected failure is not
    /// mistaken for a stopped session.
    static func error(errno code: Int32, path: String) -> Error {
        switch code {
        case ENOENT, ECONNREFUSED, ECONNRESET, EPIPE, ENOTCONN, ENOTDIR, ENOTSOCK, EACCES, EPERM:
            return PaddockError.herdrSocketUnavailable(path: path)
        default:
            return NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }
}
