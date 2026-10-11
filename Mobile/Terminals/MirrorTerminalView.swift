import SwiftTerm
import UIKit

/// A terminal that only shows. It is fed what a session on the Mac printed and gives nothing back: no
/// keyboard, no taps, no answers to the questions the program asks its terminal. In the full-screen view a
/// finger scrolls it back through earlier output, and that is all a finger does.
final class MirrorTerminalView: TerminalView {
    /// Takes whatever the terminal would send to its program, and keeps none of it.
    private let sink = ReplySink()

    /// How many times the terminal tried to send something, and how many bytes that came to. The stream
    /// holds the program's own questions (what kind of terminal, what colours, which keyboard mode), so
    /// these go up in ordinary use. Nothing counted here ever leaves the device.
    var droppedReplies: (count: Int, bytes: Int) { (sink.count, sink.bytes) }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 520, height: 320), font: Theme.mono(Theme.Size.body))
        terminalDelegate = sink
        // The bar of extra keys SwiftTerm puts over the keyboard. There is no keyboard.
        inputAccessoryView = nil
        // SwiftTerm's taps select text, open links and bring up the keyboard. Only the scroll view's own
        // drag is kept.
        for recognizer in gestureRecognizers ?? [] where recognizer !== panGestureRecognizer {
            removeGestureRecognizer(recognizer)
        }
        interactions.forEach(removeInteraction)
        // A program that asked for the mouse would otherwise be sent the drag in place of it scrolling.
        allowMouseReporting = false
        linkReporting = .none
        bellStyle = .none
        isAccessibilityElement = false
        showsHorizontalScrollIndicator = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// SwiftTerm 1.99.0 moves to the rows a finger has scrolled to and doesn't ask for them to be drawn,
    /// so they come up blank until something else changes. Setting the cursor's style to what it already
    /// is has no effect but to ask for a new frame.
    override var contentOffset: CGPoint {
        didSet {
            guard contentOffset.y != oldValue.y, isTracking || isDecelerating else { return }
            setCursorStyle(terminalStateSnapshot().cursorStyle)
        }
    }

    // Without these a hardware keyboard, or a tap that slipped through, could still type into it.
    override var canBecomeFirstResponder: Bool { false }
    override var canBecomeFocused: Bool { false }
}

/// Where everything a mirror terminal tries to send ends up. It counts what it was handed, for a test to
/// see that replies were made and went nowhere.
private final class ReplySink: TerminalViewDelegate {
    private(set) var count = 0
    private(set) var bytes = 0

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        count += 1
        bytes += data.count
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}

    // A program on the Mac gets no say over this device's clipboard.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
}
