import AppKit
import SwiftTerm

/// The terminal a session's process runs in.
///
/// SwiftTerm's own `LocalProcessTerminalView` hands the process's output straight to its
/// renderer and lets nobody else see the bytes. This view does the same job the same way,
/// and also keeps what was printed in `output`, so a paired device can be shown the terminal.
final class SessionTerminalView: TerminalView, TerminalViewDelegate {
    /// What the process printed lately.
    nonisolated let output = OutputLog()
    private(set) var process: LocalProcess!
    private var link: ProcessLink!
    /// Called once the process has gone, with its exit code if it left one.
    var onExit: ((Int32?) -> Void)?
    /// Called when the terminal has a new number of columns or rows.
    var onResize: (() -> Void)?
    private var columns = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        link = ProcessLink(feed: feedSender, output: output) { [weak self] code in self?.exited(code) }
        // Output is parsed on the thread that read it, as SwiftTerm's own view does; only the
        // process ending comes back to the main thread.
        process = LocalProcess(delegate: link, dispatchQueue: .main, directDelivery: true)
        link.windowSize = windowSize()
        columns = terminalDimensions.cols
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func startProcess(executable: String, args: [String], environment: [String]?, currentDirectory: String?) {
        link.windowSize = windowSize()
        process.startProcess(executable: executable, args: args, environment: environment, currentDirectory: currentDirectory)
    }

    func terminate() { process.terminate() }

    private func exited(_ code: Int32?) {
        programStatusProcessExited()
        onExit?(code)
    }

    /// The size the process is told its terminal has.
    private func windowSize() -> winsize {
        let size = terminalDimensions
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let points = getOptimalFrameSize().size
        return winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols),
                       ws_xpixel: UInt16(clamping: Int(points.width * scale)), ws_ypixel: UInt16(clamping: Int(points.height * scale)))
    }

    // MARK: What the terminal asks of its host

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Forgotten before the process hears of the new size: it repaints as soon as it does, on another
        // thread, and forgetting afterwards could throw away the start of that repaint.
        if newCols < columns { output.forget() }
        columns = newCols
        var size = windowSize()
        link.windowSize = size
        _ = process.updateWindowSize(&size)
        onResize?()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { process.send(data: data) }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(bytes: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? { NSPasteboard.general.string(forType: .string)?.data(using: .utf8) }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // A program in the terminal gets no say over the clipboard beyond plain copy and paste.
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
}

/// Stands between the process and the terminal. The process calls it on the thread that
/// reads its output, so nothing here may touch the view itself.
private nonisolated final class ProcessLink: LocalProcessDelegate, @unchecked Sendable {
    private let feed: TerminalFeedSender
    private let output: OutputLog
    private let exited: @MainActor @Sendable (Int32?) -> Void
    private let lock = NSLock()
    private var size = winsize()

    init(feed: TerminalFeedSender, output: OutputLog, exited: @escaping @MainActor @Sendable (Int32?) -> Void) {
        self.feed = feed
        self.output = output
        self.exited = exited
    }

    var windowSize: winsize {
        get { lock.withLock { size } }
        set { lock.withLock { size = newValue } }
    }

    func getWindowSize() -> winsize { windowSize }

    func dataReceived(slice: ArraySlice<UInt8>) {
        feed.feed(byteArray: slice)
        output.append(slice)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor in exited(exitCode) }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        dataReceived(slice: Array("\r\nProcess launch failed: \(error)\r\n".utf8)[...])
    }
}
