#if DEBUG
import Foundation
import QueenBeeCore
import UIKit

/// A made-up Mac with one agent card that has a browser, for checking the card's browser on this device
/// without a Mac or a Chromium. Launched with `-qbCannedBrowser <state>`, where the state is what the Mac's
/// browser is doing: notStarted, starting, failed, missing, downloading, stopped or frames. With `-qbControl 1`
/// the made-up Mac lets this device control it, and answers what is done in the page roughly as a real page
/// would: a click on its button changes it, typing fills its box, an address opens. Everything here is made up.
///
/// And the steps a test names with `-qbDo` for a card's browser, made-up Mac or real:
///   browserOpen:<card>            open the card's browser full screen, as the mark at the end of its bar does
///   browserClose                  close it
///   browserTap:<card>:<x>:<y>     tap the full-screen page where the page's own point x, y is drawn
///   browserType:<card>:<text>     type that on the keyboard into the page
///   browserKey:<card>:<key>       press a key under the page: Escape, Tab, Enter, Backspace, ArrowLeft…
///   browserGo:<card>:<address>    type an address into the bar and press Go
///   browserBack:<card> | browserForward:<card> | browserReload:<card> | browserCopy:<card>
///   browserOffer:<card>           press the button under the notice: Download, Try again or Restart
/// With `-qbExpandBrowser <card>` the card's browser opens full screen once the flow is on the canvas, and with
/// `-qbBrowserKeys 1` its keyboard comes up.
enum DebugBrowser {
    static var cannedState: String? { UserDefaults.standard.string(forKey: "qbCannedBrowser") }
    static var isWanted: Bool { cannedState != nil }
    static var wantsKeys: Bool { UserDefaults.standard.bool(forKey: "qbBrowserKeys") }

    static let flowID = "cannedbr"
    static let surfer = "surfer01"
    private static let notes = "notes001"

    /// What the made-up page shows.
    private struct Page {
        var url = "https://shop.example.com/"
        var title = "Example Shop"
        var pressed = 0
        var typed = ""
        var history = ["https://shop.example.com/"]
        var index = 0
    }

    private static var page = Page()
    private static var status = RemoteBrowserState.Status.running
    private static var watched = false

