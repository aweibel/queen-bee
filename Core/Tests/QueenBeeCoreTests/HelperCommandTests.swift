import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct HelperCommandTests {
    struct Unreachable: Error {}

    private let environment = ["QB_SESSION": "card-42", "QB_SOCKET": "/tmp/qb.sock"]

    /// Runs a subcommand against an app that answers `reply`, or can't be reached when `reply` is nil.
    private func run(_ arguments: [String], stdin: String, reply: JSONValue?,
                     environment: [String: String]? = nil) -> (output: String, exitCode: Int32, sent: [WireRequest]) {
        var sent: [WireRequest] = []
        let result = HelperCommand.run(arguments: arguments, environment: environment ?? self.environment, stdin: Data(stdin.utf8)) { request in
            sent.append(request)
            guard let reply else { throw Unreachable() }
            return reply
        }
        return (String(decoding: result.output, as: UTF8.self), result.exitCode, sent)
    }

    // MARK: hook

    @Test func hookForwardsTheHookJSONAndPrintsNothing() {
        let result = run(["hook", "Stop"], stdin: #"{"hook_event_name":"Stop","last_assistant_message":"Old pond"}"#, reply: ["ok": true])
        #expect(result.output.isEmpty && result.exitCode == 0)
        #expect(result.sent == [
            WireRequest(kind: "hook", session: "card-42", payload: ["hook_event_name": "Stop", "last_assistant_message": "Old pond"]),
        ])
    }

    @Test func hookPrintsWhatTheAppWantsPutInFrontOfTheSession() throws {
        let context: JSONValue = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": "Read the reference."]]
        let result = run(["hook"], stdin: #"{"hook_event_name":"SessionStart","source":"resume"}"#, reply: context)
        #expect(result.exitCode == 0)
        #expect(try JSONValue.parse(Data(result.output.utf8)) == context)
        // Anything else the app answers with stays unprinted, as Claude Code would try to read it.
        #expect(run(["hook"], stdin: #"{"hook_event_name":"SessionStart"}"#, reply: ["additionalContext": "x"]).output.isEmpty)
    }

    @Test func hookNeverBlocksClaude() {
        let unreachable = run(["hook"], stdin: #"{"hook_event_name":"Stop"}"#, reply: nil)
        #expect(unreachable.output.isEmpty && unreachable.exitCode == 0 && unreachable.sent.count == 1)
        let notJSON = run(["hook"], stdin: "oops", reply: ["ok": true])
        #expect(notJSON.output.isEmpty && notJSON.exitCode == 0 && notJSON.sent.isEmpty)
        let empty = run(["hook"], stdin: "", reply: ["ok": true])
        #expect(empty.output.isEmpty && empty.exitCode == 0)
    }

    @Test func aMissingSessionIsSentAsEmpty() {
        let result = run(["hook"], stdin: "{}", reply: [:], environment: [:])
        #expect(result.sent.first?.session == "")
    }

    // MARK: route

    @Test func routePrintsTheDeliveries() throws {
        let reply: JSONValue = ["deliveries": [["to": "session-2", "text": "[Queen Bee · run ab12 · hand-off 2 · from Writer]\nOld pond"]]]
        let result = run(["route"], stdin: #"{"answer":"Old pond"}"#, reply: reply)
        #expect(result.exitCode == 0)
        #expect(result.sent == [WireRequest(kind: "route", session: "card-42", payload: ["answer": "Old pond"])])
        #expect(result.output.hasSuffix("\n"))
        #expect(try JSONValue.parse(Data(result.output.utf8)) == reply)
    }

    @Test func routeWithNoAppDeliversNothing() {
        #expect(run(["route"], stdin: #"{"answer":"Old pond"}"#, reply: nil).output == "{\"deliveries\":[]}\n")
        #expect(run(["route"], stdin: #"{"answer":"Old pond"}"#, reply: nil).exitCode == 0)
        let notJSON = run(["route"], stdin: "oops", reply: ["deliveries": []])
        #expect(notJSON.output == "{\"deliveries\":[]}\n" && notJSON.exitCode == 0 && notJSON.sent.isEmpty)
    }

    // MARK: sent

    @Test func sentReportsAndPrintsNothing() {
        let result = run(["sent"], stdin: #"{"to":"session-2","ok":false,"error":"not running"}"#, reply: ["ok": true])
        #expect(result.output.isEmpty && result.exitCode == 0)
        #expect(result.sent == [WireRequest(kind: "sent", session: "card-42", payload: ["to": "session-2", "ok": false, "error": "not running"])])
        let unreachable = run(["sent"], stdin: "{}", reply: nil)
        #expect(unreachable.output.isEmpty && unreachable.exitCode == 0)
    }

    // MARK: may-send

    @Test func maySendPrintsTheAppsAnswer() throws {
        let result = run(["may-send"], stdin: #"{"to":"session-2"}"#, reply: ["allowed": false, "reason": "Writer and Tester are not linked"])
        #expect(result.exitCode == 0)
        #expect(result.sent == [WireRequest(kind: "may-send", session: "card-42", payload: ["to": "session-2"])])
        #expect(try JSONValue.parse(Data(result.output.utf8)) == ["allowed": false, "reason": "Writer and Tester are not linked"])
    }

    @Test func maySendAllowsWhenTheAppIsGone() {
        let result = run(["may-send"], stdin: #"{"to":"session-2"}"#, reply: nil)
        #expect(result.output == "{\"allowed\":true}\n" && result.exitCode == 0)
        let notJSON = run(["may-send"], stdin: "", reply: ["allowed": false])
        #expect(notJSON.output == "{\"allowed\":true}\n" && notJSON.exitCode == 0)
    }

    // MARK: usage

    @Test func anUnknownOrMissingSubcommandPrintsUsage() {
        let unknown = run(["dance"], stdin: "", reply: [:])
        #expect(unknown.exitCode == 2 && unknown.output.contains("usage") && unknown.sent.isEmpty)
        let missing = run([], stdin: "", reply: [:])
        #expect(missing.exitCode == 2 && missing.output.contains("usage"))
        for subcommand in ["hook", "route", "sent", "may-send", "mcp"] { #expect(missing.output.contains(subcommand)) }
    }

    // MARK: mcp

    /// Feeds `lines` to the relay and collects what it writes.
    private func relay(_ lines: [String], reply: (WireRequest) throws -> JSONValue) -> [String] {
        var input = lines[...]
        var written: [String] = []
        HelperCommand.runMCP(environment: environment, readLine: { input.popFirst() }, write: { written.append($0) }, send: reply)
        return written
    }

    @Test func theBrowsersRelayMarksItsRequestsAsItsOwn() {
        var input = [#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#][...]
        var sent: [WireRequest] = []
        HelperCommand.runMCP(kind: "browser-mcp", environment: environment, readLine: { input.popFirst() }, write: { _ in }) { request in
            sent.append(request)
            return .null
        }
        #expect(sent.map(\.kind) == ["browser-mcp"])
        #expect(sent.first?.session == "card-42")
    }

    @Test func mcpRelaysEachLineAndWritesEachReply() throws {
        var sent: [WireRequest] = []
        let written = relay([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            "",
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"  {"jsonrpc":"2.0","id":2,"method":"ping"}  "#,
        ]) { request in
            sent.append(request)
            guard let id = request.payload["id"] else { return .null }
            return ["jsonrpc": "2.0", "id": id, "result": [:]]
        }
        #expect(sent.map(\.kind) == ["mcp", "mcp", "mcp"])
        #expect(sent.allSatisfy { $0.session == "card-42" })
        #expect(sent.first?.payload == ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(written.count == 2)
        #expect(written.allSatisfy { !$0.contains("\n") })
        #expect(try written.map { try JSONValue.parse(Data($0.utf8))["id"] } == [1, 2])
    }

    @Test func mcpAnswersWithAnErrorWhenTheAppIsGone() throws {
        let written = relay([
            #"{"jsonrpc":"2.0","id":"abc","method":"tools/call","params":{"name":"get_flow"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        ]) { _ in throw Unreachable() }
        #expect(written.count == 1)
        let reply = try JSONValue.parse(Data(written[0].utf8))
        #expect(reply == ["jsonrpc": "2.0", "id": "abc", "error": ["code": -32000, "message": "Queen Bee is not running"]])
    }

    @Test func mcpAnswersALineThatIsNotJSONWithAParseError() throws {
        var sent = 0
        let written = relay(["{ nope"]) { _ in sent += 1; return .null }
        #expect(sent == 0)
        #expect(written.count == 1)
        let reply = try JSONValue.parse(Data(written[0].utf8))
        #expect(reply["error"]?["code"] == -32700)
        #expect(reply["id"] == .null)
    }
}
