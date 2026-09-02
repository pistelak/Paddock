import AppKit

/// What a drag onto the terminal turns into: file URLs become quoted
/// paths, anything else pastes as plain text.
@MainActor
enum DropPayload {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .string]

    static func text(from pasteboard: NSPasteboard) -> String? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        let fileURLs = urls.filter(\.isFileURL)
        if !fileURLs.isEmpty {
            return fileURLs.map { ShellQuote.forPrompt($0.path) }.joined(separator: " ")
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty else { return nil }
        return string
    }
}
