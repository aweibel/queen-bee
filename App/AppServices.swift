import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import QueenBeeCore

/// What the whole app shares: where its files are, the socket the helper talks to,
/// and which open flow each session belongs to.
@Observable
final class AppServices {
    static let shared = AppServices()

    @ObservationIgnored let supportDirectory: URL
    @ObservationIgnored let socketPath: String
    @ObservationIgnored let helperPath: String
    @ObservationIgnored let pluginDirectory: URL
    /// Nil until the login shell has been asked for its PATH.
    private(set) var environment: ResolvedEnvironment?
    /// Why the app can't start sessions, shown in every window.
    private(set) var problem: String?

    /// The project folders in the sidebar, in the order they were added.
    private(set) var projects: [ProjectModel] = []
    /// The flow on the canvas.
    var selectedFlowID: String? {
        didSet {
            guard selectedFlowID != oldValue else { return }
            // Going into a sub-flow sets the trail first. Any other change of flow starts a new one.
            if flowTrail.last != selectedFlowID { flowTrail = selectedFlowID.map { [$0] } ?? [] }
            current?.open()
        }
    }
    /// How much of the canvas the floating panels cover, published by the window for the canvas.
    @ObservationIgnored var canvasObstruction = CanvasObstruction(left: 400, right: 450)
    /// Saved agent roles, shared by every flow.
    private(set) var roles: [AgentRole] = []
    private var rolesURL: URL { supportDirectory.appendingPathComponent("roles.json") }

    private func loadRoles() {
        guard let data = try? Data(contentsOf: rolesURL), let saved = try? JSONDecoder().decode([AgentRole].self, from: data) else { return }
        roles = saved
    }

    private func saveRoles() {
        guard let data = try? JSONEncoder().encode(roles) else { return }
        try? data.write(to: rolesURL, options: .atomic)
    }

    /// Saves a role, replacing the one with the same id, or with the same name when it is new.
    @discardableResult
    func save(_ role: AgentRole) -> AgentRole {
        var role = role
        if let index = roles.firstIndex(where: { $0.id == role.id }) {
            roles[index] = role
        } else if let index = roles.firstIndex(where: { $0.name.caseInsensitiveCompare(role.name) == .orderedSame }) {
            role.id = roles[index].id
            roles[index] = role
        } else {
            roles.append(role)
        }
        saveRoles()
        return role
    }

    func deleteRole(_ id: String) {
        roles.removeAll { $0.id == id }
        saveRoles()
    }

    /// The way into the flow on screen: the flow it was opened from, and that one's, back to
    /// the first. One entry when the flow was picked directly.
    private(set) var flowTrail: [String] = []

    /// Opens a sub-flow from the flow whose Flow card runs it, remembering the way back.
    func enter(_ inner: FlowController, from outer: FlowController) {
        let upTo = flowTrail.firstIndex(of: outer.flow.id).map { Array(flowTrail[...$0]) } ?? [outer.flow.id]
        flowTrail = upTo + [inner.flow.id]
        selectedFlowID = inner.flow.id
    }

    /// Goes back up the trail to one of the flows on it.
    func goBack(to flowID: String) {
        guard let index = flowTrail.firstIndex(of: flowID) else { return }
        flowTrail = Array(flowTrail[...index])
        selectedFlowID = flowID
    }

    /// The find panel is open.
    var showsFind = false
    /// The first-run walk-through is on screen.
    var showsWelcome = false
    /// Blank flows whose pointer to the orchestrator has been closed.
    private(set) var dismissedHints: Set<String> = []
    private static let hintsKey = "dismissedOrchestratorHints"

    func dismissHint(forFlow id: String) {
        dismissedHints.insert(id)
        if remembersProjects { UserDefaults.standard.set(dismissedHints.sorted(), forKey: Self.hintsKey) }
    }

    /// Puts away the app's own message. It comes back if the problem does.
    func dismissProblem() {
        problem = nil
    }

    func closeWelcome() {
        showsWelcome = false
        if remembersProjects { UserDefaults.standard.set(true, forKey: OnboardingView.seenKey) }
    }

    /// Flows kept at the top of the sidebar.
    private(set) var pinnedFlowIDs: Set<String> = []

