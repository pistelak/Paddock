import Foundation

/// The on-disk shape of tabs.json. The version is read first so a document
/// from another app version is reported as such instead of failing deep
/// inside decoding. Version 2 stores `SessionTab` directly; a later format
/// change gets its own stored type here, not a change to `SessionTab`.
enum TabsDocument {
    static let currentVersion = 2

    private struct Probe: Decodable {
        let version: Int
    }

    private struct V1: Decodable {
        struct Tab: Decodable {
            let id: UUID
            let sessionName: SessionName
            let displayName: String?
            let colorIndex: Int
        }

        let tabs: [Tab]
    }

    private struct V2: Codable {
        var version = TabsDocument.currentVersion
        let tabs: [SessionTab]
    }

    struct Decoded {
        let tabs: [SessionTab]
        /// True when the file was in an older format and should be
        /// rewritten in the current one.
        let needsUpgrade: Bool
    }

    static func decode(_ data: Data) throws -> Decoded {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Probe.self, from: data).version
        switch version {
        case 1:
            let tabs = try decoder.decode(V1.self, from: data).tabs.map { stored in
                SessionTab(
                    id: stored.id,
                    sessionName: stored.sessionName,
                    displayName: stored.displayName,
                    color: TabColorID.fromLegacyIndex(stored.colorIndex)
                )
            }
            return Decoded(tabs: tabs, needsUpgrade: true)
        case currentVersion:
            return Decoded(tabs: try decoder.decode(V2.self, from: data).tabs, needsUpgrade: false)
        default:
            throw PaddockError.unsupportedTabsFile(version: version)
        }
    }

    static func encode(_ tabs: [SessionTab]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(V2(tabs: tabs))
    }
}
