import Foundation
import Testing
@testable import QueenBeeCore

/// A browser that records what it was asked to do.
actor FakeBrowser: BrowserToolHost {
    private(set) var calls: [String] = []
    var failure: BrowserError?

    func fail(with error: BrowserError) { failure = error }

    private func note(_ call: String) throws -> String {
        calls.append(call)
        if let failure { throw failure }
        return "did \(call)"
    }

    func open(_ url: URL) async throws -> String { try note("open \(url.absoluteString)") }
    func read() async throws -> String { try note("read") }
    func screenshot() async throws -> Data { _ = try note("screenshot"); return Data([1, 2, 3]) }
    func scroll(dx: Double, dy: Double) async throws -> String { try note("scroll \(dx) \(dy)") }
    func back() async throws -> String { try note("back") }
    func wait(text: String?, seconds: Double) async throws -> String { try note("wait \(text ?? "-") \(seconds)") }
    func click(ref: Int) async throws -> String { try note("click ref \(ref)") }
    func click(x: Double, y: Double) async throws -> String { try note("click at \(x) \(y)") }
    func type(ref: Int, text: String, submit: Bool) async throws -> String { try note("type \(ref) \(text) \(submit)") }
    func press(_ key: BrowserKey) async throws -> String { try note("press \(key.key)") }
}

@Suite struct BrowserToolsTests {
    // MARK: Addresses

    @Test func webAddressesPass() throws {
        #expect(try BrowserTools.checkedURL("https://example.com/a?b=1").absoluteString == "https://example.com/a?b=1")
        #expect(try BrowserTools.checkedURL("  http://example.com  ").absoluteString == "http://example.com")
        #expect(try BrowserTools.checkedURL("HTTPS://Example.com").host == "Example.com")
    }

    @Test func anAddressWithoutASchemeGetsOne() throws {
        #expect(try BrowserTools.checkedURL("example.com/docs").absoluteString == "https://example.com/docs")
        #expect(try BrowserTools.checkedURL("localhost:3000/app").absoluteString == "http://localhost:3000/app")
        #expect(try BrowserTools.checkedURL("127.0.0.1:8080").absoluteString == "http://127.0.0.1:8080")
        #expect(try BrowserTools.checkedURL("example.com:8443/x").absoluteString == "https://example.com:8443/x")
        #expect(try BrowserTools.checkedURL("[::1]:8080/x").absoluteString == "http://[::1]:8080/x")
        // A name that only starts like this Mac's is somewhere else, and gets an encrypted connection.
        #expect(try BrowserTools.checkedURL("localhost.example.com").absoluteString == "https://localhost.example.com")
        #expect(try BrowserTools.checkedURL("127.0.0.1.example.com/a").absoluteString == "https://127.0.0.1.example.com/a")
        // An address inside another address's query doesn't count as its scheme.
        #expect(try BrowserTools.checkedURL("example.com/r?u=http://x.com").absoluteString == "https://example.com/r?u=http://x.com")
    }

    @Test(arguments: [
        "file:///etc/passwd", "file://localhost/etc/passwd", "chrome://settings", "javascript:alert(1)",
        "data:text/html,<h1>hi</h1>", "about:blank", "view-source:https://example.com", "ftp://example.com/x",
        "chrome-extension://abc/page.html", "blob:https://example.com/1", "FILE:///etc/passwd", "", "   ",
        "https://", "two words.com", "https://exa mple.com", "http:foo", "//example.com", "JaVaScRiPt://x/%0aalert(1)",
    ])
    func anythingButAWebAddressIsRefused(_ raw: String) {
        #expect(throws: BrowserError.self) { try BrowserTools.checkedURL(raw) }
    }

    // MARK: Calls

    private func call(_ name: String, _ arguments: JSONValue = [:], on browser: FakeBrowser = FakeBrowser()) async -> (ToolResult, [String]) {
        let result = await BrowserTools.call(name: name, arguments: arguments, host: browser)
        return (result, await browser.calls)
    }

