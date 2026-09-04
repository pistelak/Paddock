import Foundation

/// A validated herdr session name. The value is interpolated into a
/// shell-parsed Ghostty `command` and appended to the sessions directory as a
/// path component, so the alphabet is restricted at construction and on
/// decode; a `SessionName` can never carry shell syntax, and the two names
/// that would step out of that directory (`.` and `..`) are refused.
struct SessionName: Hashable, Sendable, Codable, CustomStringConvertible {
    static let maximumLength = 64
    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))

    let rawValue: String

    init(_ raw: String) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".", name != "..",
              name.count <= Self.maximumLength,
              name.unicodeScalars.allSatisfy({ $0.isASCII && Self.allowed.contains($0) })
        else {
            throw PaddockError.invalidSessionName(raw)
        }
        rawValue = name
    }

    init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}
