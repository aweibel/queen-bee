import AppKit
import QueenBeeCore

/// The browser tab that belongs to one agent card. The agent's tools act on it, the card's browser half shows
/// it, and the person's clicks and keys in that half go to it. It lives here, not in the card's view, so it
/// survives the canvas rebuilding its views.
// Named as main-actor here because conforming to a Sendable protocol would otherwise opt the class out of the app's default.
@MainActor
final class BrowserTab: BrowserToolHost {
    /// "<flowID>/<cardID>", the same key the card's session goes by.
    let key: String
    private(set) weak var host: BrowserHost?
    private weak var connection: CDPConnection?
    private(set) var targetID: String?
    private(set) var sessionID: String?
    private var attaching: Task<(CDPConnection, String), any Error>?

    private(set) var url = ""
    private(set) var title = ""
    private(set) var isLoading = false
    /// The latest picture of the page, kept so a view made later has something to show at once.
    private(set) var lastFrame: CGImage?
    /// The same picture as the browser sent it, kept so a device that starts watching has something to show at once.
    private(set) var lastStream: StreamFrame?
    /// Whether the tab's history has a page before this one, and one after it.
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the last address a device typed into the bar didn't open, until the page changes. The Mac's own bar
    /// shows its errors in itself.
    private(set) var addressProblem: String?
    private var mainFrame: String?
    /// The page's size in points: the size of the card's browser half.
    private var size = CGSize(width: 560, height: 340)
    private var sizeTask: Task<Void, Never>?
    private var titleCheck: Task<Void, Never>?
    private var wantsStream = false
    /// The card's browser half on the Mac is in view. The page is also streamed while a paired device watches it.
    private var paneWantsStream = false
    private var isStreaming = false
    /// The paired devices watching this card's page, each told of every picture and every change.
    private var watchers: [UUID: (frame: (StreamFrame) -> Void, change: () -> Void)] = [:]
    /// The numbers the last `read` gave out, and the page node each stands for.
    private var refs: [Int: Int] = [:]
    /// Where to go back to when the browser has been started again.
    private var lastAddress: String?
    /// What pop-up dialogs on the page said since the agent was last told.
    private var dialogs: [String] = []
    /// The card has lost its browser. Nothing brings a closed tab back.
    private var isClosed = false
    /// How many of the agent's own clicks, keys and page opens are under way.
    private var agentActions = 0
    /// A world of the app's own in the page's main frame, where Copy asks what is selected: the page's own
    /// scripts can't reach it, so nothing the page did to itself can answer for it. Made again for each new page.
    private var copyWorld: (frame: String, context: Int)?
    /// The history is asked for at most four times a second, however fast a page changes its own address.
    private var historyCheck: Task<Void, Never>?
    private var lastHistoryRead = Date.distantPast
    /// Waits a moment before the page stops being drawn, so a device that takes a card off its screen and puts it
    /// straight back doesn't stop and start it.
    private var stopping: Task<Void, Never>?

    /// A new picture of the page.
    var onFrame: ((CGImage) -> Void)?
    /// The address, title, loading state or the browser's own state changed.
    var onChange: (() -> Void)?

    private func changed() {
        onChange?()
        watchers.values.forEach { $0.change() }
    }

    init(key: String, host: BrowserHost) {
        self.key = key
        self.host = host
    }

    var hostState: BrowserHost.State { host?.state ?? .stopped }
    var isAttached: Bool { sessionID != nil && connection?.isOpen == true }

    // MARK: Attaching

    /// The line to the browser and this tab's session on it, opening the tab first if it isn't open.
    private func session() async throws -> (CDPConnection, String) {
        guard !isClosed else { throw BrowserError("This card's browser has been turned off.") }
        if let connection, connection.isOpen, let sessionID { return (connection, sessionID) }
        if let attaching { return try await attaching.value }
        let task = Task { try await self.attach() }
        attaching = task
        defer { if attaching == task { attaching = nil } }
        return try await task.value
    }

