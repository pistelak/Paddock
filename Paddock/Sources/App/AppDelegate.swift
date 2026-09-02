import AppKit
import GhosttyTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var coordinator: TabCoordinator?

    func applicationDidFinishLaunching(_: Notification) {
        HerdrEnvironment.scrubInheritedMarkers()
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
            TerminalDebugLog.enable(.standard)
            TerminalDebugLog.sink = { message in NSLog("%@", message) }
        #endif
        NSApp.mainMenu = MainMenu.build()
        Task { await bootstrap() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// Lets a queued tab-list save reach the disk before the process ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = coordinator?.store else { return .terminateNow }
        Task {
            await store.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Startup

    private func bootstrap() async {
        let windowController = MainWindowController()
        mainWindowController = windowController

        guard let herdrExecutable = await HerdrLocator.locate() else {
            windowController.showWindow(nil)
            AlertPresenter.present(PaddockError.herdrNotFound, in: windowController.window)
            return
        }

        let host = TerminalHost(configPath: GhosttyConfigLocator.path())
        let store = TabStore(fileURL: TabStore.defaultFileURL())
        let coordinator = TabCoordinator(store: store, host: host, herdrExecutable: herdrExecutable)
        self.coordinator = coordinator

        await loadOrSeed(store, using: coordinator.herdr, window: windowController.window)

        windowController.install(MainContentViewController(
            sidebar: coordinator.sidebar,
            panes: coordinator.panes
        ))
        coordinator.window = windowController.window
        windowController.showWindow(nil)
        NSApp.activate()
        coordinator.start()

        if let issue = host.configurationIssue {
            AlertPresenter.presentWarning(
                title: "Ghostty config not applied",
                message: "\(issue)\n\n\(GhosttyConfigLocator.themesSymlinkHint)\n\nRunning with libghostty defaults.",
                in: windowController.window
            )
        }
    }

    /// Loads the saved tabs, or seeds them from herdr on first launch. Every
    /// failure along the way is shown; the app still starts with a
    /// `default` tab so there is always something to attach to.
    private func loadOrSeed(_ store: TabStore, using herdr: HerdrCLI, window: NSWindow?) async {
        do {
            if try await store.load() { return }
        } catch {
            AlertPresenter.present(error, in: window)
        }

        var tabs: [SessionTab] = []
        do {
            tabs = TabStore.seedTabs(from: try await herdr.listSessions())
        } catch {
            AlertPresenter.present(error, in: window)
        }
        if tabs.isEmpty, let fallback = try? SessionName("default") {
            tabs = [SessionTab(sessionName: fallback, color: .blue)]
        }
        do {
            try store.replaceAll(tabs)
        } catch {
            AlertPresenter.present(error, in: window)
        }
    }
}
