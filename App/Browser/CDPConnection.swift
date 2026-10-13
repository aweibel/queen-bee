import AppKit
import ImageIO
import QueenBeeCore

/// A picture handed from the thread that reads the browser's pipe to the main thread. A `CGImage` never
/// changes once made, so it is safe to pass along.
struct StreamFrame: @unchecked Sendable {
    let image: CGImage
}

/// A running Chromium browser and the private line the app controls it over.
///
/// The line is a pair of pipes the browser inherits as its descriptors 3 and 4 (`--remote-debugging-pipe`).
/// Nothing else on the Mac can reach it, which a debugging port open on localhost would not be true of.
final class CDPConnection {
    let pid: pid_t
    private let writeFD: Int32
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private(set) var isOpen = true
    /// Writes happen here, in order, so a browser that has stopped reading can't freeze the app's window.
    private let writer = DispatchQueue(label: "dev.queenbee.browser.write")
    /// Messages handed to `writer` and not yet written.
    private var backlog = 0

    /// Something happened in the browser: the event's name, its details, and the tab's session if it has one.
    var onEvent: ((_ method: String, _ params: JSONValue, _ session: String?) -> Void)?
    /// A new picture of a tab, with the number to acknowledge it by.
    var onFrame: ((_ session: String, _ frame: StreamFrame, _ ack: Int) -> Void)?
    /// The browser's process has ended, whether it was asked to or not.
    var onClose: (() -> Void)?

    init(executable: String, arguments: [String]) throws {
        let started = try Self.spawn(executable, arguments)
        pid = started.pid
        writeFD = started.toChild
        let readFD = started.fromChild
        let pid = started.pid
        Thread.detachNewThread { [weak self] in
            Self.readLoop(fd: readFD, pid: pid) { incoming in
                Task { @MainActor in self?.receive(incoming) }
            }
        }
    }

    // MARK: Talking

