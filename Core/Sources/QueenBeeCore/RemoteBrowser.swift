import CoreGraphics
import Foundation

// An agent card's browser, seen and used from a paired device. The device says which browser cards it has on
// screen, and the Mac sends each of those a picture of its page a few times a second, and what the card's
// bar and notice show. A device that may control the Mac can then click, scroll and type in the page as the
// person at the Mac can, signed-in sites included: the browser is typing, and is held to what typing is.

extension Remote {
    /// The most pictures of one card's page the Mac sends a device in a second.
    public static let browserFramesASecond = 10.0
    /// The biggest one picture of a page may be, in bytes of JPEG. A bigger one is made smaller first.
    public static let browserFrameLimit = 200_000
    /// The most browser cards one device is sent pictures of at once. It has more on screen only zoomed far
    /// out, where a card shows no page anyway.
    public static let browserWatchLimit = 16
    /// The most text a device may type into a page in one message, in bytes of UTF-8.
    public static let browserTextLimit = 4_096
    /// The longest address, or words to search for, a device may give a card's address bar, in bytes.
    public static let addressLimit = 2_048
    /// The most of a page's selected text a device is sent for its Copy, in characters.
    public static let browserCopyLimit = 100_000
    /// How often a device sends the pointer moving, or a scroll, at most, a second. Finer steps are added
    /// together on the device first.
    public static let pointerStepsASecond = 30.0
    /// The pointer moving and scrolling have a pace of their own on the Mac, apart from every other command's:
    /// a drag sends one every step, and would leave nothing for the click that ends it. This many in a burst,
    /// and this many a second after that.
    public static let pointerBurst = 60.0
    public static let pointersASecond = 40.0
}

/// One picture of a card's page, as the browser drew it.
public struct RemoteBrowserFrame: Codable, Equatable, Sendable {
    public var jpeg: Data
    /// The picture's size in pixels.
    public var width: Int
    public var height: Int
    /// The page's size in the browser's own points, which its clicks and scrolls are given in. The picture is
    /// usually drawn at twice this, which `scale` says.
    public var pageWidth: Double
    public var pageHeight: Double

    public init(jpeg: Data, width: Int, height: Int, pageWidth: Double, pageHeight: Double) {
        self.jpeg = jpeg; self.width = width; self.height = height; self.pageWidth = pageWidth; self.pageHeight = pageHeight
    }

    /// Pixels of the picture to one of the page's points.
    public var scale: Double { pageWidth > 0 ? Double(width) / pageWidth : 1 }
    public var pageSize: CGSize { CGSize(width: pageWidth, height: pageHeight) }
}

/// What a card's browser half shows besides the picture: its bar, and the notice over the page when there is
/// no page to show. Sent when any of it changes, and once when a device starts watching the card.
public struct RemoteBrowserPage: Codable, Equatable, Sendable {
    /// The project's browser, as the Mac's flow list says of it.
    public var status: RemoteBrowserState.Status
    /// How far a download has got, from 0 to 1.
    public var progress: Double?
    /// Why the browser failed, in the Mac's words.
    public var problem: String?
    /// The card's tab is open in the browser.
    public var isAttached: Bool
    /// The Mac has a picture of the page.
    public var hasPicture: Bool
    /// The address bar. Empty for a blank page.
    public var url: String
    public var title: String
    public var isLoading: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// Why the last address typed into the bar didn't open, as the Mac's bar shows it until the page changes.
    public var addressProblem: String?

    public init(status: RemoteBrowserState.Status = .idle, progress: Double? = nil, problem: String? = nil, isAttached: Bool = false,
                hasPicture: Bool = false, url: String = "", title: String = "", isLoading: Bool = false, canGoBack: Bool = false,
                canGoForward: Bool = false, addressProblem: String? = nil) {
        self.status = status; self.progress = progress; self.problem = problem; self.isAttached = isAttached; self.hasPicture = hasPicture
        self.url = url; self.title = title; self.isLoading = isLoading; self.canGoBack = canGoBack; self.canGoForward = canGoForward
        self.addressProblem = addressProblem
    }

