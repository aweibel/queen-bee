import Foundation

/// What the Mac app and a paired device say to each other. Each message is one frame of JSON.
public enum Remote {
    /// Both sides must be on the same version, or the device is told to update.
    public static let version = 1
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
}

/// Device to Mac.
public enum DeviceMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    /// The flow the device is looking at, or nil for none.
    case open(flowID: String?)
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
