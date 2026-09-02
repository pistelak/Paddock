import Foundation

struct ProcessResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

/// Runs a subprocess to completion without blocking a cooperative thread:
/// both pipes are drained concurrently through `FileHandle.bytes` (a child
/// that fills one pipe while we wait on the other would otherwise deadlock),
/// and termination arrives through an `AsyncStream` fed by
/// `terminationHandler`.
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

        async let output = readToEnd(standardOutput.fileHandleForReading)
        async let errors = readToEnd(standardError.fileHandleForReading)
        let (standardOutputText, standardErrorText) = try await (output, errors)

        var status: Int32 = -1
        for await value in termination {
            status = value
        }

        return ProcessResult(
            status: status,
            standardOutput: standardOutputText,
            standardError: standardErrorText
        )
    }

    private static func readToEnd(_ handle: FileHandle) async throws -> String {
        var text = ""
        for try await line in handle.bytes.lines {
            text.append(line)
            text.append("\n")
        }
        return text
    }
}
