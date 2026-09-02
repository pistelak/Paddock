import Foundation

/// The one place `tabs.json` is read or written. Writes carry a generation
/// so a slow older write can never replace a newer one. The file is a few
/// hundred bytes, so the synchronous I/O inside the actor is short-lived.
actor TabStoreFile {
    let url: URL
    private var lastWrittenGeneration = 0

    init(url: URL) {
        self.url = url
    }

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, generation: Int) throws {
        guard generation > lastWrittenGeneration else { return }
        lastWrittenGeneration = generation
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
