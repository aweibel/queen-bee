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

Thread.detachNewThread { [deviceID] in
    while let line = readLine() {
        let words = line.split(separator: " ").map(String.init)
        switch words.first {
        case "open" where words.count == 2:
            shared.flowID = words[1]
            Task { try? await shared.link.send(DeviceMessage.open(flowID: words[1])) }
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
        say(["type": "library", "flows": library.projects.flatMap(\.flows).map(\.name)])
        try? await connection.send(DeviceMessage.open(flowID: shared.flowID))
    case .opened(let snapshot):
        say(["type": "opened", "name": snapshot.flow.name, "cards": snapshot.flow.cards.count,
             "sessions": snapshot.run.sessions.mapValues(\.rawValue)])
    case .flow(_, let revision, let flow):
        say(["type": "flow", "revision": revision, "efforts": flow.cards.map { $0.effort ?? "" }])
    case .run(let id, let state):
        say(["type": "run", "flow": id, "isRunning": state.isRunning, "sessions": state.sessions.mapValues(\.rawValue)])
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
