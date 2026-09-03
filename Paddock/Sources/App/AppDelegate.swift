import AppKit
import GhosttyTerminal

/// Paddock is a single-window app: closing the window quits, window tabbing
/// is off, and the menu offers no second window. Everything window-scoped
/// (the selected tab, the two hidden-column flags) is therefore stored
/// app-wide on purpose.
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

    /// Stops every spaces store, then lets a queued tab-list save reach the
    /// disk before the process ends.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        coordinator.stop()
        Task {
            await coordinator.store.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The Dock icon was clicked. This is where AppKit would expect a
    /// multi-window app to open a window; Paddock brings back the only one it
    /// has and asks for nothing else. `hasVisibleWindows` is not consulted:
    /// AppKit counts a *miniaturised* window as visible, so it would be `true`
    /// in exactly the case that needs handling.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let window = mainWindowController?.window else { return false }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Startup

    /// The window comes first, before anything that can wait on the outside
    /// world: locating herdr may fall back to a login shell, and a slow
    /// `.zshrc` must not leave the user looking at nothing.
    private func bootstrap() async {
        let windowController = MainWindowController()
        mainWindowController = windowController
        windowController.showWindow(nil)
        NSApp.activate()

        guard let herdrExecutable = await HerdrLocator.locate() else {
            await AlertPresenter.present(PaddockError.herdrNotFound, in: windowController.window)
            return
        }

        let host = TerminalHost(configPath: GhosttyConfigLocator.path())
        let store = TabStore(fileURL: TabStore.defaultFileURL())
        let coordinator = TabCoordinator(store: store, host: host, herdrExecutable: herdrExecutable)
        self.coordinator = coordinator

        let notices = await loadOrSeed(store, using: coordinator.herdr)

        let content = MainContentViewController(
            sidebar: coordinator.sidebar,
            spaces: coordinator.spaces,
            panes: coordinator.panes
        )
        content.onLayoutChange = { [weak coordinator] in coordinator?.focusSelectedPane() }
        windowController.install(content)
        coordinator.window = windowController.window
        coordinator.start()

        // Told after the content is up, so the user reads them against the
        // tabs they describe rather than an empty window.
        for notice in notices {
            await AlertPresenter.presentWarning(title: notice.title, message: notice.message, in: windowController.window)
        }
        if let issue = host.configurationIssue {
            await AlertPresenter.presentWarning(
                title: "Ghostty config not applied",
                message: "\(issue)\n\n\(GhosttyConfigLocator.themesSymlinkHint)\n\nRunning with libghostty defaults.",
                in: windowController.window
            )
        }
    }

    /// Something the user should be told once the window is on screen.
    struct Notice: Equatable, Sendable {
        let title: String
        let message: String
    }

    /// Loads the saved tabs, or seeds them from herdr — on first launch, and
    /// after a file that could not be read has been dealt with. Every failure
    /// along the way becomes a notice; the app still starts with a `default`
    /// tab so there is always something to attach to.
    ///
    /// **The original file is never written over while it is still there.**
    /// Corrupt contents are moved aside first; a newer format or an I/O error
    /// turns saving off for this run instead, because those bytes may be
    /// somebody's perfectly good tab list. See `TabStore.LoadFailure`.
    private func loadOrSeed(_ store: TabStore, using herdr: HerdrCLI) async -> [Notice] {
        var notices: [Notice] = []
        do {
            if try await store.load() { return [] }
        } catch {
            notices.append(await recover(from: error, in: store))
        }

        var tabs: [SessionTab] = []
        do {
            tabs = TabStore.seedTabs(from: try await herdr.listSessions())
        } catch {
            notices.append(Notice(
                title: "Could not list herdr sessions",
                message: "\(error.localizedDescription)\n\nStarting with a “default” tab."
            ))
        }
        if tabs.isEmpty, let fallback = try? SessionName("default") {
            tabs = [SessionTab(sessionName: fallback, color: .blue)]
        }
        do {
            try store.replaceAll(tabs)
        } catch {
            notices.append(Notice(title: "Could not set up tabs", message: error.localizedDescription))
        }
        return notices
    }

    /// Chooses the recovery for a file that could not be loaded and reports
    /// what was done. Only `.invalidContents` may touch the file, and even
    /// then only to move it; if that fails the run goes ephemeral too.
    private func recover(from failure: TabStore.LoadFailure, in store: TabStore) async -> Notice {
        let path = store.fileURL.path
        switch failure {
        case let .invalidContents(reason):
            do {
                let backup = try await store.quarantineFile()
                return Notice(
                    title: "Paddock rebuilt your tabs",
                    message: """
                    The saved tab layout could not be read: \(reason.localizedDescription)
                    It was moved to:
                    \(backup.path)

                    Paddock rebuilt the tab list from your herdr sessions. Your herdr sessions were not \
                    changed. Custom tab order, names and colours were reset.
                    """
                )
            } catch {
                store.disableSaving()
                return Self.cannotAccessNotice(path: path, error: error)
            }
        case let .newerVersion(version):
            store.disableSaving()
            return Notice(
                title: "These tabs were saved by a newer Paddock",
                message: """
                \(path) uses format version \(version) and was left unchanged.

                Paddock is using a temporary tab list from herdr for this run; changes to tab order, \
                names and colours will not be saved. Install a compatible Paddock to recover the saved \
                layout, or delete this file if you intend to reset it. Your herdr sessions are unaffected.
                """
            )
        case let .io(error):
            store.disableSaving()
            return Self.cannotAccessNotice(path: path, error: error)
        }
    }

    private static func cannotAccessNotice(path: String, error: Error) -> Notice {
        Notice(
            title: "Paddock can’t access its saved tabs",
            message: """
            Paddock could not read or preserve \(path): \(error.localizedDescription)
            The file was left unchanged.

            Paddock is using a temporary tab list from herdr for this run; tab-layout changes will not \
            be saved. Check the file and folder permissions, then relaunch. Your herdr sessions are \
            unaffected.
            """
        )
    }
}
