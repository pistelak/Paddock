import AppKit
import GhosttyTerminal

/// One herdr session, rendered by one libghostty surface. The pane keeps
/// its surface alive while hidden so switching tabs never detaches the
/// herdr client; only a detach or exit inside herdr ends the surface, after
/// which the overlay offers to reattach.
@MainActor
final class TerminalPaneViewController: NSViewController {
    /// Where the pane is in its life. One value, so "an overlay with no
    /// terminal", "a stale reason with no overlay" and the like cannot be
    /// written; every transition is a whole new value.
    private enum PaneState {
        /// The terminal is up and herdr is (being) attached in it.
        case attached(PaddockTerminalView)
        /// The surface ended; the overlay says why and offers a reattach.
        case ended(PaddockTerminalView, DetachedOverlayView, SurfaceEnd)

        var terminal: PaddockTerminalView {
            switch self {
            case let .attached(terminal), let .ended(terminal, _, _): terminal
            }
        }

        var overlay: DetachedOverlayView? {
            switch self {
            case .attached: nil
            case let .ended(_, overlay, _): overlay
            }
        }
    }

    private(set) var tab: SessionTab
    private(set) var lastTitle: String?

    var onEvent: ((TerminalPaneEvent) -> Void)?

    private let host: TerminalHost
    private let herdrExecutable: URL
    /// `nil` only before `loadView()`.
    private var state: PaneState?
    private var isVisible = true

    init(tab: SessionTab, host: TerminalHost, herdrExecutable: URL) {
        self.tab = tab
        self.host = host
        self.herdrExecutable = herdrExecutable
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        view = container
        state = .attached(attachTerminalView())
    }

    // MARK: - Host API

    func update(tab: SessionTab) {
        self.tab = tab
        state?.terminal.setAccessibilityLabel(accessibilityLabel)
        if case let .ended(_, overlay, end)? = state {
            overlay.message = Self.overlayMessage(for: end, tab: tab)
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        state?.terminal.setSurfaceVisible(visible)
    }

    /// Moves keyboard focus into this pane: the terminal, or the Reattach
    /// button while the overlay is up. Does nothing for a hidden pane, so a
    /// background pane whose process ends never steals focus.
    func focusPreferredResponder() {
        guard isVisible, let state else { return }
        if let overlay = state.overlay {
            view.window?.makeFirstResponder(overlay.reattachButton)
        } else {
            state.terminal.acquireProgrammaticFocus()
        }
    }

    /// Tears the ended surface and its overlay down and starts a fresh one.
    func reattach() {
        guard case let .ended(terminal, overlay, _)? = state else { return }
        overlay.removeFromSuperview()
        terminal.removeFromSuperview()
        lastTitle = nil
        onEvent?(.titleChanged(nil))
        state = .attached(attachTerminalView())
        focusPreferredResponder()
    }

    // MARK: - Surface

    private var surfaceOptions: TerminalSurfaceOptions {
        TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: NSHomeDirectory(),
            envVars: ["PADDOCK_SESSION": tab.sessionName.rawValue],
            // Ghostty parses `command` with /bin/sh, so both words are quoted.
            command: "\(ShellQuote.singleQuoted(herdrExecutable.path)) --session \(ShellQuote.singleQuoted(tab.sessionName.rawValue))",
            waitAfterCommand: false,
            context: .window,
            // herdr repaints the whole alternate screen on every resize;
            // the package recommends ~96ms coalescing for such TUIs.
            resizeThrottleMilliseconds: 96
        )
    }

    private var accessibilityLabel: String {
        "Terminal for \(tab.displayName)"
    }

    private static func overlayMessage(for end: SurfaceEnd, tab: SessionTab) -> String {
        switch end {
        case .detached: "Session “\(tab.displayName)” was detached."
        case .exited: "herdr exited for session “\(tab.displayName)”."
        }
    }

    private func attachTerminalView() -> PaddockTerminalView {
        let terminal = PaddockTerminalView(frame: view.bounds)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.delegate = self
        terminal.configuration = surfaceOptions
        terminal.controller = host.controller
        terminal.setAccessibilityLabel(accessibilityLabel)
        view.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        terminal.setSurfaceVisible(isVisible)
        return terminal
    }

    private func end(_ end: SurfaceEnd) {
        // A second close for a surface that has already ended changes nothing.
        guard case let .attached(terminal)? = state else { return }
        let overlay = DetachedOverlayView(message: Self.overlayMessage(for: end, tab: tab))
        overlay.onReattach = { [weak self] in self?.reattach() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        state = .ended(terminal, overlay, end)
        focusPreferredResponder()
    }
}

// MARK: - Terminal delegates

extension TerminalPaneViewController: TerminalSurfaceTitleDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceLifecycleDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        lastTitle = title
        onEvent?(.titleChanged(title))
    }

    func terminalDidClose(processAlive: Bool) {
        let end = SurfaceEnd(processAlive: processAlive)
        self.end(end)
        onEvent?(.surfaceClosed(end))
    }

    /// The surface exists, so the `herdr` process behind it has just been
    /// spawned: the moment a session that was not running starts to answer.
    func terminalDidAttachSurface(_: TerminalSurface) {
        onEvent?(.surfaceAttached)
    }

    func terminalDidDetachSurface() {
        // Nothing to report: a detach happens both when herdr ends (which
        // `terminalDidClose(processAlive:)` already covers) and when the pane
        // is torn down on purpose, and neither needs a second event.
    }
}
