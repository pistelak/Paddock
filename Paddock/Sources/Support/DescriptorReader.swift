import Foundation
import os

/// Reads a file descriptor to end of file on a thread of its own.
///
/// The alternative, `FileHandle.bytes`, is not usable in this process: every
/// `AsyncBytes` iteration is driven by shared Foundation machinery, so one
/// reader parked in `read(2)` starves all the others (`UnixSocketConnection`
/// carries the full story). Two pipes of one subprocess have to be drained
/// *concurrently* — a child that fills stderr while we wait on stdout would
/// otherwise deadlock — which is exactly the shape that breaks.
///
/// A thread per descriptor blocks nothing but itself. The threads are
/// short-lived (they end with the pipe, which ends with the child) and there
/// are two per `ProcessRunner.run`, which the app calls a handful of times.
///
/// **The read can be given up on.** EOF only arrives when the *last* writer
/// closes the pipe, and a child that was terminated may have left a grandchild
/// holding it — a login shell's version manager, a backgrounded helper. So
/// the loop waits in `poll(2)` in short slices and checks an `Interrupt`
/// between them; once triggered it returns what it has instead of waiting on
/// a writer that may never go away. That is what makes `ProcessRunner`'s
/// timeout an actual bound.
///
/// `UnixSocketConnection` keeps its own loop rather than calling this: it
/// frames NDJSON, is torn down from cancellation handlers and has a descriptor
/// lifecycle to guard. Sharing would mean pushing all of that in here.
enum DescriptorReader {
    /// One `read(2)`'s worth. Pipe buffers are 64 KiB on macOS.
    private static let bufferSize = 64 * 1024

    /// How long one `poll(2)` waits before the loop looks at the interrupt.
    /// Short enough that giving up feels immediate; long enough that an idle
    /// child costs nothing measurable.
    private static let pollSlice: Int32 = 50

    /// A one-way flag a reader checks between polls. Trigger it from any
    /// thread — a cancellation handler, a timeout — and every reader holding
    /// it returns at its next slice.
    final class Interrupt: Sendable {
        private let triggered = OSAllocatedUnfairLock(initialState: false)

        init() {}

        func trigger() {
            triggered.withLock { $0 = true }
        }

        var isTriggered: Bool {
            triggered.withLock { $0 }
        }
    }

    /// Everything the descriptor produces until EOF, or until `interrupt` is
    /// triggered — in which case whatever arrived so far.
    ///
    /// Reads the descriptor `handle` owns rather than the handle itself, and
    /// leaves closing to the caller: the `FileHandle` must outlive the read,
    /// and it is the caller who knows when that is.
    static func readToEnd(_ handle: FileHandle, interrupt: Interrupt? = nil) async throws -> Data {
        let descriptor = handle.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try readToEnd(descriptor: descriptor, interrupt: interrupt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "paddock-pipe-reader"
            thread.stackSize = 256 * 1024
            thread.start()
        }
    }

    /// The blocking loop itself: wait for readable in slices, read, repeat;
    /// stop at EOF, on an error other than `EINTR`, or when interrupted.
    private static func readToEnd(descriptor: Int32, interrupt: Interrupt?) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var descriptors = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)]
        while true {
            if interrupt?.isTriggered == true { return output }
            let ready = poll(&descriptors, 1, pollSlice)
            if ready < 0 {
                let code = errno
                if code == EINTR { continue }
                throw posixError(code)
            }
            if ready == 0 { continue }
            // Readable, or hung up: either way `read` answers without blocking
            // — with bytes, or with 0 for EOF.
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { return output }
            if count > 0 {
                output.append(contentsOf: buffer[0 ..< count])
                continue
            }
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            throw posixError(code)
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }
}
