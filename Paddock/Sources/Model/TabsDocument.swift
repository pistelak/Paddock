import Foundation

/// The on-disk shape of tabs.json. The version is read first so a document
/// from another app version is reported as such instead of failing deep
/// inside decoding.
///
/// Every version has a *frozen* stored type of its own (`V1.Tab`, `V2.Tab`)
/// that is translated into `SessionTab` through its initialiser. `SessionTab`
/// itself is never decoded: a synthesised `Decodable` assigns stored
/// properties directly and would skip the display-name normalisation, and a
/// domain type that keeps evolving must not double as a file format that has
/// to stay readable for ever. A later format change gets `V3` here, not a
/// change to `SessionTab`.
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
        /// Frozen: the file format of version 2. `displayName` is optional on
        /// the way in so an older Paddock that wrote `""` still loads, and
        /// always written on the way out.
        struct Tab: Codable {
            let id: UUID
            let sessionName: SessionName
            let displayName: String?
            let color: TabColorID

            init(_ tab: SessionTab) {
                id = tab.id
                sessionName = tab.sessionName
                displayName = tab.displayName
                color = tab.color
            }

            var sessionTab: SessionTab {
                SessionTab(id: id, sessionName: sessionName, displayName: displayName, color: color)
            }
        }

        var version = TabsDocument.currentVersion
        let tabs: [Tab]
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
            let tabs = try decoder.decode(V2.self, from: data).tabs.map(\.sessionTab)
            return Decoded(tabs: tabs, needsUpgrade: false)
        default:
            throw PaddockError.unsupportedTabsFile(version: version)
        }
    }

    static func encode(_ tabs: [SessionTab]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(V2(tabs: tabs.map(V2.Tab.init)))
    }
}
