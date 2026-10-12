// A stand-in for a paired device, for scripts/e2e.py. It pairs with a test copy of the app over this
// machine's loopback, connects, opens a flow, and prints one line of JSON for everything it is sent.
//
//   qb-remote-check --code <pairing code> --pair-port <n> --flow <id> [--seconds <n>]
//   qb-remote-check --port <n> --device <id> --wrong-key
//
// After pairing it prints the device id, then waits for the device's port on standard input.
// After that each line on standard input is something more for it to do:
//   open <flow id>   look at another flow
//   reconnect        connect again, as a device does when it thinks the link has dropped
//   silent           open a second connection and say nothing on it
//   stranger         open a second connection and say hello as some other device
//   {"id": 1, "do": "run", "flow": "<flow id>", ...}
//                    send a command, as a device that may control the Mac does. "do" is the command's name.
//                    The rest are whichever of "card", "hold", "key", "text" and "hex" (key presses, as
//                    hexadecimal) that command takes. Nothing is checked here: the Mac has to do that.
//                    The Mac's answer is printed as {"type": "answer", "id": 1, "refusal": null or its reason}.
//                    The commands that edit a flow take whichever of these they need: "kind", "x", "y",
//                    "moves" ({card id: [x, y]}), "frame" ([x, y, width, height]), "final", "cards" and
//                    "links" (lists of ids), "from", "port", "to", "link", "passes", "group", "name", "folded",
//                    "patch" (a card's settings, named as RemoteCardPatch names them), "limit" or "notify"
//                    (a flow's own settings) and "project".
//   {"raw": {...}}   send that JSON as it is, as a device with an app of its own making could.
// It never prints a key.
import Foundation
import Network
import QueenBeeCore
import QueenBeeLink

func say(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func local(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

if CommandLine.arguments.contains("--wrong-key") {
    // A device that was never paired: it knows where to connect and has no key.
    guard let port = option("--port").flatMap(UInt16.init), port != 0 else {
        say(["type": "usage"])
        exit(2)
    }
    let connection = LinkConnection(to: local(port), key: LinkSecurity.randomKey())
    do {
        try await connection.start(timeout: 4)
        try await connection.send(DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: option("--device") ?? "", deviceName: "Stranger")))
        _ = try await connection.receive(HostMessage.self)
        say(["type": "let-in"])
    } catch {
        // The error tells a listener that turned the key down from nothing listening at all.
        say(["type": "kept-out", "error": "\(error)"])
    }
    exit(0)
}

guard let code = option("--code").flatMap(PairingCode.init(text:)), let pairPort = option("--pair-port").flatMap(UInt16.init),
      pairPort != 0, let flowID = option("--flow") else {
    say(["type": "usage"])
    exit(2)
}
let seconds = option("--seconds").flatMap(Double.init) ?? 20
// In capitals, as an iPad or iPhone gives its id. The Mac keeps ids in lower case and must still know this one.
let deviceID = UUID().uuidString.uppercased()

let grant: PairGrant
do {
    let pairing = LinkConnection(to: local(pairPort), key: code.secret)
    try await pairing.start(timeout: 5)
    try await pairing.send(PairRequest(version: Remote.version, deviceID: deviceID, deviceName: "Test device"))
    switch try await pairing.receive(PairReply.self) {
    case .granted(let granted): grant = granted
    case .refused(let reason):
        say(["type": "pair-refused", "reason": reason])
        exit(0)
    }
    pairing.close()
} catch {
    say(["type": "pair-failed", "error": "\(error)"])
    exit(0)
}
// The id the Mac says it kept, which is the one the script asks the app about.
say(["type": "paired", "device": grant.deviceID, "mac": grant.macName.isEmpty ? "" : "named"])

guard let port = readLine().flatMap({ UInt16($0.trimmingCharacters(in: .whitespaces)) }), port != 0 else {
    say(["type": "no-port"])
    exit(2)
}

/// What the reader of standard input and the reader of the connection both need.
final class Shared: @unchecked Sendable {
    private let lock = NSLock()
    private var flow: String
    private var current: LinkConnection
    private var next: LinkConnection?

    init(flow: String, link: LinkConnection) { self.flow = flow; current = link }

