import Foundation
import os

/// One connected `AF_UNIX` stream socket, owned for the life of a single herdr
/// exchange (one request, or one events subscription).
///
/// Reading goes through `FileHandle.bytes.lines`, the same buffered
/// async-lines pattern `Support/ProcessRunner.swift` uses for pipes: it gives
/// NDJSON framing for free and never busy-waits. `NWConnection` was the
/// alternative and would have needed a `DispatchQueue` (against the project's
/// Swift-Concurrency-only rule) plus hand-rolled framing.
///
/// Shutting down is deliberately two-phase. `shutdown(2)` ends a blocked read
/// with a clean EOF; only once the read loop has finished may the descriptor be
/// closed. Calling `close(2)` on a descriptor another thread is blocked in
/// throws `EBADF` and — worse — frees the number for immediate reuse, so
/// `close()` here is what the *reader* calls when its loop ends, and everyone
/// else calls `shutdown()`.
///
/// `@unchecked Sendable`: `FileHandle` is not `Sendable`, but this type only
/// ever hands it out as a fresh `bytes` sequence, and the descriptor's
/// lifecycle is serialised by the lock below.
final class UnixSocketConnection: @unchecked Sendable {
    /// How the descriptor may still be used. Once `close()` has run the number
    /// can be handed to an unrelated socket, so every syscall is gated on this
    /// to make a late `shutdown()` (from a stream's `onTermination`, say) a
    /// no-op instead of a wild write into someone else's connection.
    private struct Lifecycle {
        var isOpen = true
    }

    let path: String

    private let descriptor: Int32
    private let handle: FileHandle
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
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    }

    /// The socket's newline-delimited lines. Create this once per connection:
    /// each call starts a fresh buffered reader, so a second one would race the
    /// first for bytes.
    var lines: AsyncLineSequence<FileHandle.AsyncBytes> {
        handle.bytes.lines
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

    /// Releases the descriptor. Call this only once the read loop has ended.
    func close() {
        lifecycle.withLock { state in
            guard state.isOpen else { return }
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
