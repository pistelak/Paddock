import AppKit

/// The dialogs behind the spaces column's context menu and "+": rename,
/// close, create. Each asks, then tells the store, then reports a failure.
///
/// A failed create, rename or close answers a dialog the user just filled in
/// and gets an alert of its own; a failed *focus* is one click among many and
/// is a footnote in the column's footer instead, which is why focus is not
/// here — it lives with the coordinator, which owns the column.
@MainActor
struct SpaceCommands {
    weak var window: NSWindow?

    func rename(_ workspaceID: WorkspaceID, in store: WorkspaceStore) async {
        guard let workspace = store.state.workspace(workspaceID) else { return }
        guard let raw = await AlertPresenter.promptForText(
            title: "Rename Space",
            message: "Shown in the Spaces column and in herdr’s own tab bar.",
            placeholder: "Label",
            initialValue: workspace.label,
            confirmTitle: "Rename",
            in: window
        ) else { return }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        do {
            try await store.rename(workspaceID, to: label)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    func close(_ workspaceID: WorkspaceID, in store: WorkspaceStore) async {
        guard let workspace = store.state.workspace(workspaceID) else { return }
        let confirmed = await AlertPresenter.confirm(
            title: "Close space “\(Self.displayName(of: workspace))”?",
            message: "Every pane and agent in it will be terminated.",
            confirmTitle: "Close Space",
            destructive: true,
            in: window
        )
        guard confirmed else { return }
        do {
            try await store.close(workspaceID)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    func create(in store: WorkspaceStore) async {
        guard let raw = await AlertPresenter.promptForText(
            title: "New Space",
            message: "herdr creates the space and moves to it.",
            placeholder: "Label (optional)",
            confirmTitle: "Create",
            in: window
        ) else { return }
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await store.create(label: label.isEmpty ? nil : label)
        } catch {
            await AlertPresenter.present(error, in: window)
        }
    }

    /// A space herdr has no label for is known by its number, exactly as the
    /// row draws it.
    static func displayName(of workspace: Workspace) -> String {
        workspace.label.isEmpty ? "\(workspace.number)" : workspace.label
    }
}
