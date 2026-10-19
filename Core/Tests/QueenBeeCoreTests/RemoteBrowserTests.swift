import CoreGraphics
import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteBrowserTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try Remote.decode(T.self, from: Remote.encode(value))
    }

    // MARK: Messages

    @Test func theNewMessagesSurviveTheTrip() throws {
        let frame = RemoteBrowserFrame(jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1120, height: 680, pageWidth: 560, pageHeight: 340)
        let page = RemoteBrowserPage(status: .running, isAttached: true, hasPicture: true, url: "http://127.0.0.1:8000/", title: "Test Shop",
                                     isLoading: true, canGoBack: true, addressProblem: "no site has that name")
        let host: [HostMessage] = [
            .browserFrame(id: "f", card: "c", frame: frame), .browserPage(id: "f", card: "c", page: page),
            .browserCopied(id: "f", card: "c", text: "selected words"),
        ]
        for message in host { #expect(try roundTrip(message) == message) }
        #expect(try roundTrip(DeviceMessage.watchBrowsers(flowID: "f", cardIDs: ["a", "b"])) == .watchBrowsers(flowID: "f", cardIDs: ["a", "b"]))
        let actions: [RemoteBrowserAction] = [
            .mouse(RemoteMouse(.pressed, x: 10, y: 20, isDown: true, clicks: 1)), .mouse(RemoteMouse(.moved, x: 11, y: 21, isDown: true)),
            .wheel(x: 1, y: 2, dx: 0, dy: -120), .key(name: "Enter", modifiers: 0), .text("hi Bee"), .navigate("example.com"),
            .back, .forward, .reload, .copy(cut: true), .shortcut(.redo),
        ]
        for action in actions {
            let message = DeviceMessage.command(id: 4, command: .browser(flowID: "f", cardID: "c", action: action))
            #expect(try roundTrip(message) == message)
        }
        #expect(frame.scale == 2)
    }

    @Test func aDeviceOnTheOldVersionIsToldToUpdate() {
        // Stage 4's browser came with version 5.
        #expect(Remote.version == 5)
    }

    @Test func browserCommandsAreForTheirFlowAndAreNotEdits() {
        let command = RemoteCommand.browser(flowID: "f", cardID: "c", action: .text("x"))
        #expect(command.flowID == "f")
        #expect(!command.isEdit)
        #expect(!command.canTakeTime)
    }

    @Test func thePointerMovingAndScrollingAreNotAnsweredAndEverythingElseIs() {
        func answered(_ action: RemoteBrowserAction) -> Bool { RemoteCommand.browser(flowID: "f", cardID: "c", action: action).isAnswered }
        #expect(!answered(.mouse(RemoteMouse(.moved, x: 1, y: 1))))
        #expect(!answered(.mouse(RemoteMouse(.moved, x: 1, y: 1, isDown: true))))
        #expect(!answered(.wheel(x: 1, y: 1, dx: 0, dy: 10)))
        #expect(answered(.mouse(RemoteMouse(.pressed, x: 1, y: 1, isDown: true, clicks: 1))))
        #expect(answered(.mouse(RemoteMouse(.released, x: 1, y: 1, clicks: 1))))
        #expect(answered(.key(name: "Tab", modifiers: 0)))
        #expect(answered(.copy(cut: false)))
        #expect(RemoteBrowserAction.wheel(x: 0, y: 0, dx: 0, dy: 1).isPointer)
        #expect(!RemoteBrowserAction.reload.isPointer)
    }

    // MARK: Caps

    @Test func textIsCappedAtFourKilobytes() {
        func problem(_ action: RemoteBrowserAction) -> String? { RemoteCommand.browser(flowID: "f", cardID: "c", action: action).problem }
        #expect(problem(.text(String(repeating: "a", count: Remote.browserTextLimit))) == nil)
        #expect(problem(.text(String(repeating: "a", count: Remote.browserTextLimit + 1))) != nil)
        // Counted in bytes: a character can be four of them.
        #expect(problem(.text(String(repeating: "😀", count: Remote.browserTextLimit / 4 + 1))) != nil)
        #expect(problem(.text("")) != nil)
    }

    @Test func anAddressIsCappedAtTwoKilobytes() {
        let long = "example.com/" + String(repeating: "a", count: Remote.addressLimit)
        #expect(RemoteBrowserAction.navigate(long).problem?.contains("too long") == true)
        #expect(RemoteBrowserAction.navigate("example.com/" + String(repeating: "a", count: 100)).problem == nil)
        #expect(RemoteBrowserAction.navigate("   ").problem != nil)
    }

    @Test func onlyRealKeysAndPointsOnThePagePass() {
        #expect(RemoteBrowserAction.key(name: "Enter", modifiers: 0).problem == nil)
        #expect(RemoteBrowserAction.key(name: "a", modifiers: 4).problem == nil)
        #expect(RemoteBrowserAction.key(name: "Hyper", modifiers: 0).problem != nil)
        #expect(RemoteBrowserAction.key(name: "Enter", modifiers: 99).problem != nil)
        #expect(RemoteBrowserAction.mouse(RemoteMouse(.pressed, x: .nan, y: 0)).problem != nil)
        #expect(RemoteBrowserAction.mouse(RemoteMouse(.pressed, x: 1e9, y: 0)).problem != nil)
        #expect(RemoteBrowserAction.mouse(RemoteMouse(.pressed, x: 5, y: 5, clicks: 9)).problem != nil)
        #expect(RemoteBrowserAction.wheel(x: 5, y: 5, dx: .infinity, dy: 0).problem != nil)
        #expect(RemoteBrowserAction.wheel(x: 5, y: 5, dx: 0, dy: -300).problem == nil)
    }

    @Test func typedTextIsMadeSafe() {
        #expect(RemoteBrowserAction.text("a\u{1B}[31mb\r\n").cleaned == .text("a[31mb\n"))
        #expect(RemoteBrowserAction.navigate("example.com\n/x").cleaned == .navigate("example.com /x"))
    }

    // MARK: The address bar's rules

    @Test func theAddressBarOpensAddressesAndSearchesForWords() throws {
        #expect(try BrowserTools.typedAddress("example.com/docs").absoluteString == "https://example.com/docs")
        #expect(try BrowserTools.typedAddress("localhost:3000").absoluteString == "http://localhost:3000")
        #expect(try BrowserTools.typedAddress("127.0.0.1:8080/two.html").absoluteString == "http://127.0.0.1:8080/two.html")
        #expect(try BrowserTools.typedAddress("https://example.com").absoluteString == "https://example.com")
        let search = try BrowserTools.typedAddress("red apples")
        #expect(search.host == "www.google.com" && search.query == "q=red%20apples")
        // Words with a colon in them are still words.
        #expect(try BrowserTools.typedAddress("note: buy apples").host == "www.google.com")
    }

    @Test(arguments: ["javascript:alert(1)", "javascript:void(document.title='x')", "file:///etc/passwd", "chrome://settings",
                      "data:text/html,hi", "about:blank", "mailto:someone@example.com", "view-source:https://example.com", "JAVASCRIPT:alert(1)"])
    func theAddressBarRefusesWhatIsNotAWebAddress(_ typed: String) {
        #expect(throws: BrowserError.self) { try BrowserTools.typedAddress(typed) }
        #expect(RemoteBrowserAction.navigate(typed).problem?.contains("http") == true)
    }

    // MARK: Notices

    @Test func theNoticesAreTheMacsOwn() {
        func notice(_ status: RemoteBrowserState.Status, attached: Bool = false, picture: Bool = false, problem: String? = nil, progress: Double? = nil) -> BrowserNotice? {
            RemoteBrowserPage(status: status, progress: progress, problem: problem, isAttached: attached, hasPicture: picture).notice
        }
        #expect(notice(.missing)?.offer == .download)
        #expect(notice(.missing)?.words.contains("download a copy") == true)
        #expect(notice(.downloading, progress: 0.45)?.words == "Downloading the browser… 45%")
        #expect(notice(.downloading)?.offer == nil)
        #expect(notice(.failed, problem: "It crashed")?.words == "It crashed")
        #expect(notice(.failed, problem: "It crashed")?.offer == .tryAgain)
        #expect(notice(.stopped) == BrowserNotice(words: "Browser stopped", offer: .restart))
        #expect(notice(.starting)?.words == "Starting the browser…")
        #expect(notice(.idle)?.words == "Starting the browser…")
        #expect(notice(.running, attached: true) == nil)
        #expect(notice(.running, picture: true) == nil)
        #expect(BrowserNotice.Offer.tryAgain.title == "Try again")
    }

    // MARK: Where a finger is on the page

    @Test func aPictureIsFittedInTheMiddleKeepingItsShape() {
        // A page twice as wide as it is tall, in a square view: room above and below.
        let drawn = BrowserGeometry.fitted(CGSize(width: 600, height: 300), in: CGSize(width: 300, height: 300))
        #expect(drawn == CGRect(x: 0, y: 75, width: 300, height: 150))
        let tall = BrowserGeometry.fitted(CGSize(width: 300, height: 600), in: CGSize(width: 400, height: 300))
        #expect(tall == CGRect(x: 125, y: 0, width: 150, height: 300))
        #expect(BrowserGeometry.fitted(.zero, in: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func aPointInTheViewIsAPointOnThePage() {
        let page = CGSize(width: 560, height: 340), view = CGSize(width: 1120, height: 680)
        // Drawn at twice the page's size, with no room over.
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 240, y: 180), in: view, page: page) == CGPoint(x: 120, y: 90))
        #expect(BrowserGeometry.pagePoint(at: .zero, in: view, page: page) == .zero)
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 1120, y: 680), in: view, page: page) == CGPoint(x: 560, y: 340))
    }

    @Test func theRoomBesideThePictureIsNotThePage() {
        let page = CGSize(width: 600, height: 300), view = CGSize(width: 300, height: 300)
        // The picture is 150 tall from y 75: the bands above and below are empty.
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 150, y: 20), in: view, page: page) == nil)
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 150, y: 290), in: view, page: page) == nil)
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 150, y: 150), in: view, page: page) == CGPoint(x: 300, y: 150))
        #expect(BrowserGeometry.pagePoint(at: CGPoint(x: 0, y: 75), in: view, page: page) == .zero)
        // A drag that wanders off is kept to the edge.
        #expect(BrowserGeometry.clampedPagePoint(at: CGPoint(x: -40, y: 400), in: view, page: page) == CGPoint(x: 0, y: 300))
    }

    @Test func aFingerMovingIsTheSameDistanceOnThePage() {
        let moved = BrowserGeometry.pageDistance(CGSize(width: 10, height: -30), in: CGSize(width: 300, height: 300), page: CGSize(width: 600, height: 300))
        #expect(moved == CGSize(width: 20, height: -60))
    }

    // MARK: Pace

    @Test func picturesGoAtMostTenASecondOneAtATime() {
        var pacer = FramePacer<Int>()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(pacer.offer(1, now: start) == 1)
        // Still on its way: the next is held.
        #expect(pacer.offer(2, now: start.addingTimeInterval(0.2)) == nil)
        #expect(pacer.nextTry == nil)
        pacer.delivered()
        #expect(pacer.due(now: start.addingTimeInterval(0.2)) == 2)
        pacer.delivered()
        // Gone, but too soon after the last.
        #expect(pacer.offer(3, now: start.addingTimeInterval(0.25)) == nil)
        #expect(abs((pacer.nextTry ?? start).timeIntervalSince(start) - 0.3) < 0.001)
        #expect(pacer.due(now: start.addingTimeInterval(0.29)) == nil)
        #expect(pacer.due(now: start.addingTimeInterval(0.301)) == 3)
        #expect(pacer.sent == 3 && pacer.dropped == 0)
    }

    @Test func aDeviceThatFallsBehindGetsTheNewestPictureAndNoQueue() {
        var pacer = FramePacer<Int>()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = pacer.offer(0, now: start)
        // The device reads nothing for a while, and the browser draws sixty more.
        for n in 1...60 { #expect(pacer.offer(n, now: start.addingTimeInterval(Double(n) / 60)) == nil) }
        #expect(pacer.held == 60)
        #expect(pacer.dropped == 59)
        pacer.delivered()
        #expect(pacer.due(now: start.addingTimeInterval(2)) == 60)
        #expect(pacer.held == nil)
    }

    @Test func overASecondNoMoreThanTenGo() {
        var pacer = FramePacer<Int>()
        let start = Date(timeIntervalSince1970: 1_000)
        var sent = 0
        // Sixty a second for a second, each sent at once.
        for n in 0..<60 {
            let now = start.addingTimeInterval(Double(n) / 60)
            if pacer.due(now: now) != nil { sent += 1; pacer.delivered() }
            if pacer.offer(n, now: now) != nil { sent += 1; pacer.delivered() }
        }
        // Never more than ten. Steps that fall a hair short of a tenth of a second wait for the next.
        #expect(sent <= 10 && sent >= 8)
    }

    @Test func stoppingForgetsWhatWasHeld() {
        var pacer = FramePacer<Int>()
        _ = pacer.offer(1)
        _ = pacer.offer(2)
        pacer.reset()
        #expect(pacer.held == nil && !pacer.isInFlight)
        #expect(pacer.offer(3) == 3)
    }

    @Test func thePointerIsLetGoAtMostThirtyTimesASecond() {
        var gatherer = PointerGatherer()
        let start = Date(timeIntervalSince1970: 1_000)
        var went = 0
        for n in 0..<120 where gatherer.mayGo(now: start.addingTimeInterval(Double(n) / 120)) { went += 1 }
        #expect(went <= 30 && went >= 20)
        #expect(gatherer.wait(now: start.addingTimeInterval(1)) <= 1.0 / 30)
    }
}
