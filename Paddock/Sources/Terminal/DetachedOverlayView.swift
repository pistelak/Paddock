import AppKit

/// Covers a pane whose herdr client has gone away and offers to start a new
/// one. The herdr session itself keeps running server-side.
@MainActor
final class DetachedOverlayView: NSVisualEffectView {
    var onReattach: (() -> Void)?
    let reattachButton: NSButton

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    private let label: NSTextField

    init(message: String) {
        reattachButton = NSButton(title: "Reattach", target: nil, action: nil)
        label = NSTextField(labelWithString: message)
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active

        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.maximumNumberOfLines = 3

        let hint = NSTextField(labelWithString: "Your panes are still alive in herdr.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        reattachButton.bezelStyle = .rounded
        reattachButton.keyEquivalent = "\r"
        reattachButton.target = self
        reattachButton.action = #selector(reattachPressed)

        let stack = NSStackView(views: [label, hint, reattachButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func reattachPressed() {
        onReattach?()
    }

    // Swallow clicks so they do not reach the (dead) terminal underneath.
    override func mouseDown(with _: NSEvent) {}
}
