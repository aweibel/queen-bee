import Observation
import QueenBeeCore
import UIKit

/// The newest picture of one card's page, decoded and ready to draw, with the page's own size, which taps on
/// it are mapped to.
struct BrowserPicture {
    let image: UIImage
    let page: CGSize
    /// The picture's size in pixels, as the Mac sent it.
    let pixels: CGSize
}

/// The browsers of the open flow's agent cards, as this device sees them: what each card's bar and notice
/// show, and the newest picture of each page that is on screen. Pictures come only for the cards the device
/// says it is showing, on the canvas or full screen, and go again once a card leaves the screen.
///
/// Like the terminals, none of it goes through `mirror`: pictures arrive ten times a second, and nothing
/// else on screen is drawn from them.
@Observable
final class BrowserFeeds {
    /// What each watched card's bar and notice show, by card id. Read through `revision`: the canvas draws from
    /// these without being made to work out everything else again ten times a second.
    @ObservationIgnored private(set) var pages: [String: RemoteBrowserPage] = [:]
    /// The newest picture of each watched card's page, by card id.
    @ObservationIgnored private(set) var pictures: [String: BrowserPicture] = [:]
    /// Goes up whenever a page or a picture changes, for the full-screen view to follow.
    private(set) var revision = 0
    /// Goes up when a bar or notice changes, or a card gets its first picture or loses it: not for every picture.
    private(set) var pageRevision = 0
    /// The card whose browser is open full screen.
    private(set) var expandedCard: String?
    /// The last thing the Mac turned down in each card's browser, until the next thing works.
    var refusals: [String: String] = [:]
    /// The text the Mac last sent for Copy, by card.
    @ObservationIgnored var copied: [String: String] = [:]
    /// Called when a card's picture or bar has changed, so its card on the canvas can be drawn again.
    @ObservationIgnored var onChange: ((_ cardID: String) -> Void)?
    /// Tells the Mac which cards are on screen.
    @ObservationIgnored var sendWatch: ((_ cardIDs: [String]) -> Void)?