    @Test func openChecksTheAddressBeforeTheBrowserSeesIt() async {
        let (bad, badCalls) = await call("open", ["url": "file:///etc/passwd"])
        #expect(bad.isError && bad.text.contains("http"))
        #expect(badCalls.isEmpty)
        let (good, goodCalls) = await call("open", ["url": "example.com"])
        #expect(!good.isError)
        #expect(goodCalls == ["open https://example.com"])
        let (missing, _) = await call("open")
        #expect(missing.isError && missing.text.contains("url"))
    }

    @Test func screenshotComesBackAsAPicture() async {
        let (result, _) = await call("screenshot")
        #expect(!result.isError)
        #expect(result.image == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func scrollTurnsADirectionIntoScreens() async {
        #expect(await call("scroll").1 == ["scroll 0.0 1.0"])
        #expect(await call("scroll", ["direction": "up", "amount": 2]).1 == ["scroll 0.0 -2.0"])
        #expect(await call("scroll", ["direction": "Left", "amount": "0.5"]).1 == ["scroll -0.5 0.0"])
        #expect(await call("scroll", ["direction": "right", "amount": 500]).1 == ["scroll 20.0 0.0"])
        let (bad, calls) = await call("scroll", ["direction": "sideways"])
        #expect(bad.isError && calls.isEmpty)
    }

    @Test func waitIsCappedAndHasDefaults() async {
        #expect(await call("wait").1 == ["wait - 2.0"])
        #expect(await call("wait", ["text": "Done"]).1 == ["wait Done 10.0"])
        #expect(await call("wait", ["text": "Done", "seconds": 600]).1 == ["wait Done 30.0"])
        #expect(await call("wait", ["seconds": -4]).1 == ["wait - 0.0"])
    }

    @Test func clickTakesARefOrAPoint() async {
        #expect(await call("click", ["ref": 14]).1 == ["click ref 14"])
        #expect(await call("click", ["ref": "7"]).1 == ["click ref 7"])
        #expect(await call("click", ["x": 10, "y": .number(20.5)]).1 == ["click at 10.0 20.5"])
        let (neither, calls) = await call("click", ["x": 10])
        #expect(neither.isError && calls.isEmpty)
    }

    @Test func typeNeedsARefAndText() async {
        #expect(await call("type", ["ref": 3, "text": "hello"]).1 == ["type 3 hello false"])
        #expect(await call("type", ["ref": 3, "text": "", "submit": true]).1 == ["type 3  true"])
        #expect(await call("type", ["text": "hello"]).0.isError)
        #expect(await call("type", ["ref": 3]).0.isError)
    }

    @Test func pressTakesNamedKeysAndSingleCharacters() async {
        #expect(await call("press", ["key": "enter"]).1 == ["press Enter"])
        #expect(await call("press", ["key": "Esc"]).1 == ["press Escape"])
        #expect(await call("press", ["key": "a"]).1 == ["press a"])
        let (bad, calls) = await call("press", ["key": "Hyper"])
        #expect(bad.isError && bad.text.contains("Enter") && calls.isEmpty)
    }

    @Test func aBrowserFailureIsAToolErrorWithItsWords() async {
        let browser = FakeBrowser()
        await browser.fail(with: BrowserError("The browser has stopped"))
        let (result, _) = await call("read", on: browser)
        #expect(result == ToolResult(text: "The browser has stopped", isError: true))
    }

    @Test func anUnknownToolIsAnError() async {
        #expect(await call("download").0.isError)
    }

    // MARK: Definitions

