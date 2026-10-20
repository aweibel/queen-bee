import AppKit
import Observation
import QueenBeeCore

extension SessionState {
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
    @ObservationIgnored let view: SessionTerminalView
    /// What the terminal shows, for a paired device. Nothing runs for it until it is first asked for.
    @ObservationIgnored private(set) lazy var feed: TerminalFeed = makeFeed()
    private(set) var state: SessionState = .notStarted {
        didSet {
            guard state != oldValue else { return }
            if state != .starting { isSlowToStart = false }
            KeepAwake.note(self, live: isLive, working: state == .working)
        }
    }
    /// Claude Code was started a while ago and hasn't said it is ready. It may be asking something in the terminal,
    /// such as whether to trust the folder, or it may be stuck. Nothing is typed into it meanwhile.
    private(set) var isSlowToStart = false
    /// How long a session may take to say it is ready before its card says so.
    static let slowToStartAfter: Duration = .seconds(20)
    /// The session's last finished reply, as its turn-end reported it.
    var lastReply: String?
    /// The card settings this session was started with. A running session keeps these until
    /// it restarts, whatever the card says now.
    private(set) var launched: AgentSettings?
    /// The standing instructions this session was started with. The orchestrator has no card settings, so this
    /// is how the app tells that its instructions have changed since.
    private(set) var launchedInstructions: String?
    /// The Claude Code session id this terminal was started with.
    private(set) var claudeSessionID: String?
    @ObservationIgnored var onExit: ((Int32?) -> Void)?

    /// Typed input waiting for the session to go idle.
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var readyAt: Date = .distantFuture
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    /// The PreCompact hook said the next summary was asked for with /compact, not made in the middle of a turn.
    @ObservationIgnored private var compactedByPerson = false
    /// Counts launches, so the check on a slow start only looks at the launch that set it going.
    @ObservationIgnored private var launches = 0

    // A session let go while still live mustn't keep the Mac awake for good.
    isolated deinit {
        KeepAwake.note(self, live: false, working: false)
    }

    init(key: String) {
        self.key = key
        view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        super.init()
        view.font = Theme.mono(12)
        view.onExit = { [weak self] code in self?.processExited(code) }
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

    private func makeFeed() -> TerminalFeed {
        let view = view
        let feed = OutputFeed(log: view.output) {
            let size = view.terminalDimensions
            return (size.cols, size.rows)
        }
        view.onResize = { [weak feed] in feed?.sizeChanged() }
        return feed
    }

    var isLive: Bool { state != .notStarted && state != .exited }

    func start(_ spec: LaunchSpec, settings: AgentSettings? = nil, instructions: String? = nil) {
        guard !isLive else { return }
        launched = settings
        launchedInstructions = instructions
        claudeSessionID = spec.sessionID
        state = .starting
        launches += 1
        let launch = launches
        view.startProcess(executable: spec.executable, args: spec.arguments, environment: spec.environment,
                          currentDirectory: spec.workingDirectory)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.slowToStartAfter)
            guard let self, self.launches == launch, self.state == .starting else { return }
            self.isSlowToStart = true
        }
    }

    /// Ends the session on purpose. That is not the session exiting, so `onExit` isn't told.
    func terminate() {
        onExit = nil
        guard isLive else { return }
        view.terminate()
        state = .exited
    }

    /// Stops the turn under way, as Esc does at the keyboard, and drops input waiting to be typed. For a run
    /// that has been stopped: its agents shouldn't go on working, or spending, on what nothing will use.
    func interrupt() {
        waiting.removeAll()
        guard state == .working || state == .needsYou else { return }
        view.send(txt: "\u{1b}")
        // Claude Code reports no turn end for a turn cut short, so the session is taken to be back at its prompt.
        state = .idle
    }

    /// Applies a hook event to the state. Returns false for events that change nothing.
    @discardableResult
    func apply(hook event: String, notificationType: String?, source: String? = nil, trigger: String? = nil) -> Bool {
        switch event {
        case "SessionStart":
            let next = state.afterSessionStart(source: source, compactedByPerson: compactedByPerson)
            compactedByPerson = false
            // A summary made mid-turn: the turn goes on, and what is waiting to be typed waits for it to end.
            guard next == .idle else { return false }
            // The prompt box takes a moment to accept input after the hook fires.
            readyAt = Date().addingTimeInterval(1.5)
            state = .idle
            flushSoon()
        case "PreCompact":
            compactedByPerson = trigger == "manual"
            return false
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

    /// Key presses from a paired device, written to the process as the terminal writes the Mac's own.
    func type(_ keys: Data) {
        guard isLive else { return }
        view.send(source: view, data: [UInt8](keys)[...])
    }

    private func processExited(_ exitCode: Int32?) {
        state = .exited
        waiting.removeAll()
        onExit?(exitCode)
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