    @ObservationIgnored private var controllers: [String: WeakController] = [:]
    @ObservationIgnored private var serverTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    private init() {
        // QB_SUPPORT_DIR lets a test copy of the app keep its socket and plugin apart from the real one's.
        if TestHarness.isEnabled, let override = ProcessInfo.processInfo.environment["QB_SUPPORT_DIR"], !override.isEmpty {
            supportDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // A build from source keeps its socket, plugin, roles and history apart from an installed copy's.
            #if DEBUG
            supportDirectory = base.appendingPathComponent("QueenBee-Dev", isDirectory: true)
            #else
            supportDirectory = base.appendingPathComponent("QueenBee", isDirectory: true)
            #endif
        }
        socketPath = supportDirectory.appendingPathComponent("qb.sock").path
        helperPath = Bundle.main.url(forAuxiliaryExecutable: "qb")?.path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/qb").path
        pluginDirectory = supportDirectory.appendingPathComponent("plugin/qb-link", isDirectory: true)
    }

    /// Runs once at launch: finds `claude`, puts the plugin where Claude Code can write
    /// beside it, and opens the socket.
    func start() {
        guard !didStart else { return }
        didStart = true
        // The socket and the plugin live here, so only this account may look inside.
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        installPlugin()
        startServer()
        loadRoles()
        loadTold()
        // Also a backstop for flow files the watcher missed while the app was in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppServices.shared.projects.forEach { $0.rescan() } }
        }
        restoreProjects()
        RemoteHost.shared.start()
        // A test run isn't a first run, unless it asks to see the walk-through.
        showsWelcome = remembersProjects ? !UserDefaults.standard.bool(forKey: OnboardingView.seenKey) : LaunchArguments.welcome
        if remembersProjects { dismissedHints = Set(UserDefaults.standard.stringArray(forKey: Self.hintsKey) ?? []) }
        Task {
            let resolved = await ResolvedEnvironment.resolve()
            self.environment = resolved
            if resolved.claude == nil {
                self.problem = "Queen Bee can't find Claude Code. Install it from claude.com/claude-code, then reopen Queen Bee."
            }
        }
    }

    /// Claude Code writes type files into a plugin's folder when it loads it, so the copy
    /// it loads lives in Application Support, not inside the app bundle.
    private func installPlugin() {
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("qb-link") else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: pluginDirectory)
        do {
            try fm.copyItem(at: bundled, to: pluginDirectory)
        } catch {
            problem = "Queen Bee couldn't set up the link between its agents: \(error.localizedDescription)"
        }
    }

    // MARK: Projects and flows

    private static let projectsKey = "projects"
    private static let pinnedKey = "pinnedFlows"
    private static let trustedKey = "trustedProjects"

    /// Whether flows already saved in `root` may be opened. Opening a flow starts sessions with the
    /// instructions, folders and permissions in its file, so a folder that arrives with flows in it,
    /// such as a cloned repository, is only opened once the person has said they trust it.
    func confirmTrust(_ root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        var trusted = Set(UserDefaults.standard.stringArray(forKey: Self.trustedKey) ?? [])
        if trusted.contains(path) || TestHarness.isEnabled { return true }
        let flows = (try? FileManager.default.contentsOfDirectory(at: FlowStore(root: root).directory, includingPropertiesForKeys: nil)) ?? []
        if flows.contains(where: { $0.pathExtension == "json" }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Trust the flows in “\(root.lastPathComponent)”?"
            alert.informativeText = "This folder already has Queen Bee flows in it. Opening them starts Claude Code agents that follow the instructions saved in those files, with the permissions those files give them. Only continue if you trust where this folder came from."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Trust and Open")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
        }
        trusted.insert(path)
        UserDefaults.standard.set(trusted.sorted(), forKey: Self.trustedKey)
        return true
    }
    /// A test run opens scratch folders, which shouldn't come back the next time the app starts.
    private var remembersProjects: Bool { !TestHarness.isEnabled }

    var allFlows: [FlowController] { projects.flatMap(\.controllers) }
    var current: FlowController? { allFlows.first { $0.flow.id == selectedFlowID } }
    var openProjectPaths: [String] { projects.map(\.root.path) }

    /// Puts back the folders that were in the sidebar last time, then the one named on the command line.
    private func restoreProjects() {
        if remembersProjects {
            pinnedFlowIDs = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? [])
            for path in UserDefaults.standard.stringArray(forKey: Self.projectsKey) ?? []
            where FileManager.default.fileExists(atPath: path) {
                addProject(URL(fileURLWithPath: path), select: false)
            }
        }
        var shown = false
        for path in LaunchArguments.takeFolders() where confirmTrust(URL(fileURLWithPath: path)) {
            let project = addProject(URL(fileURLWithPath: path), select: !shown)
            if project.controllers.isEmpty, !shown { project.newFlow() }
            shown = true
        }
        if !shown, selectedFlowID == nil { selectedFlowID = allFlows.first?.flow.id }
    }

    @discardableResult
    func addProject(_ root: URL, select: Bool = true) -> ProjectModel {
        let key = root.standardizedFileURL
        let project = projects.first { $0.root == key } ?? {
            let made = ProjectModel(root: key)
            projects.append(made)
            rememberProjects()
            return made
        }()
        if select, let first = project.controllers.first { selectedFlowID = first.flow.id }
        return project
    }

    /// Takes a folder out of the sidebar. Its flows stay on disk.
    func removeProject(_ project: ProjectModel) {
        let wasCurrent = project.controllers.contains { $0.flow.id == selectedFlowID }
        project.close()
        projects.removeAll { $0 === project }
        rememberProjects()
        if wasCurrent { selectedFlowID = allFlows.first?.flow.id }
    }

    private func rememberProjects() {
        guard remembersProjects else { return }
        UserDefaults.standard.set(projects.map(\.root.path), forKey: Self.projectsKey)
    }

    func togglePin(_ flowID: String) {
        if !pinnedFlowIDs.insert(flowID).inserted { pinnedFlowIDs.remove(flowID) }
        if remembersProjects { UserDefaults.standard.set(pinnedFlowIDs.sorted(), forKey: Self.pinnedKey) }
    }

    func shutDown() {
        RemoteHost.shared.shutDown()
        projects.forEach { $0.close() }
        unlink(socketPath)
    }

    func register(_ controller: FlowController) {
        controllers[controller.flow.id] = WeakController(controller)
    }

    func unregister(flowID: String) {
        controllers[flowID] = nil
    }

    // MARK: What sessions have been told

    /// What a Claude Code session knows of its instructions. A session that is resumed keeps the instructions it
    /// was first started with, whatever it is started with now, so anything newer has to be handed to it.
    private struct Told: Codable {
        /// The instructions the session was first started with, as a stamp.
        var born: String?
        /// The newer instructions handed to it since, as a stamp.
        var delivered: String?
        /// The capabilities reference it was last pointed at, as a stamp.
        var reference: String?
    }

    @ObservationIgnored private var told: [String: Told] = [:]
    private var toldURL: URL { supportDirectory.appendingPathComponent("sessions-told.json") }

    private func loadTold() {
        guard let data = try? Data(contentsOf: toldURL), let saved = try? JSONDecoder().decode([String: Told].self, from: data) else { return }
        told = saved
    }

    private func saveTold() {
        guard let data = try? JSONEncoder().encode(told) else { return }
        try? data.write(to: toldURL, options: .atomic)
    }

    static func stamp(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// A session is being started for the first time, with these instructions.
    func noteBorn(session id: String, instructions: String) {
        told[id] = Told(born: Self.stamp(instructions))
        saveTold()
    }

    /// Whether a session that has just started needs to be handed `instructions`, because they aren't the ones
    /// it was first started with and it hasn't been handed them since. `afresh` is true when the session's
    /// context was cleared or summarised, which loses whatever it was handed before.
    func needsInstructions(session id: String, instructions: String, afresh: Bool) -> Bool {
        let now = Self.stamp(instructions)
        var record = told[id] ?? Told()
        guard record.born != now else { return false }
        guard afresh || record.delivered != now else { return false }
        record.delivered = now
        told[id] = record
        saveTold()
        return true
    }

    /// Whether the capabilities reference has changed since this session was last pointed at it.
    func referenceChanged(forSession id: String, afresh: Bool) -> Bool {
        let now = Self.stamp(Capabilities.reference)
        var record = told[id] ?? Told()
        guard afresh || record.reference != now else { return false }
        record.reference = now
        told[id] = record
        saveTold()
        return true
    }

    #if DEBUG
    /// Makes every session look as if it had been started by an earlier version of the app.
    func testForgetWhatSessionsWereTold() {
        told = told.mapValues { _ in Told(born: "an earlier version") }
    }
    #endif

    // MARK: Socket

    /// What each session was told to call itself, and the session key that belongs to.
    @ObservationIgnored private var credentials: [String: String] = [:]
    @ObservationIgnored private var credentialOwners: [String: String] = [:]

    /// The `QB_SESSION` value for the session `key` ("<flowID>/<cardID>" or "<flowID>/orchestrator"): the key
    /// with a secret on the end. The helper sends it back with every request, which is how the app knows
    /// which session is really asking.
    func credential(for key: String) -> String {
        if let known = credentials[key] { return known }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let made = key + "#" + bytes.map { String(format: "%02x", $0) }.joined()
        credentials[key] = made
        credentialOwners[made] = key
        return made
    }

    private func startServer() {
        let path = socketPath
        unlink(path)
        serverTask = Task.detached {
            do {
                let listener = try NetworkListener<TCP>(
                    using: NWParametersBuilder.parameters { TCP() }.localEndpoint(.unix(path: path)))
                try await listener.run { connection in
                    // One request and one reply per connection, each a 4-byte length then JSON.
                    let header = try await connection.receive(exactly: 4)
                    let length = header.content.reduce(0) { ($0 << 8) | Int($1) }
                    guard length > 0, length < 64_000_000 else { return }
                    let body = try await connection.receive(exactly: length)
                    let reply: JSONValue
                    if let request = try? JSONDecoder().decode(WireRequest.self, from: Data(body.content)) {
                        reply = await AppServices.shared.handle(request)
                    } else {
                        reply = ["error": "unreadable request"]
                    }
                    try await connection.send(Wire.frame(reply.data()))
                }
            } catch {
                await MainActor.run { AppServices.shared.problem = "Queen Bee couldn't start listening for its agents: \(error.localizedDescription)" }
            }
        }
    }

    /// Answers one helper request. `session` is "<flowID>/<cardID>" or "<flowID>/orchestrator".
    func handle(_ request: WireRequest) async -> JSONValue {
        var parts = request.session.split(separator: "/", maxSplits: 1).map(String.init)
        if request.kind != "test" {
            // Who is asking comes from the secret, never from the name the request gives itself.
            guard let owner = credentialOwners[request.session] else { return fallback(for: request) }
            parts = owner.split(separator: "/", maxSplits: 1).map(String.init)
        }
        if request.kind == "test" {
            guard TestHarness.isEnabled else { return ["error": "testing is off"] }
            if let reply = await TestHarness.handleRemote(request.payload) { return reply }
            guard parts.count == 2, let controller = controllers[parts[0]]?.value else { return TestHarness.handleApp(request.payload) }
            return await TestHarness.handle(request.payload, controller: controller)
        }
        guard parts.count == 2, let controller = controllers[parts[0]]?.value else {
            return fallback(for: request)
        }
        let who = parts[1]
        switch request.kind {
        case "hook":
            return controller.handleHook(from: who, payload: request.payload)
        case "route":
            let deliveries = await controller.handleRoute(from: who, answer: request.payload["answer"]?.stringValue ?? "",
                                                          asked: request.payload["asked"]?.boolValue == true)
            return ["deliveries": .array(deliveries.map { ["to": .string($0.to), "text": .string($0.text)] })]
        case "sent":
            controller.handleSent(from: who, results: request.payload["results"]?.arrayValue ?? [])
            return [:]
        case "may-send":
            let verdict = controller.judgeSend(from: who, to: request.payload["to"]?.stringValue ?? "")
            if let reason = verdict.refusal { return ["allowed": false, "reason": .string(reason)] }
            return ["allowed": true, "sessionId": verdict.sessionID.map(JSONValue.string) ?? .null, "inFlow": .bool(verdict.inFlow)]
        case "mcp":
            // The tools edit and run the flow, so they answer only to the orchestrator's secret. That keeps an
            // agent from reaching them through its own helper; it is not a wall against an agent that can run
            // any command as the person, which could read another of their processes' environment.
            guard who == FlowController.orchestratorKey else { return fallback(for: request) }
            return await MCPServer.handle(request.payload, host: controller) ?? .null
        case "browser-mcp":
            // An agent reaches only the tab of its own card, and only while that card's Browser switch is on.
            // Which card is asking comes from the session's secret, like everything else here.
            guard let tab = controller.browserTab(forCard: who) else { return fallback(for: request) }
            return await MCPServer.handleBrowser(request.payload, host: tab) ?? .null
        default:
            return fallback(for: request)
        }
    }

    /// What to say when the flow a session belongs to isn't open.
    private func fallback(for request: WireRequest) -> JSONValue {
        switch request.kind {
        case "route": return ["deliveries": []]
        case "may-send": return ["allowed": true]
        case "mcp":
            guard let id = request.payload["id"], !id.isNull else { return .null }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "This flow isn't open in Queen Bee."]]
        case "browser-mcp":
            guard let id = request.payload["id"], !id.isNull else { return .null }
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "This agent's card has no browser. The person can turn one on in the card's settings."]]
        default: return [:]
        }
    }
}

/// The strips at the canvas's left and right that floating panels sit over, in screen points.
nonisolated struct CanvasObstruction: Equatable, Sendable {
    var left: CGFloat
    var right: CGFloat
}

private struct WeakController {
    weak var value: FlowController?
    init(_ value: FlowController) { self.value = value }
}