    /// The connection in use.
    var link: LinkConnection {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var flowID: String {
        get { lock.withLock { flow } }
        set { lock.withLock { flow = newValue } }
    }

    /// The connection to carry on with once the one in use ends.
    func replace(with connection: LinkConnection) { lock.withLock { next = connection } }
    func takeReplacement() -> LinkConnection? {
        lock.withLock {
            defer { next = nil }
            return next
        }
    }
}

@Sendable func hello(as id: String) -> DeviceMessage { .hello(RemoteHello(version: Remote.version, deviceID: id, deviceName: "Test device")) }

let key = grant.key
var connection = LinkConnection(to: local(port), key: key)
let shared = Shared(flow: flowID, link: connection)
do {
    try await connection.start(timeout: 5)
    try await connection.send(hello(as: deviceID))
} catch {
    say(["type": "connect-failed", "error": "\(error)"])
    exit(0)
}

Task {
    try? await Task.sleep(for: .seconds(seconds))
    say(["type": "time-up"])
    exit(0)
}

/// A second connection with the device's own key. It reports the first thing it is told, or that it was closed.
@Sendable func second(_ name: String, port: UInt16, key: Data, saying first: DeviceMessage?) async {
    let extra = LinkConnection(to: local(port), key: key)
    do {
        try await extra.start(timeout: 5)
        if let first { try await extra.send(first) }
        say(["type": "\(name)-open"])
    } catch {
        say(["type": "\(name)-failed", "error": "\(error)"])
        return
    }
    do {
        if case .refused(let reason) = try await extra.receive(HostMessage.self) {
            say(["type": "\(name)-refused", "reason": reason])
        } else {
            say(["type": "\(name)-let-in"])
        }
    } catch {
        say(["type": "\(name)-ended"])
    }
}

/// The command a line of JSON on standard input describes, or nil if it describes none.
@Sendable func command(from fields: [String: Any]) -> RemoteCommand? {
    func text(_ name: String) -> String { fields[name] as? String ?? "" }
    func number(_ name: String) -> Double { fields[name] as? Double ?? 0 }
    func flag(_ name: String) -> Bool { fields[name] as? Bool ?? false }
    func list(_ name: String) -> [String] { fields[name] as? [String] ?? [] }
    let flow = text("flow")
    switch fields["do"] as? String {
    case "openOnMac": return .openOnMac(flowID: flow)
    case "run": return .run(flowID: flow, command: fields["text"] as? String)
    case "runFrom": return .runFrom(flowID: flow, cardID: text("card"), text: text("text"))
    case "stop": return .stop(flowID: flow)
    case "approve": return .approve(flowID: flow, holdID: text("hold"), text: text("text"))
    case "reject": return .reject(flowID: flow, holdID: text("hold"), note: text("text"))
    case "allowScript": return .allowScript(flowID: flow, holdID: text("hold"))
    case "refuseScript": return .refuseScript(flowID: flow, holdID: text("hold"))
    case "startSession": return .startSession(flowID: flow, cardID: text("card"))
    case "prompt": return .prompt(flowID: flow, key: text("key"), text: text("text"))
    case "keys":
        let hex = Array(text("hex"))
        let bytes = stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
        return .keys(flowID: flow, key: text("key"), data: Data(bytes))
    case "addCard":
        guard let kind = CardKind(rawValue: text("kind")) else { return nil }
        return .addCard(flowID: flow, kind: kind, x: number("x"), y: number("y"))
    case "moveCards":
        let moves = (fields["moves"] as? [String: [Double]] ?? [:]).filter { $0.value.count == 2 }.mapValues { RemotePoint(x: $0[0], y: $0[1]) }
        return .moveCards(flowID: flow, moves: moves, final: flag("final"))
    case "resizeCard":
        guard let frame = fields["frame"] as? [Double], frame.count == 4 else { return nil }
        return .resizeCard(flowID: flow, cardID: text("card"), frame: RemoteFrame(x: frame[0], y: frame[1], width: frame[2], height: frame[3]),
                           final: flag("final"))
    case "deleteItems": return .deleteItems(flowID: flow, cardIDs: list("cards"), linkIDs: list("links"))
    case "addLink": return .addLink(flowID: flow, from: text("from"), port: text("port"), to: text("to"))
    case "setLinkLimit": return .setLinkLimit(flowID: flow, linkID: text("link"), maxPasses: Int(number("passes")))
    case "duplicate": return .duplicate(flowID: flow, cardIDs: list("cards"))
    case "tidy": return .tidy(flowID: flow)
    case "group": return .group(flowID: flow, cardIDs: list("cards"), name: text("name"))
    case "ungroup": return .ungroup(flowID: flow, groupID: text("group"))
    case "renameGroup": return .renameGroup(flowID: flow, groupID: text("group"), name: text("name"))
    case "foldGroup": return .foldGroup(flowID: flow, groupID: text("group"), folded: flag("folded"))
    case "patchCard":
        guard let settings = fields["patch"], let data = try? JSONSerialization.data(withJSONObject: settings),
              let patch = try? Remote.decode(RemoteCardPatch.self, from: data) else { return nil }
        return .patchCard(flowID: flow, cardID: text("card"), patch: patch)
    case "setFlowOption":
        if let on = fields["notify"] as? Bool { return .setFlowOption(flowID: flow, option: .notifyOrchestrator(on: on)) }
        return .setFlowOption(flowID: flow, option: .subflowLimit(levels: Int(number("limit"))))
    case "newFlow": return .newFlow(projectID: text("project"), name: text("name"))
    case "renameFlow": return .renameFlow(flowID: flow, name: text("name"))
    case "deleteFlow": return .deleteFlow(flowID: flow)
    case "undo": return .undo(flowID: flow)
    case "redo": return .redo(flowID: flow)
    default: return nil
    }
}

// What standard input asks to be sent leaves through here, one message at a time, so the Mac gets it in the
// order it was asked for: the steps of a drag before its last, and a drag before the flow is left.
let (outgoing, outbox) = AsyncStream.makeStream(of: (id: Int?, frame: Data).self)
Task {
    for await next in outgoing {
        do { try await shared.link.send(next.frame) } catch {
            if let id = next.id { say(["type": "command-failed", "id": id, "error": "\(error)"]) }
        }
    }
}

Thread.detachNewThread { [deviceID] in
    while let line = readLine() {
        if line.hasPrefix("{") {
            if let raw = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["raw"],
               let frame = try? JSONSerialization.data(withJSONObject: raw) {
                // Sent as written, with whatever a device's own app would never put in it.
                outbox.yield((nil, frame))
                continue
            }
            guard let fields = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let id = fields["id"] as? Int, let command = command(from: fields),
                  let frame = try? Remote.encode(DeviceMessage.command(id: id, command: command)) else {
                say(["type": "unknown", "line": String(line.prefix(200))])
                continue
            }
            outbox.yield((id, frame))
            continue
        }
        let words = line.split(separator: " ").map(String.init)
        switch words.first {
        case "open" where words.count == 2:
            shared.flowID = words[1]
            if let frame = try? Remote.encode(DeviceMessage.open(flowID: words[1])) { outbox.yield((nil, frame)) }
        case "reconnect":
            Task {
                let next = LinkConnection(to: local(port), key: key)
                do {
                    try await next.start(timeout: 5)
                    shared.replace(with: next)
                    try await next.send(hello(as: deviceID))
                } catch {
                    say(["type": "reconnect-failed", "error": "\(error)"])
                }
            }
        case "silent":
            Task { await second("silent", port: port, key: key, saying: nil) }
        case "stranger":
            Task { await second("stranger", port: port, key: key, saying: hello(as: UUID().uuidString)) }
        default:
            say(["type": "unknown", "line": line])
        }
    }
}

while true {
    let message: HostMessage
    do { message = try await connection.receive(HostMessage.self) } catch {
        // The Mac closes the old connection when the device connects again, and the new one takes over here.
        if let next = shared.takeReplacement() {
            connection = next
            shared.link = next
            say(["type": "reconnected"])
            continue
        }
        say(["type": "ended"])
        exit(0)
    }
    switch message {
    case .welcome(let welcome):
        say(["type": "welcome", "version": welcome.version, "canControl": welcome.canControl])
    case .refused(let reason):
        say(["type": "refused", "reason": reason])
    case .library(let library):
        say(["type": "library", "flows": library.projects.flatMap(\.flows).map(\.name), "projects": library.projects.map(\.id),
             "flowIDs": Dictionary(library.projects.flatMap(\.flows).map { ($0.name, $0.id) }) { first, _ in first },
             "roles": library.roles.map(\.name)])
        try? await connection.send(DeviceMessage.open(flowID: shared.flowID))
    case .opened(let snapshot):
        say(["type": "opened", "name": snapshot.flow.name, "cards": snapshot.flow.cards.count,
             "cardIDs": Dictionary(snapshot.flow.cards.map { ($0.name, $0.id) }) { first, _ in first },
             "undo": snapshot.edit.undo ?? NSNull(), "redo": snapshot.edit.redo ?? NSNull(), "armed": snapshot.edit.armed,
             "sessions": snapshot.run.sessions.mapValues(\.rawValue)])
    case .flow(_, let revision, let flow):
        say(["type": "flow", "revision": revision, "efforts": flow.cards.map { $0.effort ?? "" }, "cards": flow.cards.count,
             "links": flow.links.count])
    case .edit(let id, let state):
        say(["type": "edit", "flow": id, "undo": state.undo ?? NSNull(), "redo": state.redo ?? NSNull(), "armed": state.armed,
             "nextFires": state.nextFires.count])
    case .run(let id, let state):
        say(["type": "run", "flow": id, "isRunning": state.isRunning, "sessions": state.sessions.mapValues(\.rawValue),
             "holds": state.holds.map { ["id": $0.id, "card": $0.cardID, "kind": $0.kind.rawValue, "needsAllow": $0.needsAllow] as [String: Any] }])
    case .log(_, let lines, let reset):
        say(["type": "log", "lines": lines.count, "reset": reset])
    case .messages(_, let link, let all):
        say(["type": "messages", "link": link, "count": all.count])
    case .history(_, let runs):
        say(["type": "history", "runs": runs.count])
    case .terminal(_, let key, let chunk):
        say(["type": "terminal", "key": key, "reset": chunk.reset, "bytes": chunk.data.count, "cols": chunk.cols, "rows": chunk.rows])
    case .answer(let id, let refusal):
        say(["type": "answer", "id": id, "refusal": refusal ?? NSNull()])
    case .control(let canControl):
        say(["type": "control", "canControl": canControl])
    }
}