    /// The browser cards on the canvas's screen just now.
    @ObservationIgnored private var onCanvas: Set<String> = []
    /// What the Mac was last told, or nil when it has been told nothing on this connection and flow.
    @ObservationIgnored private var told: Set<String>?
    @ObservationIgnored private var telling: Task<Void, Never>?
    /// The newest picture of each card that has arrived, counted, so a slow decode of an older one is not drawn over a newer one.
    @ObservationIgnored private var arrived: [String: Int] = [:]
    /// How long a change to what is on screen waits, so a pan across the canvas tells the Mac once and not every frame.
    private static let settle: Duration = .milliseconds(250)
    #if DEBUG
    /// How many pictures have been drawn, for a test.
    @ObservationIgnored private(set) var debugDrawn: [String: Int] = [:]
    /// When the Mac was told what is on screen and when a card's bar first came, for a test to see how long it took.
    @ObservationIgnored private(set) var debugTimes: [String] = []
    private static func clock() -> String { String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) }
    /// The full-screen view's page, for a test to tap as a finger would.
    @ObservationIgnored weak var debugStage: BrowserStageView?
    /// What is in the full-screen view's address bar, and whether its key catcher has the keyboard.
    var debugAddress: String?
    var debugCatching = false
    #endif

    /// The cards the Mac is to send pictures of: those on the canvas's screen, and the one open full screen.
    var watched: Set<String> { onCanvas.union(expandedCard.map { [$0] } ?? []) }

    func receive(_ message: HostMessage) {
        switch message {
        case .browserPage(_, let card, let page):
            guard watched.contains(card) else { return }
            #if DEBUG
            if pages[card] == nil { debugTimes.append("page at \(Self.clock())") }
            #endif
            guard pages[card] != page else { return }
            pages[card] = page
            pageRevision += 1
            changed(card)
        case .browserFrame(_, let card, let frame):
            guard watched.contains(card) else { return }
            let number = (arrived[card] ?? 0) + 1
            arrived[card] = number
            // Decoded away from the main thread: a picture is up to 200 KB of JPEG, ten times a second.
            Task.detached(priority: .userInitiated) { [frame] in
                guard let image = UIImage(data: frame.jpeg)?.preparingForDisplay() else { return }
                await MainActor.run { self.show(image, frame, card: card, number: number) }
            }
        case .browserCopied(_, let card, let text):
            copied[card] = text
        default:
            break
        }
    }

    private func show(_ image: UIImage, _ frame: RemoteBrowserFrame, card: String, number: Int) {
        // A newer one may have arrived and been drawn already, or the card may have left the screen.
        guard arrived[card] == number, watched.contains(card) else { return }
        if pictures[card] == nil { pageRevision += 1 }
        pictures[card] = BrowserPicture(image: image, page: frame.pageSize, pixels: CGSize(width: frame.width, height: frame.height))
        #if DEBUG
        debugDrawn[card, default: 0] += 1
        #endif
        changed(card)
    }

    private func changed(_ card: String) {
        revision += 1
        onChange?(card)
    }

    /// The canvas has these browser cards on its screen now, large enough to read.
    func canvasShows(_ cards: Set<String>) {
        guard cards != onCanvas else { return }
        onCanvas = cards
        watchedChanged()
    }

    /// Opens a card's browser full screen, or with nil closes it.
    func expand(_ card: String?) {
        guard card != expandedCard else { return }
        expandedCard = card
        watchedChanged()
    }

    /// A card that has left the screen keeps no picture: it would be out of date by the time it came back,
    /// and the Mac sends one at once when it does.
    private func watchedChanged() {
        let now = watched
        for card in Set(pages.keys).union(pictures.keys).subtracting(now) {
            pages[card] = nil
            pictures[card] = nil
            arrived[card] = nil
            pageRevision += 1
            changed(card)
        }
        tellSoon()
    }

    private func tellSoon() {
        guard telling == nil else { return }
        telling = Task {
            try? await Task.sleep(for: Self.settle)
            telling = nil
            let now = watched
            guard now != told else { return }
            told = now
            pageRevision += 1
            #if DEBUG
            debugTimes.append("told \(now.count) at \(Self.clock())")
            #endif
            sendWatch?(now.sorted())
        }
    }

    /// A new connection, or the open flow sent afresh: the Mac knows nothing of what is on screen, so it is told again.
    func tellAgain() {
        told = nil
        tellSoon()
    }

    /// Another flow, or no Mac: nothing here is for it.
    func reset() {
        telling?.cancel()
        telling = nil
        pages = [:]
        pictures = [:]
        arrived = [:]
        refusals = [:]
        copied = [:]
        onCanvas = []
        expandedCard = nil
        told = nil
        revision += 1
        pageRevision += 1
    }

    #if DEBUG
    /// What each card's browser shows, for a test that can't see the screen.
    func debugState(names: [String: String], canAct: Bool) -> [String: Any] {
        var cards: [String: Any] = [:]
        for card in Set(pages.keys).union(pictures.keys).union(watched) {
            let page = pages[card], picture = pictures[card]
            cards[names[card] ?? card] = [
                "url": page?.url ?? NSNull(), "title": page?.title ?? NSNull(), "loading": page?.isLoading ?? false,
                "canGoBack": page?.canGoBack ?? false, "canGoForward": page?.canGoForward ?? false,
                "notice": (page ?? RemoteBrowserPage()).notice?.words ?? NSNull(),
                "offer": (page ?? RemoteBrowserPage()).notice?.offer?.title ?? NSNull(),
                "addressProblem": page?.addressProblem ?? NSNull(),
                "hasPicture": picture != nil, "drawn": debugDrawn[card] ?? 0,
                "pageWidth": picture?.page.width ?? 0, "pageHeight": picture?.page.height ?? 0,
                "pixelWidth": picture?.pixels.width ?? 0, "refusal": refusals[card] ?? NSNull(), "copied": copied[card] ?? NSNull(),
            ] as [String: Any]
        }
        return ["cards": cards, "canAct": canAct, "times": debugTimes, "address": expandedCard == nil ? NSNull() : (debugAddress ?? ""), "catching": debugCatching,
                "stage": debugStage.map { ["x": $0.debugFrame.minX, "y": $0.debugFrame.minY, "width": $0.debugFrame.width, "height": $0.debugFrame.height] } ?? NSNull(),
                "watched": watched.compactMap { names[$0] }.sorted(), "told": told.map { $0.compactMap { names[$0] }.sorted() } ?? NSNull(),
                "expanded": expandedCard.flatMap { names[$0] } ?? NSNull()]
    }
    #endif
}
