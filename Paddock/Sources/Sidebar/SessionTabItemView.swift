import AppKit

/// A Slack-style workspace tile: rounded colour square with initials, a
/// ring when selected, a lighter fill on hover.
@MainActor
final class SessionTabItemView: NSView {
    static let size = NSSize(width: 44, height: 44)
    private static let tileInset: CGFloat = 4
    private static let cornerRadius: CGFloat = 9

    let tabID: UUID
    var onSelect: ((UUID) -> Void)?
    var onContextMenu: ((UUID, NSEvent) -> Void)?

    private(set) var tab: SessionTab
    private var isSelected = false
    private var isHovered = false

    init(tab: SessionTab) {
        tabID = tab.id
        self.tab = tab
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = tab.sessionName.rawValue
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.displayName)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    func apply(tab: SessionTab, selected: Bool) {
        self.tab = tab
        isSelected = selected
        toolTip = tab.sessionName.rawValue
        setAccessibilityLabel(tab.displayName)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_: NSRect) {
        if isSelected {
            let ring = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: Self.cornerRadius + 3,
                yRadius: Self.cornerRadius + 3
            )
            ring.lineWidth = 2
            NSColor.labelColor.setStroke()
            ring.stroke()
        }

        let tileRect = bounds.insetBy(dx: Self.tileInset, dy: Self.tileInset)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        var fill = tab.color.color.nsColor
        if isHovered, !isSelected {
            fill = fill.blended(withFraction: 0.18, of: .white) ?? fill
        }
        fill.setFill()
        tile.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
        ]
        let text = NSAttributedString(string: tab.initials, attributes: attributes)
        let textSize = text.size()
        text.draw(at: NSPoint(
            x: tileRect.midX - textSize.width / 2,
            y: tileRect.midY - textSize.height / 2
        ))
    }

    // MARK: - Mouse

    override func mouseDown(with _: NSEvent) {
        onSelect?(tabID)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(tabID)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(tabID, event)
    }

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
}
