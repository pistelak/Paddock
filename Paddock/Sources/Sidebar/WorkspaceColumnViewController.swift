import AppKit

/// The "Spaces" column: one row per herdr workspace of the selected session.
///
/// Pure view, like `SidebarViewController`: it renders whatever the bound
/// `WorkspaceStore` holds and reports clicks through closures. It never calls
/// herdr itself, so a click and a change made inside the TUI both reach the
/// rows the same way — through the store's events.
///
/// This controller is the chrome and the binding. The outline's data source,
/// item identity and diff application live in `WorkspaceOutlineController`;
/// the footer's text and transient messages in `ColumnFooterView`.
@MainActor
final class WorkspaceColumnViewController: NSViewController {
    static let width: CGFloat = 220
    /// Clears the transparent title bar's drag region, like
    /// `SidebarViewController.topInset` does for the tile strip. Smaller,
    /// because there are no traffic lights over this column.
    private static let topInset: CGFloat = 38

    /// A row was clicked, or a context-menu entry chosen, for this workspace id.
    var onAction: ((WorkspaceAction, WorkspaceID) -> Void)? {
        get { outline.onAction }
        set { outline.onAction = newValue }
    }

    /// The header's "+" was clicked; the view is the popover/sheet anchor.
    var onCreate: ((NSView) -> Void)?

    private let outline = WorkspaceOutlineController()
    private let scrollView = NSScrollView()
    private let footer = ColumnFooterView()
    private let emptyLabel = NSTextField(labelWithString: "No spaces yet")
    private let addButton = NSButton()

    /// Held strongly: the store does not reference the column back (the
    /// observer captures `self` weakly), so there is no cycle, and the
    /// registry is free to drop a store the moment it stops it.
    private var store: WorkspaceStore?
    /// The column's right to be told about `store`; dropped with it.
    private var observation: ObservationToken?

    // MARK: - Chrome

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        view = background

        let header = makeHeaderLabel()
        configureAddButton()
        configureScrollView()
        configureEmptyLabel()

        let separator = NSBox()
        separator.boxType = .separator

        for subview in [header, addButton, scrollView, emptyLabel, footer, separator] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: Self.width),

            header.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 6),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])

        render()
    }

    private func makeHeaderLabel() -> NSTextField {
        let header = NSTextField(labelWithString: "SPACES")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        return header
    }

    private func configureAddButton() {
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = .secondaryLabelColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New space")
        addButton.target = self
        addButton.action = #selector(addButtonClicked)
        // The terminal keeps the keyboard: nothing in this column takes focus.
        addButton.refusesFirstResponder = true
        addButton.toolTip = "New space"
        addButton.setAccessibilityLabel("New space")
    }

    private func configureScrollView() {
        scrollView.documentView = outline.outline
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureEmptyLabel() {
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
    }

    // MARK: - Binding

    /// Points the column at one session's store, or at nothing.
    ///
    /// Letting go of the previous token is all it takes to stop hearing from
    /// the previous store — a store the registry keeps running for another tab
    /// goes on notifying whoever else watches it, just not this column.
    func bind(_ store: WorkspaceStore?) {
        guard store !== self.store else { return }
        observation?.cancel()
        self.store = store
        observation = store?.observe { [weak self] in self?.render() }
        render()
    }

    /// Reads the bound store and brings the outline and footer up to date.
    func render() {
        guard isViewLoaded else { return }

        let state = store?.state ?? WorkspaceListState()
        let connection = store?.connection
        // Any state that is not keeping the rows current means what is on
        // screen is the last thing herdr said, not what is true now.
        let isDimmed = connection.map { !$0.isConnected } ?? false

        let rows = WorkspaceRowSnapshot.rows(for: state)
        outline.apply(rows, dimmed: isDimmed)
        emptyLabel.isHidden = !(rows.isEmpty && connection?.isConnected == true)
        footer.show(connection)
    }

    /// Shows a one-off message (a failed focus, say) in the footer for a few
    /// seconds, then goes back to describing the connection.
    func showTransientError(_ message: String) {
        footer.flash(message)
    }

    // MARK: - Actions

    @objc private func addButtonClicked() {
        onCreate?(addButton)
    }
}