    private func attach() async throws -> (CDPConnection, String) {
        guard let host else { throw BrowserError("The browser has stopped") }
        let connection = try await host.connected()
        // Each tab gets a window of its own. A hidden browser only draws the front tab of a window, and
        // every card's page has to be drawn.
        let made = try await connection.send("Target.createTarget", ["url": "about:blank", "newWindow": true])
        guard let target = made["targetId"]?.stringValue else { throw BrowserError("The browser didn't open a tab") }
        let attached = try await connection.send("Target.attachToTarget", ["targetId": .string(target), "flatten": true])
        guard let session = attached["sessionId"]?.stringValue else { throw BrowserError("The browser didn't open a tab") }
        // The card's browser may have been turned off while the tab was opening.
        guard !isClosed else {
            connection.post("Target.closeTarget", ["targetId": .string(target)])
            throw BrowserError("This card's browser has been turned off.")
        }
        self.connection = connection
        targetID = target
        sessionID = session
        _ = try await connection.send("Page.enable", session: session)
        if let agent = host.userAgent { _ = try? await connection.send("Emulation.setUserAgentOverride", agent, session: session) }
        _ = try? await connection.send("Emulation.setDeviceMetricsOverride", metrics, session: session)
        if let lastAddress, (try? BrowserTools.checkedURL(lastAddress)) != nil {
            connection.post("Page.navigate", ["url": .string(lastAddress)], session: session)
        }
        if wantsStream { startStream() }
        changed()
        return (connection, session)
    }

    /// The tab is gone from the browser, because the browser stopped or the tab was closed.
    func detached(forgettingPage: Bool = false) {
        copyWorld = nil
        attaching?.cancel()
        attaching = nil
        connection = nil
        targetID = nil
        sessionID = nil
        mainFrame = nil
        isStreaming = false
        isLoading = false
        refs = [:]
        canGoBack = false
        canGoForward = false
        if forgettingPage {
            lastAddress = nil
            url = ""
            title = ""
            lastFrame = nil
            lastStream = nil
            addressProblem = nil
        }
        changed()
    }

    /// Opens the tab again after the browser restarted, if a card is showing it.
    func reconnect() {
        guard wantsStream, !isAttached, !isClosed else { return }
        Task { _ = try? await session() }
    }

    /// The card has lost its browser: the tab closes for good.
    func close() {
        isClosed = true
        if let targetID { connection?.post("Target.closeTarget", ["targetId": .string(targetID)]) }
        onFrame = nil
        onChange = nil
        detached(forgettingPage: true)
        // A device watching the card is told once more, and then nothing: the card has no browser now.
        watchers = [:]
    }

    func hostChanged() { changed() }

    // MARK: What the browser reports

    func handle(_ method: String, _ params: JSONValue) {
        switch method {
        case "Page.frameNavigated":
            guard let frame = params["frame"], frame["parentId"] == nil else { return }
            mainFrame = frame["id"]?.stringValue
            copyWorld = nil
            setAddress(frame["url"]?.stringValue ?? "")
            // A new page has new parts: the old numbers point at nothing.
            refs = [:]
        case "Page.navigatedWithinDocument":
            guard params["frameId"]?.stringValue == mainFrame, let address = params["url"]?.stringValue else { return }
            setAddress(address)
        case "Page.frameStartedLoading":
            guard mainFrame == nil || params["frameId"]?.stringValue == mainFrame else { return }
            isLoading = true
            changed()
        case "Page.frameStoppedLoading":
            guard mainFrame == nil || params["frameId"]?.stringValue == mainFrame else { return }
            isLoading = false
            changed()
            // The browser doesn't always say when a page's title has settled, so it is asked once the page has loaded.
            Task {
                guard let name = try? await evaluate("document.title").stringValue, name != title else { return }
                title = name
                changed()
            }
        case "Page.javascriptDialogOpening":
            // Nobody can see a dialog in a hidden browser, and the page waits behind it until it is answered.
            // One the agent's own action raised is accepted, and the agent is told what it said. One the person
            // raised, such as "Delete this?", is turned down: they were never shown the question. A page asking
            // whether it may be left is always let go.
            let leaving = params["type"]?.stringValue == "beforeunload"
            let accepts = leaving || agentActions > 0
            if !leaving, let message = params["message"]?.stringValue, !message.isEmpty {
                dialogs.append("\"\(message.prefix(300))\" (\(accepts ? "accepted" : "dismissed"))")
            }
            if dialogs.count > 5 { dialogs.removeFirst(dialogs.count - 5) }
            if let sessionID { connection?.post("Page.handleJavaScriptDialog", ["accept": .bool(accepts)], session: sessionID) }
        case "Inspector.targetCrashed":
            title = "This page crashed"
            isLoading = false
            changed()
        default:
            break
        }
    }

