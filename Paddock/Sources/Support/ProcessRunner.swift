import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

/// Runs a subprocess to completion without blocking a cooperative thread:
/// both pipes are drained concurrently, each on a reader thread of its own (a
/// child that fills one pipe while we wait on the other would otherwise
/// deadlock, and `FileHandle.bytes` cannot give two readers that independence
/// — see `DescriptorReader`), and termination arrives through an `AsyncStream`
/// fed by `terminationHandler`.
enum ProcessRunner {
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        let (termination, terminationContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { finished in
            terminationContinuation.yield(finished.terminationStatus)
            terminationContinuation.finish()
        }

        try process.run()

        let outputHandle = standardOutput.fileHandleForReading
        let errorHandle = standardError.fileHandleForReading
        async let output = DescriptorReader.readToEnd(outputHandle)
        async let errors = DescriptorReader.readToEnd(errorHandle)
        let (standardOutputData, standardErrorData) = try await (output, errors)
        // Both readers have seen EOF, so nothing is using the descriptors any
        // more. Closing here rather than leaving it to the pipes' deallocation
        // keeps a run from holding two descriptors longer than it needs them.
        try? outputHandle.close()
        try? errorHandle.close()

        var status: Int32 = -1
        for await value in termination {
            status = value
        }

        return ProcessResult(
            status: status,
            // A command that writes something other than UTF-8 is a broken
            // command, not a broken run: report what decoded and let the
            // caller's own parsing fail with a message about the content.
            standardOutput: String(decoding: standardOutputData, as: UTF8.self),
            standardError: String(decoding: standardErrorData, as: UTF8.self)
        )
    }
}
