import AppKit

/// The line under the spaces list that says what the connection is doing —
/// or, for a few seconds, what just went wrong.
///
/// Two inputs, one label. The connection state is the steady text (from
/// `ConnectionFooter`), a transient message overrides it until its timer
/// runs out or a newer one replaces it. With nothing to say the whole strip
/// collapses, margins included, so live rows get the space back.
@MainActor
final class ColumnFooterView: NSView {
    static let transientDuration: Duration = .seconds(4)

    private let label = NSTextField(labelWithString: "")
    private var collapsed: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    private var connection: WorkspaceStore.ConnectionState?
    private var transientMessage: String?
    private var transientTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.usesSingleLineMode = false
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        collapsed = heightAnchor.constraint(equalToConstant: 0)
        top = label.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        NSLayoutConstraint.activate([
            top,
            bottom,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        redraw()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The steady text: what the connection is doing, or nothing when live.
    func show(_ connection: WorkspaceStore.ConnectionState?) {
        self.connection = connection
        redraw()
    }

    /// A one-off message (a failed focus, say) for `transientDuration`, then
    /// back to describing the connection.
    func flash(_ message: String) {
        transientTask?.cancel()
        transientMessage = message
        redraw()
        transientTask = Task { @MainActor [weak self] in
            // Not `try?`: that swallows cancellation and would clear a message
            // a newer error has just replaced.
            do { try await Task.sleep(for: Self.transientDuration) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.transientTask = nil
            self.transientMessage = nil
            self.redraw()
        }
    }

    /// What is on the label right now, for tests and for the VC's empty-state
    /// decision.
    var text: String? {
        transientMessage ?? ConnectionFooter.text(for: connection)
    }

    private func redraw() {
        let text = text
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        // Collapse the whole strip, margins included, when it is empty.
        collapsed.isActive = text == nil
        top.constant = text == nil ? 0 : 6
        bottom.constant = text == nil ? 0 : -10
    }
}
