import Foundation

/// The orchestrator's tool server: the three JSON-RPC methods Claude Code needs to list and call tools.
/// It keeps no state, so `tools/list` and `tools/call` work for a client that never sent `initialize`.
public enum MCPServer {
    static let defaultProtocolVersion = "2025-06-18"

    /// The reply to one message, or nil when it was a notification and expects none.
    public static func handle(_ message: JSONValue, host: any ToolHost) async -> JSONValue? {
        guard let id = message["id"], !id.isNull else { return nil }
        let params = message["params"]

        switch message["method"]?.stringValue {
        case "initialize":
            return result(id, [
                "protocolVersion": .string(params?["protocolVersion"]?.stringValue ?? defaultProtocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "queenbee", "version": "0.3.4"],
            ])

        case "tools/list":
            let tools = Tools.definitions.map { tool -> JSONValue in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            }
            return result(id, ["tools": .array(tools)])

        case "tools/call":
            guard let name = params?["name"]?.stringValue else { return error(id, -32602, "tools/call needs a tool name") }
            let outcome = await Tools.call(name: name, arguments: params?["arguments"] ?? [:], host: host)
            // A tool that fails is still a successful call: the model reads the text and tries something else.
            return result(id, ["content": [["type": "text", "text": .string(outcome.text)]], "isError": .bool(outcome.isError)])

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