    /// What the Mac's card shows over the page, and the button under it.
    public var notice: BrowserNotice? {
        BrowserNotice.of(status, progress: progress, problem: problem, isAttached: isAttached, hasPicture: hasPicture)
    }
}

/// The words a card's browser half shows over the page when there is no page to show, and what its button
/// offers. The Mac's card and a device's show the same.
public struct BrowserNotice: Equatable, Sendable {
    public enum Offer: String, Equatable, Sendable {
        /// Download a browser, when the Mac has none it can use.
        case download
        /// Start the browser again after it failed.
        case tryAgain
        /// Start it again after it stopped.
        case restart

        public var title: String {
            switch self {
            case .download: "Download"
            case .tryAgain: "Try again"
            case .restart: "Restart"
            }
        }
    }

    public var words: String
    public var offer: Offer?

    public init(words: String, offer: Offer? = nil) { self.words = words; self.offer = offer }

    public static let missing = "This card's browser needs Chrome, and there isn't one on this Mac. Queen Bee can download a copy for its own use, about 150 MB."
    public static let starting = "Starting the browser…"
    public static let stopped = "Browser stopped"

    /// Nil when the page itself is what shows.
    public static func of(_ status: RemoteBrowserState.Status, progress: Double?, problem: String?, isAttached: Bool, hasPicture: Bool) -> BrowserNotice? {
        switch status {
        case .missing: BrowserNotice(words: missing, offer: .download)
        case .downloading: BrowserNotice(words: "Downloading the browser… \(Int((progress ?? 0) * 100))%")
        case .failed: BrowserNotice(words: problem ?? "The browser didn't start.", offer: .tryAgain)
        case .stopped: BrowserNotice(words: stopped, offer: .restart)
        case .starting: BrowserNotice(words: starting)
        case .idle, .running: !isAttached && !hasPicture ? BrowserNotice(words: starting) : nil
        }
    }
}

/// The mouse in a card's page. Only the left button: the browser in a card has no menu to open.
public struct RemoteMouse: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pressed, released, moved
    }

    public var kind: Kind
    /// Where, in the page's own points.
    public var x: Double
    public var y: Double
    /// The button is held: a press, or a move that drags.
    public var isDown: Bool
    /// 1 for a click, 2 for a double click.
    public var clicks: Int
    /// The held modifier keys, as Chrome counts them: Option 1, Control 2, Command 4, Shift 8.
    public var modifiers: Int

    public init(_ kind: Kind, x: Double, y: Double, isDown: Bool = false, clicks: Int = 0, modifiers: Int = 0) {
        self.kind = kind; self.x = x; self.y = y; self.isDown = isDown; self.clicks = clicks; self.modifiers = modifiers
    }
}

/// The editing shortcuts a page is sent as the Mac sends them for ⌘A, ⌘Z and ⌘⇧Z.
public enum BrowserShortcut: String, Codable, Equatable, Sendable {
    case selectAll, undo, redo

    /// The letter, the editing command Chrome is told it stands for, and whether Shift is held.
    public var key: (letter: Character, command: String, shift: Bool) {
        switch self {
        case .selectAll: ("a", "selectAll", false)
        case .undo: ("z", "undo", false)
        case .redo: ("z", "redo", true)
        }
    }
}

/// What a device may do in a card's browser: what the person at the Mac does with its mouse, keyboard and bar.
public enum RemoteBrowserAction: Codable, Equatable, Sendable {
    case mouse(RemoteMouse)
    /// A scroll at a point of the page, by so many of its points.
    case wheel(x: Double, y: Double, dx: Double, dy: Double)
    /// One key pressed and let go, by its name in `BrowserKey.named`, such as "Enter" or "ArrowLeft".
    case key(name: String, modifiers: Int)
    /// Text typed, or pasted, as the Mac's paste puts it in.
    case text(String)
    /// What was typed into the address bar: an address, or words to search for. See `BrowserTools.typedAddress`.
    case navigate(String)
    case back, forward, reload
    /// Copy, or Cut: the page's selected text is sent back to the device, then with Cut it is deleted.
    case copy(cut: Bool)
    case shortcut(BrowserShortcut)

