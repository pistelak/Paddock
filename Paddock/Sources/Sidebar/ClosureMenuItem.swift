import AppKit

/// An `NSMenuItem` that runs a closure, so a menu can be built from Swift
/// values without a `representedObject` box, an `@objc` target and an `as?`
/// on `Any` at the other end — the three copies of that pattern this replaces
/// each carried their own payload struct.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let perform: @MainActor () -> Void

    init(title: String, perform: @escaping @MainActor () -> Void) {
        self.perform = perform
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        perform()
    }
}