    private func setAddress(_ address: String) {
        url = address == "about:blank" ? "" : address
        if address.hasPrefix("http://") || address.hasPrefix("https://") { lastAddress = address }
        addressProblem = nil
        changed()
        readHistorySoon()
    }

    /// Asks for the history now, or as soon as a quarter of a second has passed since it was last asked for. A page
    /// can change its own address many times a second, and each time would be one more question for the browser.
    private func readHistorySoon() {
        guard historyCheck == nil else { return }
        let wait = max(0, 0.25 - Date().timeIntervalSince(lastHistoryRead))
        historyCheck = Task {
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            historyCheck = nil
            lastHistoryRead = Date()
            await readHistory()
        }
    }

    /// Whether Back and Forward have anywhere to go, asked of the browser after each change of page.
    private func readHistory() async {
        guard let connection, let sessionID,
              let history = try? await connection.send("Page.getNavigationHistory", session: sessionID),
              let index = history["currentIndex"]?.intValue, let count = history["entries"]?.arrayValue?.count else { return }
        let back = index > 0, forward = index + 1 < count
        guard back != canGoBack || forward != canGoForward else { return }
        canGoBack = back
        canGoForward = forward
        changed()
    }

    func targetChanged(title new: String?, url address: String?) {
        guard let new, new != title, new != "about:blank" else { return }
        title = new
        changed()
    }

    // MARK: The picture

    private var metrics: JSONValue {
        ["width": .number(Double(Int(size.width))), "height": .number(Double(Int(size.height))), "deviceScaleFactor": 0, "mobile": false]
    }

    /// A card's browser half came into view or went out of it. The page is only streamed while someone can see it.
    func setStreaming(_ on: Bool) {
        paneWantsStream = on
        streamingChanged()
    }

    /// A paired device has the card on its screen. It is told of every picture and every change until it lets go.
    func addWatcher(frame: @escaping (StreamFrame) -> Void, change: @escaping () -> Void) -> UUID {
        let id = UUID()
        watchers[id] = (frame, change)
        streamingChanged()
        return id
    }

    func removeWatcher(_ id: UUID) {
        guard watchers.removeValue(forKey: id) != nil else { return }
        streamingChanged()
    }

    var watcherCount: Int { watchers.count }

    /// Streams the page while the Mac's card or any device is showing it, and stops when none is.
    private func streamingChanged() {
        let on = !isClosed && (paneWantsStream || !watchers.isEmpty)
        if on { stopping?.cancel(); stopping = nil }
        guard on != wantsStream else { return }
        wantsStream = on
        if on {
            if isAttached { startStream() } else if hostState != .missing, !isClosed { Task { _ = try? await session() } }
        } else if isClosed {
            stopStream()
        } else {
            // Nobody is looking now. The page goes on being drawn for a moment, in case a device that let go of the
            // card, or the Mac's own card scrolled out of view, comes straight back.
            stopping = Task {
                try? await Task.sleep(for: .seconds(Remote.streamLinger))
                guard !Task.isCancelled, !wantsStream else { return }
                stopping = nil
                stopStream()
            }
        }
    }

    private func startStream() {
        guard let sessionID, !isStreaming else { return }
        isStreaming = true
        connection?.post("Page.startScreencast", [
            "format": "jpeg", "quality": 85, "everyNthFrame": 1,
            "maxWidth": .number(Double(Int(size.width * 2))), "maxHeight": .number(Double(Int(size.height * 2))),
        ], session: sessionID)
    }

    private func stopStream() {
        guard let sessionID, isStreaming else { return }
        isStreaming = false
        connection?.post("Page.stopScreencast", session: sessionID)
    }

