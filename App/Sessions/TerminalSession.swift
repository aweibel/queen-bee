import AppKit
import Observation
import QueenBeeCore
import SwiftTerm

/// What a session is doing, as Claude Code's hooks report it.
enum SessionState: String {
    case notStarted, starting, idle, working, needsYou, failed, exited

    var label: String {
        switch self {
        case .notStarted: "Not started"
        case .starting: "Starting"
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .exited: "Exited"
        }
    }

    var color: NSColor {
        switch self {
        case .notStarted, .starting, .idle: Theme.inkSecondary
        case .working, .needsYou: Theme.live
        case .failed, .exited: Theme.failInk
        }
    }

    var tone: Badge.Tone {
        switch self {
        case .notStarted, .starting, .idle: .plain
        case .working, .needsYou: .live
        case .failed, .exited: .fail
        }
    }
}

/// One Claude Code session and the terminal it runs in. The terminal view lives here,
/// not in the card, so it survives the canvas rebuilding its views.
@Observable
final class TerminalSession: NSObject {
    /// "<flowID>/<cardID>" or "<flowID>/orchestrator": the QB_SESSION the helper reports as.
    let key: String
    @ObservationIgnored let view: LocalProcessTerminalView
    private(set) var state: SessionState = .notStarted
    /// The session's last finished reply, as its turn-end reported it.
    var lastReply: String?
    /// The card settings this session was started with. A running session keeps these until
    /// it restarts, whatever the card says now.
    private(set) var launched: AgentSettings?
    /// The Claude Code session id this terminal was started with.
    private(set) var claudeSessionID: String?
    @ObservationIgnored var onExit: ((Int32?) -> Void)?

    /// Typed input waiting for the session to go idle.
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var readyAt: Date = .distantFuture
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    init(key: String) {
        self.key = key
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        super.init()
        view.font = Theme.mono(12)
        view.processDelegate = self
        applyTheme()
        // The terminal takes plain colours, so it is told again whenever light and dark swap.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.applyTheme() }
        }
    }

    private func applyTheme() {
        let appearance = NSApp.effectiveAppearance
        view.nativeBackgroundColor = Theme.terminal.fixed(in: appearance)
        view.nativeForegroundColor = Theme.terminalInk.fixed(in: appearance)
    }

    var isLive: Bool { state != .notStarted && state != .exited }

    func start(_ spec: LaunchSpec, settings: AgentSettings? = nil) {
        guard !isLive else { return }
        launched = settings
        claudeSessionID = spec.sessionID
        state = .starting
        view.startProcess(executable: spec.executable, args: spec.arguments, environment: spec.environment,
                          currentDirectory: spec.workingDirectory)
    }

    func terminate() {
        guard isLive else { return }
        view.terminate()
        state = .exited
    }

    /// Applies a hook event to the state. Returns false for events that change nothing.
    @discardableResult
    func apply(hook event: String, notificationType: String?) -> Bool {
        switch event {
        case "SessionStart":
            // The prompt box takes a moment to accept input after the hook fires.
            readyAt = Date().addingTimeInterval(1.5)
            state = .idle
            flushSoon()
        case "UserPromptSubmit": state = .working
        case "PostToolUse":
            // A tool ran, so whatever the session was waiting on you for has been answered.
            guard state == .needsYou else { return false }
            state = .working
        case "Stop":
            state = .idle
            flushSoon()
        case "StopFailure": state = .failed
        case "Notification":
            guard notificationType == "permission_prompt" || notificationType == "agent_needs_input" else { return false }
            state = .needsYou
        case "SessionEnd": state = .exited
        default: return false
        }
        return true
    }

    /// Types `text` into the session as a prompt: now if it is idle, else when it next goes idle.
    func send(_ text: String) {
        waiting.append(text)
        flushSoon()
    }

    private func flushSoon() {
        guard state == .idle, !waiting.isEmpty else { return }
        let delay = max(0, readyAt.timeIntervalSinceNow)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard self.state == .idle, !self.waiting.isEmpty else { return }
            let text = self.waiting.removeFirst()
            // A bracketed paste keeps a multi-line message as one prompt; Enter follows once the paste has landed.
            // The message is cleaned first, so nothing inside it can end the paste and type keys of its own.
            self.view.send(txt: "\u{1b}[200~" + TerminalText.typed(text) + "\u{1b}[201~")
            self.state = .working
            try? await Task.sleep(for: .milliseconds(350))
            self.view.send(txt: "\r")
        }
    }
}

extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        state = .exited
        waiting.removeAll()
        onExit?(exitCode)
    }
}

/// The settings of an agent card that only take hold when its session starts.
nonisolated struct AgentSettings: Equatable, Sendable {
    var name: String
    var instructions: String
    var model: String
    var effort: String
    var permissionMode: String
    var folder: String
    var browser: Bool

    init(_ card: QueenBeeCore.Card) {
        name = card.name
        instructions = (card.instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model = card.model ?? ""
        effort = card.effort ?? ""
        permissionMode = card.permissionMode ?? ""
        folder = card.cwd ?? ""
        browser = card.browser == true
    }

    /// What differs from `other`, named as the settings panel names it.
    func differences(from other: AgentSettings) -> [String] {
        var changed: [String] = []
        if name != other.name { changed.append("name") }
        if instructions != other.instructions { changed.append("instructions") }
        if model != other.model { changed.append("model") }
        if effort != other.effort { changed.append("effort") }
        if permissionMode != other.permissionMode { changed.append("permissions") }
        if folder != other.folder { changed.append("folder") }
        if browser != other.browser { changed.append("browser") }
        return changed
    }
}

/// What to run for a session: the program, its arguments and environment, and the session id it carries.
struct LaunchSpec {
    var executable: String
    var arguments: [String]
    var environment: [String]
    var workingDirectory: String
    var sessionID: String
}
