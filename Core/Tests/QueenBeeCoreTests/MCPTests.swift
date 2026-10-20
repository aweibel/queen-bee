import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct MCPTests {
    @Test func initializeEchoesTheClientsProtocolVersion() async throws {
        let reply = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.1.295"]],
        ], host: FakeHost()))
        #expect(reply["jsonrpc"] == "2.0")
        #expect(reply["id"] == 1)
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["protocolVersion"] == "2025-03-26")
        #expect(reply["result"]?["capabilities"] == ["tools": [:]])
        #expect(reply["result"]?["serverInfo"] == ["name": "queenbee", "version": .string(MCPServer.version)])
    }

    /// The version is typed in three places: project.yml, which the app's bundle takes it from, `MCPServer.version`
    /// and the plugin's manifest. The release script checks the same, so a release can't go out with them apart.
    @Test func theVersionIsTheSameEverywhere() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let marketing = project.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "MARKETING_VERSION" else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        #expect(marketing == [MCPServer.version], "MARKETING_VERSION in project.yml and MCPServer.version in MCP.swift must match")
        let manifest = try Data(contentsOf: root.appendingPathComponent("Plugin/qb-link/.claude-plugin/plugin.json"))
        let plugin = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(plugin?["version"] as? String == MCPServer.version,
                "the version in Plugin/qb-link/.claude-plugin/plugin.json must match MCPServer.version")
    }

    @Test func initializeDefaultsTheProtocolVersion() async throws {
        let reply = try #require(await MCPServer.handle(["jsonrpc": "2.0", "id": "a", "method": "initialize"], host: FakeHost()))
        #expect(reply["id"] == "a")
        #expect(reply["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test func toolsListWorksWithoutInitialize() async throws {
        let reply = try #require(await MCPServer.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"], host: FakeHost()))
        let tools = try #require(reply["result"]?["tools"]?.arrayValue)
        #expect(tools.map { $0["name"]?.stringValue } == Tools.definitions.map(\.name))
        for (tool, definition) in zip(tools, Tools.definitions) {
            #expect(tool["description"] == .string(definition.description))
            #expect(tool["inputSchema"] == definition.inputSchema)
        }
    }

    @Test func toolsCallRunsTheToolAgainstTheHost() async throws {
        let host = FakeHost()
        let reply = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "add_card", "arguments": ["kind": "agent", "name": "Writer"]],
        ], host: host))
        #expect(reply["id"] == 3)
        #expect(reply["result"]?["isError"] == false)
        let content = try #require(reply["result"]?["content"]?.arrayValue)
        #expect(content.count == 1)
        #expect(content[0]["type"] == "text")
        #expect(content[0]["text"]?.stringValue?.contains("Writer") == true)
        #expect(await host.flow.resolveCard("Writer") != nil)
    }

    @Test func aFailedToolIsAResultNotAProtocolError() async throws {
        let reply = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "remove_card", "arguments": ["card": "Ghost"]],
        ], host: FakeHost()))
        #expect(reply["error"] == nil)
        #expect(reply["result"] == ["content": [["type": "text", "text": "No card called \"Ghost\""]], "isError": true])
    }

    @Test func toolsCallWithoutArgumentsStillRuns() async throws {
        let reply = try #require(await MCPServer.handle([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "get_run_log"],
        ], host: FakeHost()))
        #expect(reply["result"]?["isError"] == false)
    }

    @Test func toolsCallWithoutANameIsInvalidParams() async throws {
        let reply = try #require(await MCPServer.handle(["jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": [:]], host: FakeHost()))
        #expect(reply["error"]?["code"] == -32602)
        #expect(reply["result"] == nil)
    }

    @Test func pingAnswersWithAnEmptyResult() async throws {
        let reply = try #require(await MCPServer.handle(["jsonrpc": "2.0", "id": 7, "method": "ping"], host: FakeHost()))
        #expect(reply == ["jsonrpc": "2.0", "id": 7, "result": [:]])
    }

    @Test func notificationsGetNoReply() async {
        #expect(await MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], host: FakeHost()) == nil)
        #expect(await MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 1]], host: FakeHost()) == nil)
        #expect(await MCPServer.handle(["jsonrpc": "2.0", "method": "no/such/thing"], host: FakeHost()) == nil)
        #expect(await MCPServer.handle("not an object", host: FakeHost()) == nil)
    }

    @Test func anUnknownMethodIsMethodNotFound() async throws {
        let reply = try #require(await MCPServer.handle(["jsonrpc": "2.0", "id": 8, "method": "resources/list"], host: FakeHost()))
        #expect(reply["id"] == 8)
        #expect(reply["error"]?["code"] == -32601)
        #expect(reply["error"]?["message"]?.stringValue?.contains("resources/list") == true)
        #expect(reply["result"] == nil)
    }
}
