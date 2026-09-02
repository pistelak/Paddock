import Foundation

/// POSIX shell quoting. Single quotes are the only form that survives every
/// byte a filename or argument can contain, including newlines.
enum ShellQuote {
    private static let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:@%,~"))

    /// `'value'`, with embedded single quotes spelled `'\''`.
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// For pasting into a live prompt: unchanged when it needs no quoting,
    /// single-quoted otherwise, so ordinary paths stay readable.
    static func forPrompt(_ value: String) -> String {
        guard !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) else {
            return singleQuoted(value)
        }
        return value
    }
}
