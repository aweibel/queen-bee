import Foundation

/// The app's tool servers: the three JSON-RPC methods Claude Code needs to list and call tools. One serves the
/// orchestrator's tools and one serves an agent the browser in its card.
/// They keep no state, so `tools/list` and `tools/call` work for a client that never sent `initialize`.
public enum MCPServer {
    static let defaultProtocolVersion = "2025-06-18"
    /// The app's version, the same as `MARKETING_VERSION` in project.yml and the plugin's manifest.
    /// `MCPTests` and `./scripts/release.sh` fail when the three disagree.
    public static let version = "0.6.0"

    /// The orchestrator's reply to one message, or nil when it was a notification and expects none.
    public static func handle(_ message: JSONValue, host: any ToolHost) async -> JSONValue? {
        await handle(message, server: "queenbee", definitions: Tools.definitions) {
            await Tools.call(name: $0, arguments: $1, host: host)
        }
    }

    /// The browser tools' reply to one message from an agent, or nil when it expects none.
    public static func handleBrowser(_ message: JSONValue, host: any BrowserToolHost) async -> JSONValue? {
        await handle(message, server: BrowserTools.serverName, definitions: BrowserTools.definitions) {
            await BrowserTools.call(name: $0, arguments: $1, host: host)
        }
    }

    private static func handle(_ message: JSONValue, server: String, definitions: [ToolDefinition],
                               call: (String, JSONValue) async -> ToolResult) async -> JSONValue? {
        guard let id = message["id"], !id.isNull else { return nil }
        let params = message["params"]

        switch message["method"]?.stringValue {
        case "initialize":
            return result(id, [
                "protocolVersion": .string(params?["protocolVersion"]?.stringValue ?? defaultProtocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(server), "version": .string(version)],
            ])

        case "tools/list":
            let tools = definitions.map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            }
            return result(id, ["tools": .array(tools)])

        case "tools/call":
            guard let name = params?["name"]?.stringValue else { return error(id, -32602, "tools/call needs a tool name") }
            let outcome = await call(name, params?["arguments"] ?? [:])
            var content: [JSONValue] = []
            if let image = outcome.image { content.append(["type": "image", "data": .string(image), "mimeType": "image/png"]) }
            if outcome.image == nil || !outcome.text.isEmpty { content.append(["type": "text", "text": .string(outcome.text)]) }
            // A tool that fails is still a successful call: the model reads the text and tries something else.
            return result(id, ["content": .array(content), "isError": .bool(outcome.isError)])

        case "ping":
            return result(id, [:])

        case let method?:
            return error(id, -32601, "Method not found: \(method)")

        case nil:
            return error(id, -32600, "Not a request: it has no method")
        }
    }

    private static func result(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(_ id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