    /// False for the pointer moving and a scroll, which come many times a second and are never answered: the
    /// next one says where things have got to. Everything else is answered like any other command.
    public var isAnswered: Bool {
        switch self {
        case .mouse(let mouse): mouse.kind != .moved
        case .wheel: false
        default: true
        }
    }

    /// The pointer moving and scrolling, which have a pace of their own: see `Remote.pointerBurst`.
    public var isPointer: Bool { !isAnswered }

    /// What it is, in a word or two, for nothing but a test.
    public var name: String {
        switch self {
        case .mouse(let mouse): "mouse \(mouse.kind.rawValue)"
        case .wheel: "wheel"
        case .key(let name, _): "key \(name)"
        case .text: "text"
        case .navigate: "navigate"
        case .back: "back"
        case .forward: "forward"
        case .reload: "reload"
        case .copy(let cut): cut ? "cut" : "copy"
        case .shortcut(let shortcut): shortcut.rawValue
        }
    }

    /// Typed text with nothing in it a page would act on besides new lines and tabs, as a terminal's paste is.
    public var cleaned: RemoteBrowserAction {
        switch self {
        case .text(let text): .text(Remote.plainText(text))
        case .navigate(let typed): .navigate(Remote.plainLine(typed))
        default: self
        }
    }

    /// Why this can't be done whatever the page is. Nil when it is fine.
    public var problem: String? {
        func onPage(_ x: Double, _ y: Double) -> Bool { x.isFinite && y.isFinite && abs(x) <= Remote.largestSide && abs(y) <= Remote.largestSide }
        switch self {
        case .mouse(let mouse):
            guard onPage(mouse.x, mouse.y) else { return Self.offPage }
            guard (0...3).contains(mouse.clicks), (0...15).contains(mouse.modifiers) else { return "That isn't a click the browser takes." }
            return nil
        case .wheel(let x, let y, let dx, let dy):
            guard onPage(x, y), onPage(dx, dy) else { return Self.offPage }
            return nil
        case .key(let name, let modifiers):
            guard name.utf8.count <= 16, BrowserKey.named(name) != nil else { return "There is no key called \(Remote.logName(name, or: "that"))." }
            return (0...15).contains(modifiers) ? nil : "That isn't a key the browser takes."
        case .text(let text):
            if text.isEmpty { return "There is nothing to type." }
            return text.utf8.count > Remote.browserTextLimit ? "That is too much to type at once." : nil
        case .navigate(let typed):
            if typed.utf8.count > Remote.addressLimit { return "That address is too long. The most a device can send is \(Remote.addressLimit) characters." }
            if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type an address, or what to search for." }
            // The rules of the Mac's own address bar: a web address, or words to search for, and nothing else.
            do { _ = try BrowserTools.typedAddress(typed) } catch { return (error as? BrowserError)?.description ?? "That address can't be opened." }
            return nil
        case .back, .forward, .reload, .copy, .shortcut:
            return nil
        }
    }

    static let offPage = "That is off the edge of the page."
}

