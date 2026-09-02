import AppKit
import GhosttyTerminal

/// One herdr session, rendered by one libghostty surface. The pane keeps
/// its surface alive while hidden so switching tabs never detaches the
/// herdr client; only a detach or exit inside herdr ends the surface, after
/// which the overlay offers to reattach.
@MainActor
final class TerminalPaneViewController: NSViewController {
    private(set) var tab: SessionTab
    private(set) var lastTitle: String?

    var onEvent: ((TerminalPaneEvent) -> Void)?

    private let host: TerminalHost
    private let herdrExecutable: URL
    private var terminalView: PaddockTerminalView?
    private var overlay: DetachedOverlayView?
    private var overlayProcessAlive = false
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
        attachTerminalView()
    }

    // MARK: - Host API

    func update(tab: SessionTab) {
        self.tab = tab
        terminalView?.setAccessibilityLabel(accessibilityLabel)
        overlay?.message = overlayMessage
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        terminalView?.setSurfaceVisible(visible)
    }

    /// Moves keyboard focus into this pane: the terminal, or the Reattach
    /// button while the overlay is up. Does nothing for a hidden pane, so a
    /// background pane whose process ends never steals focus.
    func focusPreferredResponder() {
        guard isVisible else { return }
        if let overlay {
            view.window?.makeFirstResponder(overlay.reattachButton)
        } else {
            terminalView?.acquireProgrammaticFocus()
        }
    }

    func reattach() {
        overlay?.removeFromSuperview()
        overlay = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        lastTitle = nil
        onEvent?(.titleChanged(nil))
        attachTerminalView()
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

    private var overlayMessage: String {
        overlayProcessAlive
            ? "Session “\(tab.displayName)” was detached."
            : "herdr exited for session “\(tab.displayName)”."
    }

    private func attachTerminalView() {
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
        terminalView = terminal
    }

    private func showOverlay(processAlive: Bool) {
        guard overlay == nil else { return }
        overlayProcessAlive = processAlive
        let overlay = DetachedOverlayView(message: overlayMessage)
        overlay.onReattach = { [weak self] in self?.reattach() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.overlay = overlay
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
        showOverlay(processAlive: processAlive)
        onEvent?(.surfaceClosed(processAlive: processAlive))
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
