import AppKit

/// A Slack-style session tile: rounded colour square with initials, a ring
/// when selected, a lighter fill on hover, and in the bottom-right corner the
/// session's `TileIndicator`: a red number for spaces waiting on the user, a
/// green check for a finished one, a blue dot for a working one. A tile whose
/// connection is not live is drawn dimmed and its tooltip says why.
@MainActor
final class SessionTabItemView: NSView {
    static let size = NSSize(width: 44, height: 44)
    private static let tileInset: CGFloat = 4
    private static let cornerRadius: CGFloat = 9
    private static let dotSize: CGFloat = 10
    private static let badgeHeight: CGFloat = 16
    /// The gap between the mark and the tile, cut out of the tile so the mark
    /// reads as sitting on top of it whatever the tile colour.
    private static let markRing: CGFloat = 2
    private static let dimmedAlpha: CGFloat = 0.5

    let tabID: UUID
    var onSelect: ((UUID) -> Void)?
    var onContextMenu: ((UUID, NSEvent) -> Void)?

    private(set) var tab: SessionTab
    private var isSelected = false
    private var isHovered = false
    private var indicator: TileIndicator

    init(tab: SessionTab) {
        tabID = tab.id
        self.tab = tab
        indicator = .none(displayName: tab.displayName, sessionName: tab.sessionName.rawValue)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = indicator.tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(indicator.accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { Self.size }

    func apply(tab: SessionTab, selected: Bool, indicator: TileIndicator) {
        self.tab = tab
        isSelected = selected
        self.indicator = indicator
        toolTip = indicator.tooltip
        setAccessibilityLabel(indicator.accessibilityLabel)
        alphaValue = indicator.isDimmed ? Self.dimmedAlpha : 1
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

        if let mark = indicator.mark {
            drawMark(mark, on: tileRect)
        }
    }

    /// The corner mark, bottom-right and overlapping the tile's corner. The
    /// ring around it is cleared rather than stroked so it shows the sidebar
    /// behind, not a colour that would have to be guessed.
    private func drawMark(_ mark: TileIndicator.Mark, on tileRect: NSRect) {
        let shape: NSBezierPath
        var label: NSAttributedString?
        switch mark {
        case let .attention(count):
            let text = count > 9 ? "9+" : String(count)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ])
            label = attributed
            let width = max(Self.badgeHeight, attributed.size().width + 8)
            // Right edge where the dot's would be, so the cleared ring stays
            // inside the view instead of being clipped at its edge.
            let rect = NSRect(
                x: tileRect.maxX + Self.markRing - width,
                y: tileRect.minY - Self.markRing,
                width: width,
                height: Self.badgeHeight
            )
            shape = NSBezierPath(roundedRect: rect, xRadius: Self.badgeHeight / 2, yRadius: Self.badgeHeight / 2)
        case .done, .working:
            let rect = NSRect(
                x: tileRect.maxX - Self.dotSize + Self.markRing,
                y: tileRect.minY - Self.markRing,
                width: Self.dotSize,
                height: Self.dotSize
            )
            shape = NSBezierPath(ovalIn: rect)
        }

        // A ring `markRing` wider all round.
        let ringRect = shape.bounds.insetBy(dx: -Self.markRing, dy: -Self.markRing)
        let ringPath = mark.isBadge
            ? NSBezierPath(roundedRect: ringRect, xRadius: ringRect.height / 2, yRadius: ringRect.height / 2)
            : NSBezierPath(ovalIn: ringRect)
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        ringPath.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        mark.color.setFill()
        shape.fill()

        if let label {
            let size = label.size()
            label.draw(at: NSPoint(x: shape.bounds.midX - size.width / 2, y: shape.bounds.midY - size.height / 2))
        } else if case .done = mark {
            // A check: two strokes inside the dot, white, so "finished" is a
            // shape and not only a colour.
            let b = shape.bounds
            let check = NSBezierPath()
            check.move(to: NSPoint(x: b.minX + b.width * 0.27, y: b.minY + b.height * 0.50))
            check.line(to: NSPoint(x: b.minX + b.width * 0.44, y: b.minY + b.height * 0.32))
            check.line(to: NSPoint(x: b.minX + b.width * 0.74, y: b.minY + b.height * 0.68))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
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