    func show(_ frame: StreamFrame, ack: Int) {
        if let sessionID { connection?.post("Page.screencastFrameAck", ["sessionId": .number(Double(ack))], session: sessionID) }
        guard isStreaming else { return }
        lastFrame = frame.image
        lastStream = frame
        onFrame?(frame.image)
        watchers.values.forEach { $0.frame(frame) }
    }

    /// The page's size in its own points, which the person's clicks are given in.
    var pageSize: CGSize { size }

    /// The card's browser half changed size, so the page does too.
    func setSize(_ new: CGSize) {
        let wanted = CGSize(width: max(200, new.width.rounded()), height: max(120, new.height.rounded()))
        guard wanted != size else { return }
        size = wanted
        // A card being dragged wider reports every point of the way.
        sizeTask?.cancel()
        sizeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let sessionID, let connection else { return }
            _ = try? await connection.send("Emulation.setDeviceMetricsOverride", metrics, session: sessionID)
            if isStreaming {
                stopStream()
                startStream()
            }
        }
    }

    // MARK: The person's input

    func mouse(_ type: String, at point: CGPoint, button: String = "none", buttons: Int = 0, clicks: Int = 0, modifiers: Int = 0) {
        guard let sessionID else { return }
        if type == "mouseReleased" { checkTitleSoon() }
        connection?.post("Input.dispatchMouseEvent", [
            "type": .string(type), "x": .number(point.x), "y": .number(point.y), "button": .string(button),
            "buttons": .number(Double(buttons)), "clickCount": .number(Double(clicks)), "modifiers": .number(Double(modifiers)),
        ], session: sessionID)
    }

    func wheel(at point: CGPoint, dx: Double, dy: Double, modifiers: Int = 0) {
        guard let sessionID else { return }
        connection?.post("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": .number(point.x), "y": .number(point.y), "deltaX": .number(dx), "deltaY": .number(dy),
            "modifiers": .number(Double(modifiers)),
        ], session: sessionID)
    }

    private static func keyEvent(down: Bool, _ key: BrowserKey, modifiers: Int, commands: [String]) -> JSONValue {
        // With Command or Control held a key is a shortcut and types nothing.
        let text = modifiers & 6 == 0 ? key.text : nil
        var fields: [String: JSONValue] = [
            "type": .string(down ? (text == nil ? "rawKeyDown" : "keyDown") : "keyUp"),
            "key": .string(key.key), "code": .string(key.code), "modifiers": .number(Double(modifiers)),
            "windowsVirtualKeyCode": .number(Double(key.keyCode)), "nativeVirtualKeyCode": .number(Double(key.keyCode)),
        ]
        if down, let text {
            fields["text"] = .string(text)
            fields["unmodifiedText"] = .string(text)
        }
        if down, !commands.isEmpty { fields["commands"] = .array(commands.map(JSONValue.string)) }
        return .object(fields)
    }

    /// One key going down or coming up. `commands` are editing commands the key stands for, such as "selectAll".
    func key(down: Bool, _ key: BrowserKey, modifiers: Int = 0, commands: [String] = []) {
        guard let sessionID else { return }
        if !down { checkTitleSoon() }
        connection?.post("Input.dispatchKeyEvent", Self.keyEvent(down: down, key, modifiers: modifiers, commands: commands), session: sessionID)
    }

    func insert(text: String) {
        guard let sessionID, !text.isEmpty else { return }
        checkTitleSoon()
        connection?.post("Input.insertText", ["text": .string(text)], session: sessionID)
    }

    /// ⌘A, ⌘Z and ⌘⇧Z, sent as the letter with Command held and the editing command it stands for.
    func shortcut(_ shortcut: BrowserShortcut) {
        let (letter, command, shift) = shortcut.key
        press(BrowserKey.typing(letter), modifiers: 4 | (shift ? 8 : 0), commands: [command])
    }

    /// Deletes what is selected, as the second half of Cut.
    func deleteSelection() {
        press(BrowserKey.typing("x"), modifiers: 4, commands: ["delete"])
    }

    /// One key pressed and let go.
    func press(_ key: BrowserKey, modifiers: Int = 0, commands: [String] = []) {
        self.key(down: true, key, modifiers: modifiers, commands: commands)
        self.key(down: false, key, modifiers: modifiers)
    }

    /// Pages often rename themselves when they are clicked or typed into, and the browser doesn't always say
    /// so. The title is asked for a moment after, once for a burst of input.
    private func checkTitleSoon() {
        titleCheck?.cancel()
        titleCheck = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, isAttached, let name = try? await evaluate("document.title").stringValue, name != title else { return }
            title = name
            changed()
        }
    }

    /// What is selected on the page, for a device's Copy, or nil when the page didn't say within `seconds`.
    ///
    /// Asked in a world of the app's own in the page's main frame. That world shares the page but none of its
    /// scripts, so a page that has replaced `getSelection` with something of its own isn't asked. A page busy with
    /// a script of its own can't answer at all, and is given up on.
    func selectedText(within seconds: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        func left() -> TimeInterval { max(0.05, deadline.timeIntervalSinceNow) }
        guard let (connection, session) = try? await session() else { return nil }
        for attempt in 0..<2 {
            do {
                let context = try await copyContext(connection, session, timeout: left())
                let reply = try await connection.send("Runtime.evaluate", [
                    "expression": "getSelection().toString()", "contextId": .number(Double(context)), "returnByValue": true,
                    "timeout": .number((left() * 1000).rounded(.down)),
                ], session: session, timeout: left())
                guard reply["exceptionDetails"] == nil else { throw BrowserError("The page couldn't be read just now") }
                return reply["result"]?["value"]?.stringValue ?? ""
            } catch {
                // The world goes with the page it was made in. Made once more, if there is time.
                copyWorld = nil
                if attempt == 1 || Date() >= deadline { return nil }
            }
        }
        return nil
    }

    private func copyContext(_ connection: CDPConnection, _ session: String, timeout: TimeInterval) async throws -> Int {
        var frame = mainFrame
        if frame == nil {
            let tree = try await connection.send("Page.getFrameTree", session: session, timeout: timeout)
            frame = tree["frameTree"]?["frame"]?["id"]?.stringValue
        }
        guard let frame else { throw BrowserError("The page has no frame") }
        if let copyWorld, copyWorld.frame == frame { return copyWorld.context }
        let made = try await connection.send("Page.createIsolatedWorld", ["frameId": .string(frame), "worldName": "Queen Bee copy"],
                                             session: session, timeout: timeout)
        guard let context = made["executionContextId"]?.intValue else { throw BrowserError("The page didn't make a world") }
        copyWorld = (frame, context)
        return context
    }

    func reload() {
        guard let sessionID else { return reconnect() }
        connection?.post("Page.reload", session: sessionID)
    }

    func goForward() async {
        _ = try? await step(1)
    }

    /// Opens what the person typed in the address bar: an address, or words to search for, by the rules a
    /// device's bar goes by too.
    func openTyped(_ raw: String) async throws {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try await open(try BrowserTools.typedAddress(raw))
    }

    /// The same, from a paired device's bar. It doesn't wait for the page: why one didn't open is kept in
    /// `addressProblem` for the device's bar to show, as the Mac's shows it.
    func openTypedFromDevice(_ raw: String) {
        Task {
            do {
                try await openTyped(raw)
            } catch {
                addressProblem = (error as? BrowserError)?.description ?? "That page didn't open"
                changed()
            }
        }
    }

    /// Back, from a paired device. False when there is no page to go back to.
    func goBack() async -> Bool { (try? await step(-1)) ?? false }

    /// What the card's browser half shows besides the picture, for a paired device.
    var remotePage: RemoteBrowserPage {
        let (status, fraction, problem) = hostState.remote
        // In hundredths, which is all the notice says, so a download isn't sent for every piece that arrives.
        let progress = fraction.map { ($0 * 100).rounded(.down) / 100 }
        return RemoteBrowserPage(status: status, progress: progress, problem: problem, isAttached: isAttached, hasPicture: lastFrame != nil,
                                 url: url, title: title, isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward,
                                 addressProblem: addressProblem)
    }

    // MARK: Helpers for the tools

    private func evaluate(_ expression: String) async throws -> JSONValue {
        let (connection, session) = try await session()
        let reply = try await connection.send("Runtime.evaluate", ["expression": .string(expression), "returnByValue": true], session: session)
        guard reply["exceptionDetails"] == nil else { throw BrowserError("The page couldn't be read just now") }
        return reply["result"]?["value"] ?? .null
    }

    /// The page's title and address, in a few words for the agent.
    private func whereItIs() async -> String {
        var name = title, address = url
        if let both = try? await evaluate("JSON.stringify([document.title, location.href])").stringValue,
           let parts = try? JSONValue.parse(Data(both.utf8)).arrayValue, parts.count == 2 {
            name = parts[0].stringValue ?? name
            address = parts[1].stringValue ?? address
            // A page can rename itself at any time, and this is a moment the app hears about it.
            if name != title {
                title = name
                changed()
            }
        }
        if address.isEmpty || address == "about:blank" { return "a blank page" }
        return name.isEmpty ? address : "\"\(name)\" at \(address)"
    }

    /// Waits for the page to finish loading. False when it was still loading at the end.
    private func loaded(within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Asking fails for a moment while one page is swapped for the next.
            if let state = try? await evaluate("document.readyState").stringValue, state == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Gives a click or a key time to have its effect, and a page it started time to load.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(350))
        if isLoading { _ = await loaded(within: 10) }
    }

    private func takeDialogNote() -> String {
        guard !dialogs.isEmpty else { return "" }
        let said = dialogs.joined(separator: ", ")
        dialogs = []
        return " A dialog on the page said \(said)."
    }

    private static func plain(_ error: String) -> String {
        switch error {
        case "net::ERR_NAME_NOT_RESOLVED": "no site has that name"
        case "net::ERR_CONNECTION_REFUSED": "nothing is answering at that address"
        case "net::ERR_INTERNET_DISCONNECTED": "there is no internet connection"
        case "net::ERR_CONNECTION_TIMED_OUT", "net::ERR_TIMED_OUT": "the site took too long to answer"
        case let other where other.hasPrefix("net::ERR_CERT"): "the site's security certificate isn't valid"
        default: error
        }
    }

    private static let stale = "That part isn't on the page any more. Call read again and use the numbers it gives."

    /// The middle of a numbered part, scrolled into view first.
    private func centre(of ref: Int) async throws -> CGPoint {
        guard let node = refs[ref] else {
            throw BrowserError("There is no part numbered \(ref) on the page as it is now. Call read again and use the numbers it gives.")
        }
        let (connection, session) = try await session()
        do {
            _ = try? await connection.send("DOM.scrollIntoViewIfNeeded", ["backendNodeId": .number(Double(node))], session: session)
            let reply = try await connection.send("DOM.getContentQuads", ["backendNodeId": .number(Double(node))], session: session)
            guard let quad = reply["quads"]?.arrayValue?.first?.arrayValue?.compactMap(\.doubleValue), quad.count == 8 else {
                throw BrowserError(Self.stale)
            }
            return CGPoint(x: (quad[0] + quad[2] + quad[4] + quad[6]) / 4, y: (quad[1] + quad[3] + quad[5] + quad[7]) / 4)
        } catch {
            throw BrowserError(Self.stale)
        }
    }

    private func press(at point: CGPoint) async throws {
        let (connection, session) = try await session()
        func event(_ type: String, buttons: Int) -> JSONValue {
            ["type": .string(type), "x": .number(point.x), "y": .number(point.y), "button": type == "mouseMoved" ? "none" : "left",
             "buttons": .number(Double(buttons)), "clickCount": type == "mouseMoved" ? 0 : 1]
        }
        _ = try await connection.send("Input.dispatchMouseEvent", event("mouseMoved", buttons: 0), session: session)
        _ = try await connection.send("Input.dispatchMouseEvent", event("mousePressed", buttons: 1), session: session)
        _ = try await connection.send("Input.dispatchMouseEvent", event("mouseReleased", buttons: 0), session: session)
    }

    private func tap(_ key: BrowserKey) async throws {
        let (connection, session) = try await session()
        _ = try await connection.send("Input.dispatchKeyEvent", Self.keyEvent(down: true, key, modifiers: 0, commands: []), session: session)
        _ = try await connection.send("Input.dispatchKeyEvent", Self.keyEvent(down: false, key, modifiers: 0, commands: []), session: session)
    }

    /// Goes one page back or forward in the tab's history. False when there is no page that way.
    private func step(_ by: Int) async throws -> Bool {
        let (connection, session) = try await session()
        let history = try await connection.send("Page.getNavigationHistory", session: session)
        guard let index = history["currentIndex"]?.intValue, let entries = history["entries"]?.arrayValue,
              entries.indices.contains(index + by), let entry = entries[index + by]["id"] else { return false }
        _ = try await connection.send("Page.navigateToHistoryEntry", ["entryId": entry], session: session)
        try? await Task.sleep(for: .milliseconds(200))
        _ = await loaded(within: 15)
        return true
    }

    // MARK: BrowserToolHost, for the agent's tools

    func open(_ url: URL) async throws -> String {
        agentActions += 1
        defer { agentActions -= 1 }
        let (connection, session) = try await session()
        let reply = try await connection.send("Page.navigate", ["url": .string(url.absoluteString)], session: session, timeout: 40)
        if let error = reply["errorText"]?.stringValue, !error.isEmpty {
            if error == "net::ERR_ABORTED" { throw BrowserError("That address is a file to download, and this browser doesn't download files.") }
            throw BrowserError("The page didn't open: \(Self.plain(error)).")
        }
        lastAddress = url.absoluteString
        let finished = await loaded(within: 30)
        return (finished ? "Opened " : "Still loading after 30 seconds: ") + (await whereItIs()) + "." + takeDialogNote()
    }

    func read() async throws -> String {
        let (connection, session) = try await session()
        _ = await loaded(within: 5)
        let tree = try await connection.send("Accessibility.getFullAXTree", session: session)
        let outline = PageOutline.build(from: tree["nodes"]?.arrayValue ?? [])
        refs = outline.refs
        let place = (try? await evaluate("JSON.stringify([document.title, location.href])").stringValue)
            .flatMap { try? JSONValue.parse(Data($0.utf8)).arrayValue } ?? []
        let name = place.first?.stringValue ?? title
        let address = place.last?.stringValue ?? url
        return "Title: \(name)\nAddress: \(address)\n\(takeDialogNote().trimmingCharacters(in: .whitespaces))\n\(outline.text)"
    }

    func screenshot() async throws -> Data {
        let (connection, session) = try await session()
        let reply = try await connection.send("Page.captureScreenshot", ["format": "png"], session: session)
        guard let encoded = reply["data"]?.stringValue, let png = Data(base64Encoded: encoded),
              let image = NSBitmapImageRep(data: png)?.cgImage else { throw BrowserError("The browser couldn't take a picture of the page") }
        // The page is drawn at twice its size. The agent gets it at one pixel per point, so a point it picks
        // in the picture is the same point on the page.
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return png
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage(), let data = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else { return png }
        return data
    }

    func scroll(dx: Double, dy: Double) async throws -> String {
        let (connection, session) = try await session()
        _ = try await connection.send("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": .number(size.width / 2), "y": .number(size.height / 2),
            "deltaX": .number(dx * size.width * 0.85), "deltaY": .number(dy * size.height * 0.85),
        ], session: session)
        try? await Task.sleep(for: .milliseconds(350))
        let expression = "JSON.stringify([Math.round(scrollY), Math.round(innerHeight), Math.round(document.documentElement.scrollHeight)])"
        guard let text = try? await evaluate(expression).stringValue,
              let numbers = try? JSONValue.parse(Data(text.utf8)).arrayValue?.compactMap(\.intValue), numbers.count == 3 else {
            return "Scrolled."
        }
        return "Scrolled. The browser shows from \(numbers[0]) to \(numbers[0] + numbers[1]) of the page's \(numbers[2]) points."
    }

    func back() async throws -> String {
        guard try await step(-1) else { throw BrowserError("There is no earlier page to go back to.") }
        return "Went back to \(await whereItIs())."
    }

    func wait(text: String?, seconds: Double) async throws -> String {
        guard let text else {
            try? await Task.sleep(for: .seconds(seconds))
            return "Waited \(Int(seconds.rounded())) seconds. The browser is at \(await whereItIs())."
        }
        // JSON's way of writing text is also JavaScript's, so the text can't break out of the quotes.
        let check = "document.body ? document.body.innerText.includes(\(JSONValue.string(text).text())) : false"
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if (try? await evaluate(check).boolValue) == true { return "\"\(text)\" is on the page." }
            try? await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        throw BrowserError("\"\(text)\" didn't appear within \(Int(seconds.rounded())) seconds.")
    }

    func click(ref: Int) async throws -> String {
        agentActions += 1
        defer { agentActions -= 1 }
        try await press(at: try await centre(of: ref))
        await settle()
        return "Clicked part \(ref). The browser is at \(await whereItIs()).\(takeDialogNote()) Call read to see the page as it is now."
    }

    func click(x: Double, y: Double) async throws -> String {
        agentActions += 1
        defer { agentActions -= 1 }
        guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
            throw BrowserError("That point is off the page as shown, which is \(Int(size.width)) by \(Int(size.height)) points.")
        }
        try await press(at: CGPoint(x: x, y: y))
        await settle()
        return "Clicked at \(Int(x)), \(Int(y)). The browser is at \(await whereItIs()).\(takeDialogNote()) Call read to see the page as it is now."
    }

    func type(ref: Int, text: String, submit: Bool) async throws -> String {
        agentActions += 1
        defer { agentActions -= 1 }
        guard let node = refs[ref] else {
            throw BrowserError("There is no part numbered \(ref) on the page as it is now. Call read again and use the numbers it gives.")
        }
        let (connection, session) = try await session()
        // A drop-down list is set by choosing; anything else is focused with its old text selected, so typing replaces it.
        let prepare = """
        function(text) {
          if (this.tagName === 'SELECT') {
            const want = text.trim().toLowerCase();
            const choice = [...this.options].find(o => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want);
            if (!choice) return 'nochoice:' + [...this.options].map(o => o.text.trim()).slice(0, 40).join(' | ');
            this.value = choice.value;
            this.dispatchEvent(new Event('input', { bubbles: true }));
            this.dispatchEvent(new Event('change', { bubbles: true }));
            return 'chosen';
          }
          if (this.scrollIntoViewIfNeeded) this.scrollIntoViewIfNeeded();
          this.focus();
          if (document.activeElement !== this) return 'nofocus';
          if (typeof this.select === 'function') this.select();
          else if (this.isContentEditable) document.execCommand('selectAll', false, null);
          return 'ready';
        }
        """
        let outcome: String
        do {
            let resolved = try await connection.send("DOM.resolveNode", ["backendNodeId": .number(Double(node))], session: session)
            guard let object = resolved["object"]?["objectId"] else { throw BrowserError(Self.stale) }
            let reply = try await connection.send("Runtime.callFunctionOn", [
                "objectId": object, "functionDeclaration": .string(prepare), "arguments": [["value": .string(text)]], "returnByValue": true,
            ], session: session)
            outcome = reply["result"]?["value"]?.stringValue ?? ""
        } catch {
            throw BrowserError(Self.stale)
        }
        if outcome == "chosen" { return "Chose \"\(text)\" in part \(ref)." }
        if outcome.hasPrefix("nochoice:") {
            throw BrowserError("Part \(ref) is a list with no choice called \"\(text)\". Its choices are: \(outcome.dropFirst(9))")
        }
        if outcome == "nofocus" { throw BrowserError("Part \(ref) can't be typed into. It may be disabled, or not a text box.") }
        guard outcome == "ready" else { throw BrowserError(Self.stale) }
        if text.isEmpty {
            try await tap(BrowserKey.named("Backspace")!)
        } else {
            _ = try await connection.send("Input.insertText", ["text": .string(text)], session: session)
        }
        guard submit else { return "Typed into part \(ref)." }
        try await tap(BrowserKey.named("Enter")!)
        await settle()
        return "Typed into part \(ref) and pressed Return. The browser is at \(await whereItIs()).\(takeDialogNote()) Call read to see the page as it is now."
    }

    func press(_ key: BrowserKey) async throws -> String {
        agentActions += 1
        defer { agentActions -= 1 }
        try await tap(key)
        await settle()
        return "Pressed \(key.code.isEmpty ? key.key : key.code). The browser is at \(await whereItIs()).\(takeDialogNote())"
    }
}
