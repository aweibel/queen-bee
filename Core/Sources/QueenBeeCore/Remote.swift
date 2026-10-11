import Foundation

/// What the Mac app and a paired device say to each other. Each message is one frame of JSON.
public enum Remote {
    /// Both sides must be on the same version, or the device is told to update.
    public static let version = 2
    /// The Bonjour type of a paired device's listener, and of the listener that exists only while pairing.
    public static let service = "_queenbee._tcp"
    public static let pairingService = "_queenbee-pair._tcp"

    /// What the Mac says to a device it no longer knows. The device goes by these exact words to tell "pair
    /// again" from "update", so the Mac must send them as they are.
    public static let unpairedRefusal = "This device is no longer paired with this Mac. Pair it again from Settings on the Mac."

    /// Whether a listener's Bonjour record says it is the one this Mac keeps for this device. The Mac has one
    /// listener for each paired device, and other Macs nearby have their own.
    public static func isListener(_ record: [String: String], forDevice deviceID: String, ofMac macID: String) -> Bool {
        guard let device = record["device"], let mac = record["mac"] else { return false }
        // Ids are kept in lower case, and either side may hold its copy in capitals.
        return device.lowercased() == deviceID.lowercased() && mac.lowercased() == macID.lowercased()
    }

    /// The longest message a device may send for a session, or give a run or an approval, in characters.
    public static let promptLimit = 16_000
    /// The most key presses a device may send at once, in bytes.
    public static let keysLimit = 4_096
    /// The key of a flow's orchestrator among its sessions. Every other session goes by its card's id.
    public static let orchestratorKey = "orchestrator"

    /// What the Mac answers a command from a device that may only watch.
    public static let watchOnlyRefusal = "This device can only watch. To let it control this Mac, turn on “Can control” for it in Settings on your Mac."

    /// A name a device gave itself, made safe to put in a line of the Mac's log: on one line, with nothing
    /// in it that a terminal or a text view would act on.
    public static func oneLine(_ name: String) -> String {
        let kept = name.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let words = String(kept).split(separator: " ", omittingEmptySubsequences: true)
        return words.isEmpty ? "a device" : words.joined(separator: " ")
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

/// The first thing a device sends on a new connection.
public struct RemoteHello: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String

    public init(version: Int, deviceID: String, deviceName: String) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName
    }
}

public struct RemoteWelcome: Codable, Equatable, Sendable {
    public var version: Int
    public var macName: String
    /// False means the device may watch and nothing else.
    public var canControl: Bool

    public init(version: Int, macName: String, canControl: Bool) {
        self.version = version; self.macName = macName; self.canControl = canControl
    }
}

public struct RemoteFlowSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isSubflow: Bool
    public var activity: FlowActivity

    public init(id: String, name: String, isSubflow: Bool, activity: FlowActivity) {
        self.id = id; self.name = name; self.isSubflow = isSubflow; self.activity = activity
    }
}

public struct RemoteProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var flows: [RemoteFlowSummary]

    public init(id: String, name: String, flows: [RemoteFlowSummary]) { self.id = id; self.name = name; self.flows = flows }
}

/// Every project in the Mac's sidebar and the flows in each.
public struct RemoteLibrary: Codable, Equatable, Sendable {
    public var projects: [RemoteProject]

    public init(projects: [RemoteProject]) { self.projects = projects }
}

/// The parts of a flow's state that change while it runs. Sent whole whenever any of it changes.
public struct RemoteRunState: Codable, Equatable, Sendable {
    public var isRunning: Bool
    public var marks: [String: RunMark]
    public var linkPasses: [String: Int]
    public var liveLinkIDs: [String]
    public var handOffs: Int
    public var holds: [PendingHold]
    public var results: [String: String]
    public var usage: [String: Usage]
    /// Each session's state, by card id, with the orchestrator under "orchestrator".
    public var sessions: [String: SessionState]
    public var awaitingAnswer: [String]
    public var banner: String?

    public init(isRunning: Bool, marks: [String: RunMark], linkPasses: [String: Int], liveLinkIDs: [String], handOffs: Int,
                holds: [PendingHold], results: [String: String], usage: [String: Usage], sessions: [String: SessionState],
                awaitingAnswer: [String], banner: String?) {
        self.isRunning = isRunning; self.marks = marks; self.linkPasses = linkPasses; self.liveLinkIDs = liveLinkIDs
        self.handOffs = handOffs; self.holds = holds; self.results = results; self.usage = usage; self.sessions = sessions
        self.awaitingAnswer = awaitingAnswer; self.banner = banner
    }
}

/// Everything a device needs to draw one flow.
public struct RemoteFlowSnapshot: Codable, Equatable, Sendable {
    public var flow: Flow
    public var run: RemoteRunState
    public var log: [LogLine]
    /// What each link carried in the run on show, by link id.
    public var messages: [String: [LinkMessage]]
    /// Earlier runs, oldest first.
    public var runs: [RunRecord]

    public init(flow: Flow, run: RemoteRunState, log: [LogLine], messages: [String: [LinkMessage]], runs: [RunRecord]) {
        self.flow = flow; self.run = run; self.log = log; self.messages = messages; self.runs = runs
    }
}

/// Bytes for a remote terminal. With `reset` set they take a blank terminal of that size to the screen;
/// without it they follow on from the last chunk.
public struct TerminalChunk: Codable, Equatable, Sendable {
    public var reset: Bool
    public var cols: Int
    public var rows: Int
    public var data: Data

