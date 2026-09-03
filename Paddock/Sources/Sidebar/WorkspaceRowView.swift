import AppKit

/// The background of one space row: the "focused" pill and the hover tint.
///
/// The pill is *not* the table's selection. Selection is switched off in the
/// column (the terminal keeps the keyboard), so what the row highlights is
/// herdr's own `focused` flag, which only ever changes because herdr said so.
@MainActor
final class WorkspaceRowView: NSTableRowView {
    static let height: CGFloat = 28
    /// Leaves a margin on both sides so the pill reads as a pill rather than
    /// a full-width band.
    private static let pillInset: CGFloat = 6
    private static let focusedAlpha: CGFloat = 0.12
    private static let hoveredAlpha: CGFloat = 0.06

    var isFocusedWorkspace = false {
        didSet {
            guard isFocusedWorkspace != oldValue else { return }
            needsDisplay = true
        }
    }

    private var isHovered = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        let alpha: CGFloat = if isFocusedWorkspace {
            Self.focusedAlpha
        } else if isHovered {
            Self.hoveredAlpha
        } else {
            0
        }
        guard alpha > 0 else { return }

        let rect = bounds.insetBy(dx: Self.pillInset, dy: 1)
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Rows are recycled by the outline view; a reused row must not keep the
    /// hover of the row it used to be.
    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }
}

/// The contents of one space row: status dot, then `number · label`.
@MainActor
final class WorkspaceCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WorkspaceCell")
    private static let dotSize: CGFloat = 8

    private let dot = StatusDotView()
    private let title = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: WorkspaceRowView.height))

        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        // The cell speaks for the whole row — "2 · docs, working" — so the
        // label inside it is not announced a second time.
        title.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)

        for subview in [dot, title] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        textField = title

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// `dimmed` means the rows are stale — the socket dropped and the column
    /// is showing the last thing herdr said while it reconnects.
    func apply(_ row: WorkspaceRowSnapshot, dimmed: Bool) {
        title.stringValue = row.displayText
        dot.status = row.status
        toolTip = row.label.isEmpty ? row.displayText : row.label
        alphaValue = dimmed ? 0.5 : 1
        setAccessibilityLabel("\(row.displayText), \(row.status.rawValue)")
    }

    func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.5 : 1
    }
}

/// The 8 pt agent-status dot. Hand-drawn rather than a layer so it follows
/// appearance changes for free, like the other tiles in the sidebar.
@MainActor
private final class StatusDotView: NSView {
    var status: AgentStatus = .unknown {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        status.dotColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
