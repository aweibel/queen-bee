import AppKit
import CryptoKit
import QueenBeeCore

/// One project's browser: a hidden Chromium that every agent card with a browser in that project shares.
/// Each card has its own tab, and they all have the same sign-ins, kept in a profile that belongs to
/// Queen Bee and to this project.
final class BrowserHost {
    enum State: Equatable {
        /// Nothing has asked for a browser yet.
        case idle
        case starting
        case running
        /// No Chromium-based browser is on this Mac.
        case missing
        /// Chrome for Testing is on its way, with how far along it is.
        case downloading(Double)
        /// It ran and has ended.
        case stopped
        case failed(String)
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { tabs.values.forEach { $0.hostChanged() } } } }
    private let support: URL
    let profile: URL
    private var connection: CDPConnection?
    /// A browser that has been asked to quit and hasn't finished. It still holds the profile.
    private var closing: CDPConnection?
    private var starting: Task<CDPConnection, any Error>?
    private var tabs: [String: BrowserTab] = [:]
    /// What the browser calls itself, without the word that tells sites nobody is looking at it.
    private(set) var userAgent: JSONValue?

    init(projectRoot: URL, support: URL) {
        self.support = support
        // The folder's name can't hold a path, and two projects with the same last name must not share logins.
        let digest = SHA256.hash(data: Data(projectRoot.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        profile = support.appendingPathComponent("browser/\(name)", isDirectory: true)
    }

    // MARK: Tabs

    /// The tab of the card `key` ("<flowID>/<cardID>"), made the first time it is asked for.
    func tab(for key: String) -> BrowserTab {
        if let existing = tabs[key] { return existing }
        let tab = BrowserTab(key: key, host: self)
        tabs[key] = tab
        return tab
    }

    /// A card has lost its browser or gone. Its tab closes, and the browser with the last one.
    func release(_ key: String) {
        guard let tab = tabs.removeValue(forKey: key) else { return }
        tab.close()
        if tabs.isEmpty { shutDown() }
    }

    func releaseAll(withPrefix prefix: String) {
        for key in tabs.keys where key.hasPrefix(prefix) { release(key) }
    }

    func tab(forSession session: String) -> BrowserTab? { tabs.values.first { $0.sessionID == session } }
    func tab(forTarget target: String) -> BrowserTab? { tabs.values.first { $0.targetID == target } }

    // MARK: The process

    /// The line to the running browser, starting it first if it isn't.
    func connected() async throws -> CDPConnection {
        if let connection, connection.isOpen { return connection }
        if let starting { return try await starting.value }
        let task = Task { try await self.start() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func start() async throws -> CDPConnection {
        guard let found = BrowserFinder.find(support: support) else {
            state = .missing
            throw BrowserError("There is no browser for this card to use yet. The person can download one from the card.")
        }
        state = .starting
        do {
            // Two browsers can't share a profile, so one on its way out is waited for.
            if let closing {
                for _ in 0..<60 where closing.isOpen { try? await Task.sleep(for: .milliseconds(100)) }
                self.closing = nil
            }
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            // Sign-ins live here, so only this account may look inside.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.deletingLastPathComponent().path)
            var arguments = [
                "--headless=new", "--remote-debugging-pipe", "--user-data-dir=\(profile.path)",
                "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
                // The page is drawn at twice its size, so the picture in the card is as sharp as the screen.
                "--force-device-scale-factor=2", "--window-size=1100,700",
            ]
            // A browser the person never installed has no keychain entry of its own, and asking for one
            // would put a password prompt on screen from an app they can't see.
            if found.isDownloaded { arguments.append("--use-mock-keychain") }
            arguments.append("about:blank")
            let made = try CDPConnection(executable: found.path, arguments: arguments)
            made.onClose = { [weak self, weak made] in
                // A browser that was asked to quit has already been dealt with. This is for one that went by itself.
                guard let self, let made, self.connection === made else { return }
                self.connection = nil
                self.tabs.values.forEach { $0.detached() }
                self.state = .stopped
            }
            made.onEvent = { [weak self] method, params, session in self?.handle(method, params, session) }
            made.onFrame = { [weak self] session, frame, ack in self?.tab(forSession: session)?.show(frame, ack: ack) }

            let version = try await made.send("Browser.getVersion", timeout: 20)
            userAgent = Self.userAgent(from: version)
            // New windows a page opens are seen here, so they can be shown in the card that opened them.
            _ = try await made.send("Target.setDiscoverTargets", ["discover": true])
            // A hidden browser has nowhere for the person to see a download land, so there are none.
            _ = try? await made.send("Browser.setDownloadBehavior", ["behavior": "deny"])
            connection = made
            state = .running
            return made
        } catch {
            let words = (error as? BrowserError)?.description ?? error.localizedDescription
            state = .failed(words)
            throw BrowserError(words)
        }
    }

    /// The browser's own description of itself with "Headless" taken out, and the matching hints that
    /// sites ask for. Many sites turn away a browser that says nobody is looking at it.
    private static func userAgent(from version: JSONValue) -> JSONValue? {
        guard let agent = version["userAgent"]?.stringValue else { return nil }
        let product = version["product"]?.stringValue ?? ""
        let full = product.split(separator: "/").last.map(String.init) ?? ""
        let major = full.split(separator: ".").first.map(String.init) ?? ""
        let brands: JSONValue = [
            ["brand": "Chromium", "version": .string(major)],
            ["brand": "Google Chrome", "version": .string(major)],
            ["brand": "Not?A_Brand", "version": "99"],
        ]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "userAgent": .string(agent.replacingOccurrences(of: "HeadlessChrome", with: "Chrome")),
            "userAgentMetadata": [
                "brands": brands, "fullVersion": .string(full), "platform": "macOS",
                "platformVersion": .string("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"),
                "architecture": "arm", "model": "", "mobile": false,
            ],
        ]
    }

    private func handle(_ method: String, _ params: JSONValue, _ session: String?) {
        if let session {
            tab(forSession: session)?.handle(method, params)
            return
        }
        switch method {
        case "Target.targetInfoChanged":
            guard let info = params["targetInfo"], let id = info["targetId"]?.stringValue else { return }
            tab(forTarget: id)?.targetChanged(title: info["title"]?.stringValue, url: info["url"]?.stringValue)
        case "Target.targetCreated":
            // A link that opens a new window would open it where nobody can see it. Its address is opened in
            // the card that asked instead.
            guard let info = params["targetInfo"], info["type"]?.stringValue == "page",
                  let id = info["targetId"]?.stringValue, tab(forTarget: id) == nil,
                  let opener = info["openerId"]?.stringValue, let owner = tab(forTarget: opener) else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                let now = try? await self.connection?.send("Target.getTargetInfo", ["targetId": .string(id)])
                let address = now?["targetInfo"]?["url"]?.stringValue ?? info["url"]?.stringValue ?? ""
                self.connection?.post("Target.closeTarget", ["targetId": .string(id)])
                if let url = try? BrowserTools.checkedURL(address) { _ = try? await owner.open(url) }
            }
        case "Target.targetDestroyed", "Target.targetCrashed":
            guard let id = params["targetId"]?.stringValue, let tab = tab(forTarget: id) else { return }
            tab.detached()
            tab.hostChanged()
        default:
            break
        }
    }

    /// Starts the browser again after it stopped or failed, for the tabs that are on screen.
    func restart() {
        if case .starting = state { return }
        if case .downloading = state { return }
        Task {
            _ = try? await connected()
            tabs.values.forEach { $0.reconnect() }
        }
    }

    /// Fetches Chrome for Testing, then starts it.
    func download() {
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                _ = try await BrowserFinder.download(into: support) { [weak self] fraction in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
                state = .idle
                restart()
            } catch {
                state = .failed("The download didn't finish: \((error as? BrowserError)?.description ?? error.localizedDescription)")
            }
        }
    }

    /// Quits the browser. Its tabs stay, and the next thing that needs one starts it again.
    func shutDown() {
        starting?.cancel()
        connection?.close()
        closing = connection ?? closing
        connection = nil
        tabs.values.forEach { $0.detached() }
        if state == .running || state == .starting || state == .stopped { state = .idle }
    }

    /// The app is quitting, so there is no time to ask nicely.
    func terminate() {
        connection?.terminate()
        connection = nil
    }

    /// Forgets every sign-in, cookie and page this project's browser has kept.
    func clearData() async {
        let wasRunning = connection != nil
        let leaving = connection ?? closing
        connection?.close()
        connection = nil
        closing = nil
        // The profile can only be deleted once the browser has let go of it.
        if let leaving {
            for _ in 0..<60 where leaving.isOpen { try? await Task.sleep(for: .milliseconds(100)) }
        }
        tabs.values.forEach { $0.detached(forgettingPage: true) }
        try? FileManager.default.removeItem(at: profile)
        state = .idle
        if wasRunning, !tabs.isEmpty { restart() }
    }

    #if DEBUG
    var testProcessID: pid_t? { connection?.pid }
    #endif

    /// Whether this project's browser has kept anything.
    var hasData: Bool { FileManager.default.fileExists(atPath: profile.path) }
}
