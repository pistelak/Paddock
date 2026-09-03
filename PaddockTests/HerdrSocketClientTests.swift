import Foundation
import Testing
@testable import Paddock

/// Everything about the socket client that can be checked without a herdr:
/// the line-level decisions the read loop makes, and the errno mapping that
/// decides whether the store shows "not running" or a real failure.
/// The parts that need a server live in `HerdrSocketClientLiveTests`.
struct HerdrSocketClientTests {
    // MARK: - Stream lines

    @Test func decodesAnEventLineToItsKind() throws {
        let line = Data(#"{"event":"workspace_focused","data":{"type":"workspace_focused","workspace_id":"w3"}}"#.utf8)
        #expect(HerdrSocketClient.decodeEventKind(line) == HerdrEventKind(wire: "workspace_focused"))
    }

    @Test func keepsUnknownKindsRatherThanSkippingThem() throws {
        let line = Data(#"{"event":"tab_created","data":{"type":"tab_created","tab":{}}}"#.utf8)
        #expect(HerdrSocketClient.decodeEventKind(line) == HerdrEventKind(wire: "tab_created"))
    }

    /// A known kind with a payload the full-event decoder would reject still
    /// yields its kind: the payload is not read, so it cannot fail.
    @Test func keepsKnownKindsWhosePayloadHasDrifted() throws {
        let line = Data(#"{"event":"workspace_created","data":{"type":"workspace_created"}}"#.utf8)
        #expect(HerdrSocketClient.decodeEventKind(line) == HerdrEventKind(wire: "workspace_created"))
    }

    /// A truncated or otherwise unparseable line must not end a subscription;
    /// the reader skips whatever `decodeEventKind` cannot make sense of.
    @Test(arguments: [
        #"{"event":"workspace_focused","data""#,
        "not json at all",
        "",
    ])
    func skipsMalformedLines(line: String) {
        #expect(HerdrSocketClient.decodeEventKind(Data(line.utf8)) == nil)
    }

    /// A reply is not an event: only the subscribe ack is expected on that
    /// connection, and it is consumed before the stream starts.
    @Test func skipsResponseLines() {
        let line = Data(#"{"id":"1","result":{"type":"subscription_started"}}"#.utf8)
        #expect(HerdrSocketClient.decodeEventKind(line) == nil)
    }

    // MARK: - Connecting

    @Test func connectingToAMissingSocketReportsTheSessionAsUnavailable() {
        let path = NSTemporaryDirectory() + "paddock-missing-\(UUID().uuidString).sock"
        #expect(throws: PaddockError.herdrSocketUnavailable(path: path)) {
            try UnixSocketConnection(path: path)
        }
    }

    /// The shape a crashed herdr leaves behind: the socket file exists but
    /// nothing is listening (`ECONNREFUSED`), which still means "not running".
    @Test func connectingToAStaleSocketFileReportsTheSessionAsUnavailable() throws {
        // Short on purpose: `sun_path` holds 104 bytes and the test runner's
        // temporary directory alone is longer than that.
        let path = "/tmp/paddock-stale-\(UInt32.random(in: 0 ... .max)).sock"
        try bindWithoutListening(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: PaddockError.herdrSocketUnavailable(path: path)) {
            try UnixSocketConnection(path: path)
        }
    }

    @Test func aPathThatIsNotASocketReportsTheSessionAsUnavailable() throws {
        let path = NSTemporaryDirectory() + "paddock-file-\(UUID().uuidString)"
        #expect(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: PaddockError.herdrSocketUnavailable(path: path)) {
            try UnixSocketConnection(path: path)
        }
    }

    /// An errno that does not mean "nobody home" keeps its POSIX identity, so
    /// the store cannot mistake it for a stopped session.
    @Test func unexpectedErrnoIsNotReportedAsAStoppedSession() {
        let error = UnixSocketConnection.error(errno: EMFILE, path: "/tmp/x.sock") as NSError
        #expect(error as? PaddockError == nil)
        #expect(error.domain == NSPOSIXErrorDomain)
        #expect(error.code == Int(EMFILE))
    }

    // MARK: - One reader per connection

    /// The invariant the lifecycle lock depends on, enforced rather than
    /// documented: a second reader would race the first for bytes and, worse,
    /// let the first to finish hand the descriptor back under the other.
    @Test func aConnectionHandsOutItsLinesOnlyOnce() throws {
        let path = "/tmp/paddock-listen-\(UInt32.random(in: 0 ... .max)).sock"
        let listener = try listen(at: path)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let connection = try UnixSocketConnection(path: path)
        let lines = try connection.makeLines()
        #expect(throws: PaddockError.herdrSocketAlreadyReading(path: path)) {
            _ = try connection.makeLines()
        }
        connection.close()
        withExtendedLifetime(lines) {}
    }

    /// The contract is one reader *ever*, not one at a time: a connection
    /// carries one exchange, so a second reader after EOF has nothing to read.
    @Test func aConnectionRefusesASecondReaderEvenAfterTheFirstFinished() async throws {
        let path = "/tmp/paddock-listen-\(UInt32.random(in: 0 ... .max)).sock"
        let listener = try listen(at: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let connection = try UnixSocketConnection(path: path)
        let lines = try connection.makeLines()
        // Closing the listener's side ends the first reader with EOF.
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        Darwin.close(accepted)
        Darwin.close(listener)
        for try await _ in lines {}

        #expect(throws: PaddockError.herdrSocketAlreadyReading(path: path)) {
            _ = try connection.makeLines()
        }
        connection.close()
    }

    @Test func aClosedConnectionRefusesAReader() throws {
        let path = "/tmp/paddock-listen-\(UInt32.random(in: 0 ... .max)).sock"
        let listener = try listen(at: path)
        defer {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: path)
        }

        let connection = try UnixSocketConnection(path: path)
        connection.close()
        #expect(throws: PaddockError.herdrSocketUnavailable(path: path)) {
            _ = try connection.makeLines()
        }
    }

    // MARK: - Helpers

    /// A listening `AF_UNIX` socket at `path`, so a `UnixSocketConnection` can
    /// connect to something that never answers.
    private func listen(at path: String) throws -> Int32 {
        let descriptor = try bind(at: path)
        try #require(Darwin.listen(descriptor, 1) == 0, "could not listen on \(path): errno \(errno)")
        return descriptor
    }

    /// Creates a bound-but-not-listening `AF_UNIX` socket file. Swift Testing
    /// has no mid-test skip, so the conditions that used to skip the test are
    /// required instead: on this machine they always hold, and a failure here
    /// is a real one worth seeing.
    private func bindWithoutListening(at path: String) throws {
        Darwin.close(try bind(at: path))
    }

    /// A bound `AF_UNIX` socket at `path`; the caller closes it.
    private func bind(at path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(descriptor >= 0, "could not create a socket")

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        try #require(
            bytes.count < MemoryLayout.size(ofValue: address.sun_path),
            "\(path) is too long for sun_path"
        )
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0, "could not bind \(path): errno \(errno)")
        return descriptor
    }
}