    @Test func everyToolIsDefinedOnceAndTheLookingOnesExist() {
        let names = BrowserTools.definitions.map(\.name)
        #expect(names == ["open", "read", "screenshot", "scroll", "back", "wait", "click", "type", "press"])
        #expect(Set(BrowserTools.lookingTools).isSubset(of: Set(names)))
        // The tools that change a page are never on the list an agent may use without asking.
        for acting in ["click", "type", "press"] { #expect(!BrowserTools.lookingTools.contains(acting)) }
        #expect(BrowserTools.allowedWithoutAsking.contains("mcp__qb-browser__open"))
        #expect(BrowserTools.allowedWithoutAsking.count == 6)
    }

    @Test func theOrchestratorIsToldEveryToolAndWhatTheBrowserCannotDo() throws {
        for tool in BrowserTools.definitions { #expect(BrowserTools.summary.contains(tool.name)) }
        #expect(BrowserTools.summary.contains("one tab per card"))
        let setting = try #require(Tools.definitions.first { $0.name == "add_card" }?.inputSchema["properties"]?["browser"]?["description"]?.stringValue)
        #expect(setting.contains(BrowserTools.summary))
    }

    // MARK: The tool server

    @Test func theBrowserServerListsOnlyBrowserTools() async throws {
        let reply = try #require(await MCPServer.handleBrowser(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], host: FakeBrowser()))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == BrowserTools.definitions.map(\.name))
        let hello = try #require(await MCPServer.handleBrowser(["jsonrpc": "2.0", "id": 2, "method": "initialize"], host: FakeBrowser()))
        #expect(hello["result"]?["serverInfo"]?["name"] == "qb-browser")
    }

    @Test func theBrowserServerReturnsAPictureAsImageContent() async throws {
        let reply = try #require(await MCPServer.handleBrowser([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "screenshot"],
        ], host: FakeBrowser()))
        #expect(reply["result"] == ["content": [["type": "image", "data": "AQID", "mimeType": "image/png"]], "isError": false])
    }

    @Test func theBrowserServerReturnsTextForTheRest() async throws {
        let reply = try #require(await MCPServer.handleBrowser([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "back"],
        ], host: FakeBrowser()))
        #expect(reply["result"] == ["content": [["type": "text", "text": "did back"]], "isError": false])
    }

    @Test func theOrchestratorsServerHasNoBrowserTools() async throws {
        let reply = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "open", "arguments": ["url": "https://example.com"]],
        ], host: FakeHost()))
        #expect(reply["result"]?["isError"] == true)
    }

    // MARK: Keys

    @Test func keysCarryTheCodesPagesRead() {
        #expect(BrowserKey.named("Return") == BrowserKey(key: "Enter", code: "Enter", keyCode: 13, text: "\r"))
        #expect(BrowserKey.named("down")?.key == "ArrowDown")
        #expect(BrowserKey.named("q") == BrowserKey(key: "q", code: "KeyQ", keyCode: 81, text: "q"))
        #expect(BrowserKey.named("Q") == BrowserKey(key: "Q", code: "KeyQ", keyCode: 81, text: "Q"))
        #expect(BrowserKey.named("7") == BrowserKey(key: "7", code: "Digit7", keyCode: 55, text: "7"))
        #expect(BrowserKey.named(" ")?.code == "Space")
        #expect(BrowserKey.named("é")?.text == "é")
        #expect(BrowserKey.named("Hyper") == nil)
        #expect(BrowserKey.named("") == nil)
    }

    // MARK: The pipe

    @Test func aCommandIsJSONEndedByAZeroByte() throws {
        let data = CDP.command(id: 7, method: "Page.navigate", params: ["url": "https://example.com"], sessionID: "S1")
        #expect(data.last == 0)
        let json = try JSONValue.parse(data.dropLast())
        #expect(json == ["id": 7, "method": "Page.navigate", "params": ["url": "https://example.com"], "sessionId": "S1"])
        let plain = try JSONValue.parse(CDP.command(id: 1, method: "Browser.getVersion").dropLast())
        #expect(plain["sessionId"] == nil)
    }

    @Test func messagesAreSplitOnZeroBytesAndAPartialOneWaits() {
        var buffer = Data(#"{"id":1}"#.utf8) + [0] + Data(#"{"id":2}"#.utf8) + [0] + Data(#"{"id":"#.utf8)
        let first = CDP.messages(from: &buffer).map { String(decoding: $0, as: UTF8.self) }
        #expect(first == [#"{"id":1}"#, #"{"id":2}"#])
        #expect(String(decoding: buffer, as: UTF8.self) == #"{"id":"#)
        buffer.append(Data("3}".utf8) + [0])
        #expect(CDP.messages(from: &buffer).map { String(decoding: $0, as: UTF8.self) } == [#"{"id":3}"#])
        #expect(buffer.isEmpty)
        #expect(CDP.messages(from: &buffer).isEmpty)
    }
}
