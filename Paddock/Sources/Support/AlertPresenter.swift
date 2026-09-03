import AppKit

/// All user-facing dialogs go through here so they look alike and so the
/// sheet-vs-modal decision is made in one place.
///
/// Everything is `async` and returns when the dialog has been dismissed, so a
/// caller can sequence "tell the user, *then* act" — the shape that stopped a
/// tab-file recovery from writing over the file before its alert was even on
/// screen. A caller that genuinely does not care when the dialog closes wraps
/// the call in its own `Task`.
@MainActor
enum AlertPresenter {
    static func present(_ error: Error, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Something went wrong"
        alert.informativeText = error.localizedDescription
        _ = await run(alert, in: window)
    }

    static func presentWarning(title: String, message: String, in window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        _ = await run(alert, in: window)
    }

    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        destructive: Bool = false,
        in window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .critical : .informational
        alert.messageText = title
        alert.informativeText = message
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.hasDestructiveAction = destructive
        alert.addButton(withTitle: "Cancel")
        return await run(alert, in: window) == .alertFirstButtonReturn
    }

    static func promptForText(
        title: String,
        message: String,
        placeholder: String,
        initialValue: String = "",
        confirmTitle: String = "OK",
        in window: NSWindow?
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard await run(alert, in: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// A sheet on `window`, or — with no window to attach to, which only
    /// happens before the main window exists — an application-modal alert.
    /// `runModal()` spins its own event loop on the main thread and returns
    /// synchronously; inside an `async` main-actor function that is
    /// re-entrant but sound, and it is the only way to show anything without
    /// a window. `bootstrap()` shows the window first so this path is rare.
    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
