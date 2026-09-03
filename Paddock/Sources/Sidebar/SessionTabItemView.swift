import AppKit

/// A Slack-style workspace tile: rounded colour square with initials, a
/// ring when selected, a lighter fill on hover, and a status dot in the
/// bottom-right corner when any space in the session has something to say.
@MainActor
final class SessionTabItemView: NSView {
    static let size = NSSize(width: 44, height: 44)
    private static let tileInset: CGFloat = 4
    private static let cornerRadius: CGFloat = 9
    private static let badgeSize: CGFloat = 10
    /// The gap between the dot and the tile, cut out of the tile so the dot
    /// reads as sitting on top of it whatever the tile colour.
    private static let badgeRing: CGFloat = 2

    let tabID: UUID
    var onSelect: ((UUID) -> Void)?
    var onContextMenu: ((UUID, NSEvent) -> Void)?

    private(set) var tab: SessionTab
    private var isSelected = false
    private var isHovered = false
    /// `WorkspaceListState.aggregateStatus` of the session, or nothing for a
    /// tab whose store has not run yet.
    private var status: AgentStatus?

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

    func apply(tab: SessionTab, selected: Bool, status: AgentStatus?) {
        self.tab = tab
        isSelected = selected
        self.status = status
        toolTip = tab.sessionName.rawValue
        if let status, status.deservesBadge {
            setAccessibilityLabel("\(tab.displayName), \(status.rawValue)")
        } else {
            setAccessibilityLabel(tab.displayName)
        }
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

        if let status, status.deservesBadge {
            // Bottom-right, overlapping the tile's corner. The ring is cleared
            // rather than stroked so it shows the sidebar behind, not a colour
            // that would have to be guessed.
            let badge = NSRect(
                x: tileRect.maxX - Self.badgeSize + Self.badgeRing,
                y: tileRect.minY - Self.badgeRing,
                width: Self.badgeSize,
                height: Self.badgeSize
            )
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: badge.insetBy(dx: -Self.badgeRing, dy: -Self.badgeRing)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            status.dotColor.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
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
