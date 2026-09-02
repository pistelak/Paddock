import Foundation

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
/// `UnixSocketConnection` keeps its own loop rather than calling this: it
/// frames NDJSON, is torn down from cancellation handlers and has a descriptor
/// lifecycle to guard. Sharing would mean pushing all of that in here.
enum DescriptorReader {
    /// One `read(2)`'s worth. Pipe buffers are 64 KiB on macOS.
    private static let bufferSize = 64 * 1024

    /// Everything the descriptor produces until EOF.
    ///
    /// Reads the descriptor `handle` owns rather than the handle itself, and
    /// leaves closing to the caller: the `FileHandle` must outlive the read,
    /// and it is the caller who knows when that is.
    static func readToEnd(_ handle: FileHandle) async throws -> Data {
        let descriptor = handle.fileDescriptor
        return try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try readToEnd(descriptor: descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.name = "paddock-pipe-reader"
            thread.stackSize = 256 * 1024
            thread.start()
        }
    }

    /// The blocking loop itself, retrying `EINTR` and stopping at EOF.
    private static func readToEnd(descriptor: Int32) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count == 0 { return output }
            if count > 0 {
                output.append(contentsOf: buffer[0 ..< count])
                continue
            }
            let code = errno
            if code == EINTR { continue }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }
}
