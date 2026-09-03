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

    /// The file's bytes, or `nil` when there is genuinely nothing at the path.
    ///
    /// "Nothing there" is decided by `lstat(2)` answering `ENOENT` — not by
    /// `fileExists(atPath:)`, which also says `false` when it cannot tell (an
    /// unreadable parent directory, say), and not by any other error either.
    /// The difference matters: a `nil` here is what lets the caller seed a
    /// fresh list and save it, so it must never be returned for a path that
    /// has something at it or that could not be examined. A symlink is
    /// followed and its target must exist and be a regular file; a directory,
    /// a loop or a dangling link at the path is reported rather than written
    /// over.
    func read() throws -> Data? {
        var link = stat()
        switch try Self.call({ lstat($0, &link) }, on: url) {
        case .failed(ENOENT):
            return nil
        case let .failed(code):
            throw Self.posixError(code)
        case .succeeded:
            break
        }

        // Something is at the path. If it is a symlink, what matters is the
        // target — and a target that is missing or unreadable is an error,
        // not an absence: the link itself is still there.
        var info = link
        if link.st_mode & S_IFMT == S_IFLNK {
            switch try Self.call({ stat($0, &info) }, on: url) {
            case let .failed(code):
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey:
                        "\(url.path) is a symbolic link whose target cannot be read: \(String(cString: strerror(code))).",
                ])
            case .succeeded:
                break
            }
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: "\(url.path) is not a regular file.",
            ])
        }
        return try Data(contentsOf: url)
    }

    private enum SyscallOutcome {
        case succeeded
        case failed(Int32)
    }

    /// Runs one `stat`-family call against `url`'s file-system representation
    /// and reports its `errno` explicitly, so no caller ever reads a stale one.
    /// A URL without a representation cannot be examined at all — that is an
    /// error, never "missing".
    private static func call(_ syscall: (UnsafePointer<CChar>) -> Int32, on url: URL) throws -> SyscallOutcome {
        try url.withUnsafeFileSystemRepresentation { path -> SyscallOutcome in
            guard let path else {
                throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
            }
            return syscall(path) == 0 ? .succeeded : .failed(errno)
        }
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

    /// Moves a file that could not be read out of the way — to
    /// `tabs.json.unreadable-<UTC stamp>` next to it — and returns where it
    /// went, so the caller can say so and a fresh document can be written
    /// without destroying what was there.
    ///
    /// A move rather than a delete: the bytes may still be someone's tab
    /// layout, just not in a shape this Paddock can read. The stamp keeps
    /// repeated launches from overwriting each other's backups.
    func quarantineUnreadableFile(now: Date = Date()) throws -> URL {
        let stamp = Self.stampFormatter.string(from: now)
        var candidate = url.appendingPathExtension("unreadable-\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("unreadable-\(stamp)-\(attempt)")
            attempt += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        )
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