    static func play(_ client: RemoteClient) async {
        let state = cannedState ?? "frames"
        status = switch state {
        case "notStarted": .idle
        case "starting": .starting
        case "failed": .failed
        case "missing": .missing
        case "downloading": .downloading
        case "stopped": .stopped
        default: .running
        }
        var agent = Card(id: surfer, kind: .agent, name: "Surfer", x: 60, y: 60, width: 960, height: 300)
        agent.browser = true
        agent.instructions = "You look things up in the browser in your card."
        var note = Card(id: notes, kind: .note, name: "Note", x: 60, y: 420, width: 300, height: 120)
        note.text = "Surfer looks up prices in the shop."
        let flow = Flow(id: flowID, name: "Research", cards: [agent, note], links: [])
        client.debugOutbox = { id, command in answer(client, id, command) }
        client.debugWatcher = { _, cards in watch(client, cards.contains(surfer)) }
        client.debugTake(.welcome(RemoteWelcome(version: Remote.version, macName: "Example Mac", canControl: UserDefaults.standard.bool(forKey: "qbControl"))))
        let summary = RemoteFlowSummary(id: flowID, name: flow.name, isSubflow: false, activity: .quiet)
        client.debugTake(.library(RemoteLibrary(projects: [RemoteProject(id: "/example", name: "Example project", flows: [summary],
                                                                             browser: RemoteBrowserState(status: status, browser: "Google Chrome"))])))
        client.open(flowID)
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [], results: [:], usage: [:],
                                 sessions: [surfer: .idle], awaitingAnswer: [], banner: nil)
        client.debugTake(.opened(RemoteFlowSnapshot(flow: flow, run: run, log: [], messages: [:], runs: [])))
        let esc = "\u{1b}"
        client.debugTake(.terminal(id: flowID, key: surfer, chunk: TerminalChunk(reset: true, cols: 56, rows: 16, data: Data(
            "\(esc)[1;38;5;208m● Surfer\(esc)[0m\r\n\r\n> Find the price of the large size.\r\n\r\nOpening the shop in the browser…\r\n".utf8))))
    }

    /// The device has the card on screen, or no longer has: as a real Mac does, it is sent the bar and the page at once.
    private static func watch(_ client: RemoteClient, _ on: Bool) {
        let was = watched
        watched = on
        guard on, !was else { return }
        tell(client)
    }

    private static func tell(_ client: RemoteClient) {
        guard watched else { return }
        let live = status == .running
        let problem = status == .failed ? "The browser didn't answer in time." : nil
        let progress = status == .downloading ? 0.45 : nil
        let shown = RemoteBrowserPage(status: status, progress: progress, problem: problem, isAttached: live, hasPicture: live,
                                      url: live ? page.url : "", title: live ? page.title : "", canGoBack: live && page.index > 0,
                                      canGoForward: live && page.index + 1 < page.history.count)
        client.debugTake(.browserPage(id: flowID, card: surfer, page: shown))
        if live, let frame = picture() { client.debugTake(.browserFrame(id: flowID, card: surfer, frame: frame)) }
    }

    /// A made-up page, drawn the way a browser would draw it at twice its size: a heading, a button and a box.
    private static func picture() -> RemoteBrowserFrame? {
        let size = CGSize(width: 479, height: 273)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let ink = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
            func say(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular, colour: UIColor = ink) {
                (text as NSString).draw(at: point, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: colour])
            }
            say(page.title, at: CGPoint(x: 20, y: 16), size: 22, weight: .bold)
            say("Large tote bag, £24", at: CGPoint(x: 20, y: 52), size: 14)
            let button = CGRect(x: 20, y: 86, width: 140, height: 34)
            UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1).setFill()
            UIBezierPath(roundedRect: button, cornerRadius: 6).fill()
            say(page.pressed == 0 ? "Add to basket" : "In basket (\(page.pressed))", at: CGPoint(x: 32, y: 94), size: 14, weight: .semibold, colour: .white)
            let box = CGRect(x: 20, y: 140, width: 300, height: 34)
            UIColor(white: 0.55, alpha: 1).setStroke()
            UIBezierPath(roundedRect: box, cornerRadius: 4).stroke()
            say(page.typed.isEmpty ? "Search the shop" : page.typed, at: CGPoint(x: 30, y: 148), size: 14,
                colour: page.typed.isEmpty ? UIColor(white: 0.6, alpha: 1) : ink)
            say("Free delivery on orders over £40.", at: CGPoint(x: 20, y: 196), size: 13, colour: UIColor(white: 0.4, alpha: 1))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.8), let pixels = image.cgImage else { return nil }
        return RemoteBrowserFrame(jpeg: jpeg, width: pixels.width, height: pixels.height, pageWidth: size.width, pageHeight: size.height)
    }

    /// Answers a command as the made-up Mac.
    private static func answer(_ client: RemoteClient, _ id: Int, _ command: RemoteCommand) {
        guard command.isAnswered || client.mirror.canControl else { return }
        var refusal: String?
        if !client.mirror.canControl {
            refusal = Remote.watchOnlyRefusal
        } else if case .browser(_, _, let action) = command {
            switch action {
            case .mouse(let mouse) where mouse.kind == .released:
                // The button is at 20, 86, 140 by 34 on the page; the box under it.
                if CGRect(x: 20, y: 86, width: 140, height: 34).contains(CGPoint(x: mouse.x, y: mouse.y)) { page.pressed += 1 }
            case .text(let text): page.typed += text
            case .key(let name, _) where name == "Backspace": page.typed = String(page.typed.dropLast())
            case .key(let name, _) where name == "Enter":
                if !page.typed.isEmpty { go(to: "https://shop.example.com/search?q=\(page.typed)", title: "Results") }
            case .navigate(let typed):
                if let url = try? BrowserTools.typedAddress(typed) { go(to: url.absoluteString, title: url.host ?? typed) }
            case .back where page.index > 0:
                page.index -= 1
                page.url = page.history[page.index]
            case .copy:
                client.debugTake(.browserCopied(id: flowID, card: surfer, text: "Large tote bag, £24"))
            default: break
            }
            if command.isAnswered { tell(client) }
        } else if case .installBrowser = command {
            status = .downloading
            tell(client)
        } else if case .restartBrowser = command {
            status = .running
            tell(client)
        }
        guard command.isAnswered else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            client.debugTake(.answer(id: id, refusal: refusal))
        }
    }

    private static func go(to url: String, title: String) {
        page.history = Array(page.history.prefix(page.index + 1)) + [url]
        page.index += 1
        page.url = url
        page.title = title
        page.typed = ""
    }

    // MARK: Steps

    /// A step for a card's browser, as the work its control does. Nil for a step that isn't one of these.
    static func step(_ step: String, in client: RemoteClient) -> (() async -> String?)? {
        let parts = step.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts[0].hasPrefix("browser") else { return nil }
        func card() async -> String {
            while true {
                if client.canvas.shownRevision > 0, let card = client.mirror.snapshot?.flow.cards.first(where: { $0.name == (parts.count > 1 ? parts[1] : "") }) {
                    return card.id
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        /// Waits until what was done has gone and been answered.
        func sent(_ card: String) async -> String? {
            while client.browserInput.isBusy { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            return client.browsers.refusals[card]
        }
        let rest = parts.count > 2 ? parts[2...].joined(separator: ":") : ""
        switch parts[0] {
        case "browserOpen":
            return {
                client.openBrowser(await card())
                try? await Task.sleep(for: .milliseconds(1200))
                return nil
            }
        case "browserClose":
            return {
                client.openBrowser(nil)
                try? await Task.sleep(for: .milliseconds(900))
                return nil
            }
        case "browserTap":
            return {
                let id = await card()
                let numbers = rest.split(separator: ":").compactMap { Double($0) }
                guard numbers.count == 2 else { return "browserTap needs x and y" }
                // The page has to be drawn before a finger can land on it.
                while client.browsers.debugStage?.picture == nil { try? await Task.sleep(for: .milliseconds(200)) }
                guard client.browsers.debugStage?.debugClick(page: CGPoint(x: numbers[0], y: numbers[1])) != nil else { return "the page can't be tapped" }
                return await sent(id)
            }
        case "browserType":
            return {
                let id = await card()
                client.typeInBrowser(id, rest.replacingOccurrences(of: "\\n", with: "\n"))
                try? await Task.sleep(for: .milliseconds(100))
                return await sent(id)
            }
        case "browserKey":
            return {
                let id = await card()
                client.pressInBrowser(id, rest)
                return await sent(id)
            }
        case "browserGo":
            return { await client.useBrowser(await card(), .navigate(rest)) }
        case "browserBack":
            return { await client.useBrowser(await card(), .back) }
        case "browserForward":
            return { await client.useBrowser(await card(), .forward) }
        case "browserReload":
            return { await client.useBrowser(await card(), .reload) }
        case "browserCopy":
            return { await client.copyFromBrowser(await card()) }
        case "browserOffer":
            return {
                let id = await card()
                // The notice comes with the card's first bar from the Mac.
                for _ in 0..<50 where client.browsers.pages[id] == nil { try? await Task.sleep(for: .milliseconds(200)) }
                guard let offer = (client.browsers.pages[id] ?? RemoteBrowserPage()).notice?.offer else { return "no offer" }
                return await client.browser(offer == .download ? .download : .restart)
            }
        default:
            return nil
        }
    }

    private static var hasExpanded = false

    /// Opens a card's browser full screen, once, as soon as the flow is on the canvas.
    static func expandNamed(_ client: RemoteClient) {
        guard !hasExpanded, let name = UserDefaults.standard.string(forKey: "qbExpandBrowser") else { return }
        hasExpanded = true
        Task {
            while true {
                if client.canvas.shownRevision > 0, let card = client.mirror.snapshot?.flow.cards.first(where: { $0.name == name }) {
                    try? await Task.sleep(for: .milliseconds(800))
                    client.openBrowser(card.id)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
#endif