    /// Sends one command and waits for the browser's answer.
    func send(_ method: String, _ params: JSONValue = [:], session: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        guard isOpen else { throw BrowserError("The browser has stopped") }
        nextID += 1
        let id = nextID
        let data = CDP.command(id: id, method: method, params: params, sessionID: session)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            write(data)
            // A page that has hung must not hang the agent's tool call with it.
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.waiting.removeValue(forKey: id)?.resume(throwing: BrowserError("The browser took too long to answer"))
            }
        }
    }

    /// Sends a command whose answer nobody needs, such as a mouse move.
    func post(_ method: String, _ params: JSONValue = [:], session: String? = nil) {
        // Mouse moves and the like pile up behind a browser that is busy. Past a point they are dropped.
        guard isOpen, backlog < 400 else { return }
        nextID += 1
        write(CDP.command(id: nextID, method: method, params: params, sessionID: session))
    }

    /// Queues one message for the browser. A write that fails means the browser has gone, which the reading
    /// thread reports when the pipe closes.
    private func write(_ data: Data) {
        backlog += 1
        let fd = writeFD
        writer.async { [weak self] in
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n > 0 { sent += n } else if errno != EINTR { break }
                }
            }
            Task { @MainActor in self?.backlog -= 1 }
        }
    }

    private func receive(_ incoming: Incoming) {
        switch incoming {
        case .frame(let session, let frame, let ack):
            onFrame?(session, frame, ack)
        case .message(let message):
            if let id = message["id"]?.intValue {
                guard let continuation = waiting.removeValue(forKey: id) else { return }
                if let error = message["error"] {
                    continuation.resume(throwing: BrowserError(error["message"]?.stringValue ?? "The browser refused"))
                } else {
                    continuation.resume(returning: message["result"] ?? [:])
                }
            } else if let method = message["method"]?.stringValue {
                onEvent?(method, message["params"] ?? [:], message["sessionId"]?.stringValue)
            }
        case .closed:
            guard isOpen else { return }
            isOpen = false
            // Behind any write still queued, so the descriptor isn't closed under one.
            let fd = writeFD
            writer.async { Darwin.close(fd) }
            let left = waiting
            waiting.removeAll()
            left.values.forEach { $0.resume(throwing: BrowserError("The browser has stopped")) }
            onClose?()
        }
    }

    /// Asks the browser to quit, and makes sure it does.
    func close() {
        guard isOpen else { return }
        post("Browser.close")
        // A browser that ignores the request is ended anyway. Once it has gone `isOpen` is false, and the
        // signal isn't sent: by then its process id could belong to something else.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if self.isOpen { kill(self.pid, SIGTERM) }
        }
    }

    /// Ends the browser at once, as when the app itself is quitting.
    func terminate() {
        guard isOpen else { return }
        kill(pid, SIGTERM)
    }

    /// True once the process has ended and been collected.
    var hasEnded: Bool { !isOpen }

    // MARK: The reading thread

    private enum Incoming: Sendable {
        case message(JSONValue)
        case frame(session: String, frame: StreamFrame, ack: Int)
        case closed
    }

    nonisolated private static func readLoop(fd: Int32, pid: pid_t, deliver: @escaping @Sendable (Incoming) -> Void) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let streamMark = Data(#""method":"Page.screencastFrame""#.utf8)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            buffer.append(chunk, count: n)
            for body in CDP.messages(from: &buffer) {
                // Pictures arrive many times a second and are large, so they are decoded here, off the main thread.
                if body.prefix(64).range(of: streamMark) != nil {
                    if let frame = Self.frame(from: body) { deliver(frame) }
                } else if let message = try? JSONValue.parse(body) {
                    deliver(.message(message))
                }
            }
        }
        Darwin.close(fd)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        deliver(.closed)
    }

    nonisolated private static func frame(from body: Data) -> Incoming? {
        guard let top = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = top["sessionId"] as? String,
              let params = top["params"] as? [String: Any],
              let ack = params["sessionId"] as? Int,
              let encoded = params["data"] as? String,
              let jpeg = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return .frame(session: session, frame: StreamFrame(image: image), ack: ack)
    }

    // MARK: Starting the process

    /// Starts the browser with a pipe to it on its descriptor 3 and a pipe from it on its descriptor 4, and
    /// nothing else of the app's open in it.
    nonisolated private static func spawn(_ executable: String, _ arguments: [String]) throws -> (pid: pid_t, toChild: Int32, fromChild: Int32) {
        var down: [Int32] = [-1, -1]
        var up: [Int32] = [-1, -1]
        guard pipe(&down) == 0 else { throw BrowserError("Queen Bee couldn't open a line to the browser") }
        guard pipe(&up) == 0 else {
            Darwin.close(down[0]); Darwin.close(down[1])
            throw BrowserError("Queen Bee couldn't open a line to the browser")
        }
        // Moved clear of 3 and 4, so putting the browser's ends there can't land on one of these.
        func lifted(_ fd: Int32) -> Int32 {
            let moved = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            Darwin.close(fd)
            return moved
        }
        let childIn = lifted(down[0]), parentOut = lifted(down[1]), parentIn = lifted(up[0]), childOut = lifted(up[1])
        defer { Darwin.close(childIn); Darwin.close(childOut) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, childIn, 3)
        posix_spawn_file_actions_adddup2(&actions, childOut, 4)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the five descriptors set up above are open in the browser.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        // The app's own variables for its sessions mean nothing to a browser.
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("QB_") && !$0.key.hasPrefix("CLAUDE") }
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else {
            Darwin.close(parentOut); Darwin.close(parentIn)
            throw BrowserError("The browser couldn't be started: \(String(cString: strerror(result)))")
        }
        // Writing to a browser that has just quit should fail, not end the app.
        _ = fcntl(parentOut, F_SETNOSIGPIPE, 1)
        return (pid, parentOut, parentIn)
    }
}