    public init(reset: Bool, cols: Int, rows: Int, data: Data) { self.reset = reset; self.cols = cols; self.rows = rows; self.data = data }
}

/// Mac to device.
public enum HostMessage: Codable, Equatable, Sendable {
    case welcome(RemoteWelcome)
    /// The connection is about to close. The text is shown to the person as it is.
    case refused(String)
    case library(RemoteLibrary)
    /// The whole of the flow the device just opened.
    case opened(RemoteFlowSnapshot)
    case flow(id: String, revision: Int, flow: Flow)
    case run(id: String, state: RemoteRunState)
    /// Lines to add to the log, or with `reset` the whole log.
    case log(id: String, lines: [LogLine], reset: Bool)
    /// Everything one link has carried.
    case messages(id: String, link: String, all: [LinkMessage])
    case history(id: String, runs: [RunRecord])
    case terminal(id: String, key: String, chunk: TerminalChunk)
    /// What became of the command the device sent with that id. No refusal means it was done.
    /// A refusal is in the Mac's words, and is shown to the person as it is.
    case answer(id: Int, refusal: String?)
    /// "Can control" was turned on or off for this device on the Mac, while it was connected.
    case control(canControl: Bool)
}

/// Device to Mac.
public enum DeviceMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    /// The flow the device is looking at, or nil for none.
    case open(flowID: String?)
    /// Something for the Mac to do. The device picks the id, and the Mac's answer carries it back.
    case command(id: Int, command: RemoteCommand)
}

/// What a device that may control the Mac can ask of it. Each is one thing the Mac's own buttons or
/// keyboard already do, and the Mac checks it the same way. State never comes back in the answer: what a
/// command changed arrives with the updates the device already gets.
public enum RemoteCommand: Codable, Equatable, Sendable {
    /// What choosing the flow on the Mac does to its sessions: starts the ones that are missing.
    /// The Mac's own window goes on showing whatever it showed.
    case openOnMac(flowID: String)
    /// Run, with a command to use in place of the Start card's own, or nil for the card's.
    case run(flowID: String, command: String?)
    /// "Run from here": `text` arrives at the card as if a link had brought it.
    case runFrom(flowID: String, cardID: String, text: String)
    case stop(flowID: String)
    /// Approve a held message, as it was or edited.
    case approve(flowID: String, holdID: String, text: String)
    /// Turn a held message down, with a note saying why, which may be empty.
    case reject(flowID: String, holdID: String, note: String)
    /// Let a script's command run. The Mac remembers it for that card, as it does when allowed there.
    case allowScript(flowID: String, holdID: String)
    case refuseScript(flowID: String, holdID: String)
    /// An agent card's "Start agent" or "Restart agent".
    case startSession(flowID: String, cardID: String)
    /// A message for a session, entered the way the Mac enters one: held until the session is idle, then
    /// pasted whole and followed by Enter. `key` is a card's id, or `Remote.orchestratorKey`.
    case prompt(flowID: String, key: String, text: String)
    /// Key presses for a session's terminal, as the bytes the keys make.
    case keys(flowID: String, key: String, data: Data)

    public var flowID: String {
        switch self {
        case .openOnMac(let id), .run(let id, _), .runFrom(let id, _, _), .stop(let id), .approve(let id, _, _),
             .reject(let id, _, _), .allowScript(let id, _), .refuseScript(let id, _), .startSession(let id, _),
             .prompt(let id, _, _), .keys(let id, _, _): id
        }
    }

    /// Why this command can't be obeyed whatever state the Mac is in: it carries too much, or nothing.
    /// Nil when it is fine. A device can ask before sending. The Mac asks every time, whatever was sent.
    public var problem: String? {
        switch self {
        case .prompt(_, _, let text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "There is nothing to send." }
            return Self.tooLong(text)
        case .keys(_, _, let data):
            if data.isEmpty { return "There is nothing to send." }
            return data.count > Remote.keysLimit ? "That is too much to type at once." : nil
        case .run(_, let command): return command.flatMap(Self.tooLong)
        case .runFrom(_, _, let text): return Self.tooLong(text)
        case .approve(_, _, let text): return Self.tooLong(text)
        case .reject(_, _, let note): return Self.tooLong(note)
        case .openOnMac, .stop, .allowScript, .refuseScript, .startSession: return nil
        }
    }

    private static func tooLong(_ text: String) -> String? {
        text.count > Remote.promptLimit ? "That message is too long. The most a device can send is \(Remote.promptLimit) characters." : nil
    }
}

/// What a device sends to the pairing listener.
public struct PairRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String

    public init(version: Int, deviceID: String, deviceName: String) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName
    }
}

public struct PairGrant: Codable, Equatable, Sendable {
    /// The device's own key, for every later connection.
    public var key: Data
    /// The device's id as the Mac keeps it. The device uses this from now on, whatever case it sent.
    public var deviceID: String
    public var macID: String
    public var macName: String

    public init(key: Data, deviceID: String, macID: String, macName: String) {
        self.key = key; self.deviceID = deviceID; self.macID = macID; self.macName = macName
    }
}

public enum PairReply: Codable, Equatable, Sendable {
    case granted(PairGrant)
    case refused(String)
}
