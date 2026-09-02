import AppKit

/// The "+" tile below the session tiles.
@MainActor
final class AddTabButton: NSView {
    var onClick: ((NSView) -> Void)?
    private var isHovered = false

    init() {
        super.init(frame: NSRect(origin: .zero, size: SessionTabItemView.size))
        toolTip = "Add session tab"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Add session tab")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { SessionTabItemView.size }

    override func draw(_: NSRect) {
        let tileRect = bounds.insetBy(dx: 4, dy: 4)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 9, yRadius: 9)
        NSColor.labelColor.withAlphaComponent(isHovered ? 0.18 : 0.08).setFill()
        tile.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .light),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSAttributedString(string: "+", attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: tileRect.midX - size.width / 2, y: tileRect.midY - size.height / 2))
    }

    override func mouseDown(with _: NSEvent) {
        onClick?(self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(self)
        return true
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
