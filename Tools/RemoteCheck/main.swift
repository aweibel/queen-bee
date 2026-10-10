// A stand-in for a paired device, for scripts/e2e.py. It pairs with a test copy of the app over this
// machine's loopback, connects, opens a flow, and prints one line of JSON for everything it is sent.
//
//   qb-remote-check --code <pairing code> --pair-port <n> --flow <id> [--seconds <n>]
//   qb-remote-check --port <n> --device <id> --wrong-key
//
// After pairing it prints the device id, then waits for the device's port on standard input.
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
let deviceID = UUID().uuidString.lowercased()

let grant: PairGrant
do {
    let pairing = LinkConnection(to: local(pairPort), key: code.secret)
    try await pairing.start(timeout: 5)
    try await pairing.send(PairRequest(version: Remote.version, deviceID: deviceID, deviceName: "Test device"))
    guard case .granted(let granted) = try await pairing.receive(PairReply.self) else {
        say(["type": "pair-refused"])
        exit(0)
    }
    grant = granted
    pairing.close()
} catch {
    say(["type": "pair-failed", "error": "\(error)"])
    exit(0)
}
say(["type": "paired", "device": deviceID, "mac": grant.macName.isEmpty ? "" : "named"])

guard let port = readLine().flatMap({ UInt16($0.trimmingCharacters(in: .whitespaces)) }), port != 0 else {
    say(["type": "no-port"])
    exit(2)
}
let connection = LinkConnection(to: local(port), key: grant.key)
do {
    try await connection.start(timeout: 5)
    try await connection.send(DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: deviceID, deviceName: "Test device")))
} catch {
    say(["type": "connect-failed", "error": "\(error)"])
    exit(0)
}

Task {
    try? await Task.sleep(for: .seconds(seconds))
    say(["type": "time-up"])
    exit(0)
}

while true {
    let message: HostMessage
    do { message = try await connection.receive(HostMessage.self) } catch {
        say(["type": "ended"])
        exit(0)
    }
    switch message {
    case .welcome(let welcome):
        say(["type": "welcome", "version": welcome.version, "canControl": welcome.canControl])
    case .refused(let reason):
        say(["type": "refused", "reason": reason])
    case .library(let library):
        say(["type": "library", "flows": library.projects.flatMap(\.flows).map(\.name)])
        try? await connection.send(DeviceMessage.open(flowID: flowID))
    case .opened(let snapshot):
        say(["type": "opened", "name": snapshot.flow.name, "cards": snapshot.flow.cards.count,
             "sessions": snapshot.run.sessions.mapValues(\.rawValue)])
    case .flow(_, let revision, let flow):
        say(["type": "flow", "revision": revision, "efforts": flow.cards.map { $0.effort ?? "" }])
    case .run(_, let state):
        say(["type": "run", "isRunning": state.isRunning, "sessions": state.sessions.mapValues(\.rawValue)])
    case .log(_, let lines, let reset):
        say(["type": "log", "lines": lines.count, "reset": reset])
    case .messages(_, let link, let all):
        say(["type": "messages", "link": link, "count": all.count])
    case .history(_, let runs):
        say(["type": "history", "runs": runs.count])
    case .terminal(_, let key, let chunk):
        say(["type": "terminal", "key": key, "reset": chunk.reset, "bytes": chunk.data.count, "cols": chunk.cols, "rows": chunk.rows])
    }
}
