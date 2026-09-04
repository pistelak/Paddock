import Testing
@testable import Paddock

/// The rule that keeps a development build away from the update feed: only a
/// bundle whose `CFBundleVersion` came off a release tag starts Sparkle.
struct VersionedBuildTests {
    @Test(arguments: ["0.2.0", "1.0.0", "0.2.1"])
    @MainActor func aReleaseVersionStartsTheUpdater(version: String) {
        #expect(AppDelegate.isVersionedBuild(version))
    }

    @Test(arguments: [nil, "0"] as [String?])
    @MainActor func theDevelopmentPlaceholderDoesNot(version: String?) {
        #expect(!AppDelegate.isVersionedBuild(version))
    }
}
