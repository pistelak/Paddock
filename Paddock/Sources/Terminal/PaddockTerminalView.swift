import AppKit
import GhosttyTerminal

/// `AppTerminalView` plus what the package leaves to the host on macOS:
/// accepting drops. Dropped files paste as escaped paths, dropped text as
/// text, both through the paste path so bracketed paste applies.
@MainActor
final class PaddockTerminalView: AppTerminalView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropPayload.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DropPayload.text(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = DropPayload.text(from: sender.draggingPasteboard) else { return false }
        acquireProgrammaticFocus()
        return paste(text: text)
    }
}
