import Foundation

/// The `qb` helper binary's logic. Claude Code runs it from hooks, the qb-link plugin runs it to route replies
/// and guard messages, and the orchestrator runs it as its tool server. Every mode forwards to the app.
public enum HelperCommand {
    static let usage = """
    usage: qb <hook|route|sent|may-send|mcp|browser-mcp|capabilities>
      hook      forward a Claude Code hook's JSON (stdin) to Queen Bee
      route     send a finished turn's reply (stdin) and print the deliveries to make
      sent      report how a delivery went (stdin)
      may-send  ask whether this session may message another (stdin) and print the answer
      mcp       relay tool-server messages between stdin and stdout
      browser-mcp  the same, for the browser in an agent's card
      capabilities  print what the app can do, as CAPABILITIES.md holds it

    """

    /// Runs one of the one-shot subcommands and returns what to print and the exit code.
    ///
    /// These run inside Claude Code's own turn, so when the app can't be reached they exit 0 with an answer
    /// that leaves the session working as if Queen Bee weren't there.
    public static func run(arguments: [String], environment: [String: String], stdin: Data,
                           send: (WireRequest) throws -> JSONValue) -> (output: Data, exitCode: Int32) {
        let fallback: String
        switch arguments.first {
        case "hook", "sent": fallback = ""
        case "route": fallback = #"{"deliveries":[]}"#
        // Refusing would block every message between sessions whenever the app is closed.
        case "may-send": fallback = #"{"allowed":true}"#
        default: return (Data(usage.utf8), 2)
        }
        let kind = arguments[0]
        let printsReply = !fallback.isEmpty
        func output(_ text: String) -> Data { printsReply ? Data((text + "\n").utf8) : Data() }

        guard let payload = try? JSONValue.parse(stdin) else { return (output(fallback), 0) }
        let request = WireRequest(kind: kind, session: environment["QB_SESSION"] ?? "", payload: payload)
        guard let reply = try? send(request) else { return (output(fallback), 0) }
        // A hook prints nothing, unless the app has something for Claude Code to put in front of the session,
        // which it sends in the shape Claude Code reads.
        if kind == "hook", reply["hookSpecificOutput"] != nil { return (Data((reply.text() + "\n").utf8), 0) }
        return (output(reply.text()), 0)
    }

    /// Relays a tool server's traffic: one JSON-RPC message per line in, one reply per line out. `kind` is "mcp"
    /// for the orchestrator's tools and "browser-mcp" for the browser in an agent's card.
    public static func runMCP(kind: String = "mcp", environment: [String: String], readLine: () -> String?, write: (String) -> Void,
                              send: (WireRequest) throws -> JSONValue) {
        let session = environment["QB_SESSION"] ?? ""
        while let line = readLine() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard let message = try? JSONValue.parse(Data(text.utf8)) else {
                write(MCPServer.error(.null, -32700, "Parse error").text())
                continue
            }
            do {
                let reply = try send(WireRequest(kind: kind, session: session, payload: message))
                if !reply.isNull { write(reply.text()) }
            } catch {
                // A request left unanswered would hang the tool call; a notification expects nothing.
                if let id = message["id"], !id.isNull {
                    write(MCPServer.error(id, -32000, "Queen Bee is not running").text())
                }
            }
        }
    }

    /// The real entry point: process arguments, environment, stdin and stdout, and the app's socket.
    public static func main() -> Never {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment
        let send: (WireRequest) throws -> JSONValue = { request in
            guard let path = environment["QB_SOCKET"], !path.isEmpty else { throw WireError("QB_SOCKET is not set") }
            // Hooks and message guards hold up a turn while they wait, so they give up quickly.
            // Routing and tool calls can sit behind several judge calls.
            let quick: Set<String> = ["hook", "sent", "may-send"]
            return try Wire.send(request, socketPath: path, timeout: quick.contains(request.kind) ? 10 : 300)
        }
        // FileHandle writes straight through, so each reply reaches Claude Code without waiting in a buffer.
        func print(_ data: Data) { try? FileHandle.standardOutput.write(contentsOf: data) }

        // The build writes CAPABILITIES.md from this, so the file is never edited by hand.
        if arguments.first == "capabilities" {
            print(Data(Capabilities.file.utf8))
            exit(0)
        }

        if let kind = arguments.first, kind == "mcp" || kind == "browser-mcp" {
            runMCP(kind: kind, environment: environment,
                   readLine: { Swift.readLine(strippingNewline: true) },
                   write: { print(Data(($0 + "\n").utf8)) },
                   send: send)
            exit(0)
        }

        // Only read stdin for a subcommand that takes it, so a typo at a terminal prints usage instead of hanging.
        let takesInput: Set<String> = ["hook", "route", "sent", "may-send"]
        let input = takesInput.contains(arguments.first ?? "") ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        let result = run(arguments: arguments, environment: environment, stdin: input, send: send)
        print(result.output)
        exit(result.exitCode)
    }
}