/// How a picture of a page is drawn on a device, and how a point where a finger is becomes a point on the page.
public enum BrowserGeometry {
    /// Where a picture of `content`'s shape is drawn in a view of `size`: as large as fits, kept to its shape,
    /// in the middle, with the room left over on two sides.
    public static func fitted(_ content: CGSize, in size: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / content.width, size.height / content.height)
        let drawn = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
    }

    /// The point on the page, in its own points, under a point of a view of `size` that shows the page fitted.
    /// Nil for a point in the room left over beside the picture.
    public static func pagePoint(at point: CGPoint, in size: CGSize, page: CGSize) -> CGPoint? {
        let drawn = fitted(page, in: size)
        guard drawn.width > 0, (drawn.minX...drawn.maxX).contains(point.x), (drawn.minY...drawn.maxY).contains(point.y) else { return nil }
        let x = (point.x - drawn.minX) / drawn.width * page.width
        let y = (point.y - drawn.minY) / drawn.height * page.height
        return CGPoint(x: min(max(x, 0), page.width), y: min(max(y, 0), page.height))
    }

    /// The same, for a point that may be off the picture, as a drag that has wandered out of it: kept to its edge.
    public static func clampedPagePoint(at point: CGPoint, in size: CGSize, page: CGSize) -> CGPoint {
        let drawn = fitted(page, in: size)
        guard drawn.width > 0 else { return .zero }
        let inside = CGPoint(x: min(max(point.x, drawn.minX), drawn.maxX), y: min(max(point.y, drawn.minY), drawn.maxY))
        return pagePoint(at: inside, in: size, page: page) ?? .zero
    }

    /// A distance a finger moved in the view, as the page's points: for scrolling.
    public static func pageDistance(_ distance: CGSize, in size: CGSize, page: CGSize) -> CGSize {
        let drawn = fitted(page, in: size)
        guard drawn.width > 0, drawn.height > 0 else { return .zero }
        return CGSize(width: distance.width * page.width / drawn.width, height: distance.height * page.height / drawn.height)
    }
}

/// Keeps one card's pictures to a pace a device can take: at most so many a second, one at a time on its way,
/// and when the device falls behind only the newest kept to send next. The older one is dropped, never queued.
///
/// The Mac offers it every picture the browser draws. It says which to send now; one held back goes when
/// `due` says so, which is asked again once the one on its way has gone and once the time has come.
public struct FramePacer<Frame> {
    public let interval: TimeInterval
    private var lastSent: Date?
    /// A picture has been sent and the device hasn't been sent all of it yet.
    public private(set) var isInFlight = false
    /// The newest picture held back.
    public private(set) var held: Frame?
    /// How many pictures were let go because a newer one came before they could be sent.
    public private(set) var dropped = 0
    public private(set) var sent = 0

    public init(framesASecond: Double = Remote.browserFramesASecond) { interval = 1 / framesASecond }

    /// A new picture. Returns it if it is to go now; otherwise it is held, in place of any held before it.
    public mutating func offer(_ frame: Frame, now: Date = Date()) -> Frame? {
        if held != nil { dropped += 1 }
        held = frame
        return due(now: now)
    }

    /// The held picture, if it may go now. It is then on its way until `delivered` is called.
    public mutating func due(now: Date = Date()) -> Frame? {
        guard let frame = held, !isInFlight else { return nil }
        if let lastSent, now.timeIntervalSince(lastSent) < interval { return nil }
        held = nil
        isInFlight = true
        lastSent = now
        sent += 1
        return frame
    }

    /// The picture on its way has gone, or was never sent after all.
    public mutating func delivered() { isInFlight = false }

    /// When to ask `due` again, if a picture is held and only time stands in its way. Nil when nothing is held,
    /// or the one on its way has to go first.
    public var nextTry: Date? {
        guard held != nil, !isInFlight, let lastSent else { return nil }
        return lastSent.addingTimeInterval(interval)
    }

    /// Forgets what is held and what is on its way, as when the device stops watching.
    public mutating func reset() {
        held = nil
        isInFlight = false
        lastSent = nil
    }
}

/// The pointer moving, or scrolls, added together on a device and let go at most so many times a second.
/// Moves keep only the newest place; scrolls add up.
public struct PointerGatherer: Sendable {
    public let interval: TimeInterval
    private var lastSent: Date?

    public init(stepsASecond: Double = Remote.pointerStepsASecond) { interval = 1 / stepsASecond }

    /// Whether a step may go now. If not, `wait` says how long until it may.
    public mutating func mayGo(now: Date = Date()) -> Bool {
        if let lastSent, now.timeIntervalSince(lastSent) < interval { return false }
        lastSent = now
        return true
    }

    public func wait(now: Date = Date()) -> TimeInterval {
        guard let lastSent else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastSent))
    }

    public mutating func reset() { lastSent = nil }
}
