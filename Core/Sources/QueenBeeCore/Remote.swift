import CryptoKit
import Foundation

/// What the Mac app and a paired device say to each other. Each message is one frame of JSON.
public enum Remote {
    /// Both sides must be on the same version, or the device is told to update.
    public static let version = 5
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

    /// The longest name a device may give a card, a group or a flow, and the longest of a card's other
    /// one-line settings, in characters.
    public static let nameLimit = 200
    /// The longest instructions, command, template or other long text a device may give a card, in characters.
    public static let textLimit = 16_000
    /// How much of a role's instructions the flow list carries, in characters. A device needs no more: it
    /// shows the start of them, and tells a card that has drifted from its role by `RemoteRole.instructionsHash`.
    public static let roleInstructionsListed = 2_000
    /// The longest file path a device may give an End card or a schedule, in characters.
    public static let pathLimit = 1_000
    /// The most cards and links a flow may have and still be added to from a device. A flow that already has
    /// more, made on the Mac, can be changed from a device and not grown.
    public static let cardLimit = 200
    public static let linkLimit = 400
    /// The most branches a device may give a Switch card.
    public static let branchLimit = 50
    /// As far from the canvas's corner as a device may put a card, and as big as it may make one, in points.
    /// The Mac has no such limits of its own, and nobody building a flow by hand comes near these.
    public static let farthestPoint = 100_000.0
    public static let largestSide = 10_000.0

    /// The most the Mac takes from a device in one message, in bytes. A device only ever sends a few words, and a
    /// bigger message ends the connection, so a device checks every command against this before sending it.
    public static let largestFromDevice = 64 * 1024

    /// What the Mac answers a command for a flow whose id a flow of another open project has too, as when a
    /// project was copied. The Mac can't tell which of them the device means, so it changes neither.
    public static let sharedFlowIDRefusal = "Two projects on your Mac have a flow with this id. Open only one of them on your Mac."

    /// What the Mac answers a command from a device that may only watch.
    public static let watchOnlyRefusal = "This device can only watch. To let it control this Mac, turn on “Can control” for it in Settings on your Mac."

    /// What the Mac answers a device that tries to allow a Script card's command that a device wrote. The
    /// device shows the same words in place of its Allow button.
    public static let allowOnMacRefusal = "This command was changed from a device. Allow it on your Mac."

    /// A name a device gave itself, made safe to put in a line of the Mac's log: on one line, with nothing
    /// in it that a terminal or a text view would act on.
    public static func oneLine(_ name: String) -> String {
        let line = plainLine(name)
        return line.isEmpty ? "a device" : line
    }

    /// Text a device sent for a setting that is one line, such as a name: on one line, with nothing in it
    /// that a terminal or a text view would act on, and no space at either end. It can come out empty.
    public static func plainLine(_ text: String) -> String {
        let kept = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        return String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Text a device sent, made safe to enter into a terminal as one paste: nothing is left in it that a
    /// terminal acts on, such as the Esc that would end the paste and turn the rest into key presses. New
    /// lines and tabs are kept, and every other control character is dropped.
    public static func plainText(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        var lastWasReturn = false
        for scalar in text.unicodeScalars {
            defer { lastWasReturn = scalar == "\r" }
            switch scalar.value {
            case 0x0A: if !lastWasReturn { kept.append("\n") }
            // A return is a new line, however the device's keyboard wrote it.
            case 0x0D: kept.append("\n")
            case 0x09: kept.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F: break
            default: kept.append(scalar)
            }
        }
        return String(kept)
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
    /// The flow whose Flow card runs this one, when exactly one flow does: where the sidebar puts it.
    public var parentID: String?
    /// Pinned to the top of the Mac's sidebar.
    public var pinned: Bool
    /// What the flow's cards are called, for finding a card from the list of flows. The first
    /// `Remote.cardNamesLimit` cards, each cut to `Remote.cardNameLength` characters.
    public var cardNames: [String]
    /// What the flow's own sessions have used, and that with every sub-flow below it, as the Mac's cost
    /// breakdown counts them. Nil when nothing has been used.
    public var usage: Usage?
    public var usageWithSubflows: Usage?
    /// True when a flow of another project open on the Mac has the same id. The Mac refuses to open or change
    /// either from a device, and the device says why: see `Remote.sharedFlowIDRefusal`. Nil otherwise.
    public var sharedID: Bool?

    public init(id: String, name: String, isSubflow: Bool, activity: FlowActivity, parentID: String? = nil, pinned: Bool = false,
                cardNames: [String] = [], usage: Usage? = nil, usageWithSubflows: Usage? = nil, sharedID: Bool? = nil) {
        self.id = id; self.name = name; self.isSubflow = isSubflow; self.activity = activity; self.parentID = parentID
        self.pinned = pinned; self.cardNames = cardNames; self.usage = usage; self.usageWithSubflows = usageWithSubflows
        self.sharedID = sharedID
    }
}

/// The browser that a project's agent cards share, as the Mac's card and flow settings show it.
public struct RemoteBrowserState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Nothing has asked for it yet, or it was put away.
        case idle
        case starting, running
        /// There is no Chromium-based browser on the Mac. The Mac offers to download one.
        case missing
        case downloading
        /// It ran and has ended. The Mac offers Restart.
        case stopped
        /// The Mac offers Try again, with `problem` saying why.
        case failed
    }

    public var status: Status
    /// How far a download has got, from 0 to 1, in twentieths so that the list is not sent for every megabyte.
    public var progress: Double?
    /// Why it failed, in the Mac's words.
    public var problem: String?
    /// The browser on the Mac that it would use, such as "Google Chrome". Nil when there is none.
    public var browser: String?
    /// Whether it has kept sign-ins or pages, which "Clear browser data" would forget.
    public var hasData: Bool

    public init(status: Status = .idle, progress: Double? = nil, problem: String? = nil, browser: String? = nil, hasData: Bool = false) {
        self.status = status; self.progress = progress; self.problem = problem; self.browser = browser; self.hasData = hasData
    }

    /// A download's progress as it is sent: between 0 and 1, in steps of a twentieth.
    public static func step(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return (min(max(fraction, 0), 1) * 20).rounded(.down) / 20
    }
}

public struct RemoteProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var flows: [RemoteFlowSummary]
    public var browser: RemoteBrowserState

    public init(id: String, name: String, flows: [RemoteFlowSummary], browser: RemoteBrowserState = RemoteBrowserState()) {
        self.id = id; self.name = name; self.flows = flows; self.browser = browser
    }
}

/// A saved role an agent card can be given, and what it holds, so a device can say when a card has drifted
/// from it. A role holds no folder.
public struct RemoteRole: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// The role's instructions, or their first `Remote.roleInstructionsListed` characters when they are longer.
    /// `instructionsHash` is of the whole, so a card can still be told apart from the role.
    public var instructions: String
    /// "" for the person's default, as with effort and permissions.
    public var model: String
    public var effort: String
    public var permissionMode: String
    /// A fingerprint of the role's whole instructions: see `RemoteRole.fingerprint`. Nil from a Mac that sends
    /// them whole.
    public var instructionsHash: String?
    /// The device that saved or last changed the role, and when, until the person at the Mac has looked at it.
    /// The Mac marks such a role "Changed from" that device, and asks before using it.
    public var changedFrom: String?
    public var changedAt: Date?

    public init(id: String, name: String, instructions: String = "", model: String = "", effort: String = "", permissionMode: String = "",
                instructionsHash: String? = nil, changedFrom: String? = nil, changedAt: Date? = nil) {
        self.id = id; self.name = name; self.instructions = instructions; self.model = model; self.effort = effort
        self.permissionMode = permissionMode; self.instructionsHash = instructionsHash; self.changedFrom = changedFrom; self.changedAt = changedAt
    }

    /// A role as the flow list carries it: long instructions cut short, with the fingerprint of the whole.
    public static func listed(id: String, name: String, instructions: String, model: String, effort: String, permissionMode: String,
                              changedFrom: String? = nil, changedAt: Date? = nil) -> RemoteRole {
        RemoteRole(id: id, name: name, instructions: String(instructions.prefix(Remote.roleInstructionsListed)), model: model, effort: effort,
                   permissionMode: permissionMode, instructionsHash: fingerprint(instructions), changedFrom: changedFrom, changedAt: changedAt)
    }

    /// "Changed from iPad 14:02", as the Mac marks a role a device saved or changed. Nil for any other role.
    public var changedLine: String? {
        guard let changedFrom else { return nil }
        let when = changedAt.map { " " + $0.formatted(date: Calendar.current.isDateInToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? ""
        return "Changed from \(changedFrom)\(when)"
    }

    /// Whether the instructions sent are all of them.
    public var hasAllInstructions: Bool { instructionsHash == nil || instructionsHash == Self.fingerprint(instructions) }

    /// Whether a card still has exactly what the role holds. When it hasn't, the Mac says "Changed since the role was saved."
    public func matches(_ card: Card) -> Bool {
        let theirs = card.instructions ?? ""
        let same = instructionsHash.map { $0 == Self.fingerprint(theirs) } ?? (instructions == theirs)
        return same && model == (card.model ?? "") && effort == (card.effort ?? "") && permissionMode == (card.permissionMode ?? "")
    }

    /// The SHA-256 of a text's UTF-8, in hexadecimal.
    public static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every project in the Mac's sidebar and the flows in each, and the roles saved on the Mac.
public struct RemoteLibrary: Codable, Equatable, Sendable {
    public var projects: [RemoteProject]
    public var roles: [RemoteRole]

    public init(projects: [RemoteProject], roles: [RemoteRole] = []) { self.projects = projects; self.roles = roles }
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
    /// The settings changed on each agent card since its session started, which the session doesn't have yet,
    /// named as the Mac's "Not in use yet" line names them: "name", "instructions", "model", "effort",
    /// "permissions", "folder", "browser". By card id, with no entry for a card that is up to date.
    public var awaitingRestart: [String: [String]]
    /// The orchestrator is running with details that are no longer the flow's, so the Mac offers "Restart to apply".
    public var orchestratorNeedsRestart: Bool
    /// What each session has used in the run on show, by card id: while a run goes, what it has used so far.
    public var runUsage: [String: Usage]

    public init(isRunning: Bool, marks: [String: RunMark], linkPasses: [String: Int], liveLinkIDs: [String], handOffs: Int,
                holds: [PendingHold], results: [String: String], usage: [String: Usage], sessions: [String: SessionState],
                awaitingAnswer: [String], banner: String?, awaitingRestart: [String: [String]] = [:],
                orchestratorNeedsRestart: Bool = false, runUsage: [String: Usage] = [:]) {
        self.isRunning = isRunning; self.marks = marks; self.linkPasses = linkPasses; self.liveLinkIDs = liveLinkIDs
        self.handOffs = handOffs; self.holds = holds; self.results = results; self.usage = usage; self.sessions = sessions
        self.awaitingAnswer = awaitingAnswer; self.banner = banner; self.awaitingRestart = awaitingRestart
        self.orchestratorNeedsRestart = orchestratorNeedsRestart; self.runUsage = runUsage
    }
}

/// What a device that edits a flow shows besides the flow itself. It is small and sent whole whenever any of
/// it changes, which is after almost every edit, so none of it rides on the flow or the run's state.
public struct RemoteEditState: Codable, Equatable, Sendable {
    /// What the Mac's Edit menu calls its Undo just now, such as "Undo Move". Nil when there is nothing to undo.
    public var undo: String?
    /// The same for Redo.
    public var redo: String?
    /// The Start cards whose schedule is on, by card id. A device turns one on or off with `armSchedule`.
    public var armed: [String]
    /// When the clock next starts a run from each of those, by card id. A schedule that waits on a file has none.
    public var nextFires: [String: Date]

    public init(undo: String? = nil, redo: String? = nil, armed: [String] = [], nextFires: [String: Date] = [:]) {
        self.undo = undo; self.redo = redo; self.armed = armed; self.nextFires = nextFires
    }
}

/// Everything a device needs to draw one flow.
public struct RemoteFlowSnapshot: Codable, Equatable, Sendable {
    public var flow: Flow
    public var run: RemoteRunState
    public var edit: RemoteEditState
    public var log: [LogLine]
    /// What each link carried in the run on show, by link id.
    public var messages: [String: [LinkMessage]]
    /// Earlier runs, oldest first.
    public var runs: [RunRecord]

    public init(flow: Flow, run: RemoteRunState, edit: RemoteEditState = RemoteEditState(), log: [LogLine],
                messages: [String: [LinkMessage]], runs: [RunRecord]) {
        self.flow = flow; self.run = run; self.edit = edit; self.log = log; self.messages = messages; self.runs = runs
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
    /// Undo, redo and the schedules of the open flow, whenever any of them changes.
    case edit(id: String, state: RemoteEditState)
    /// Lines to add to the log, or with `reset` the whole log.
    case log(id: String, lines: [LogLine], reset: Bool)
    /// Everything one link has carried.
    case messages(id: String, link: String, all: [LinkMessage])
    case history(id: String, runs: [RunRecord])
    case terminal(id: String, key: String, chunk: TerminalChunk)
    /// What became of the command the device sent with that id. No refusal means it was done.
    /// A refusal is in the Mac's words, and is shown to the person as it is. A command that is a step of a
    /// drag gets no answer at all: see `RemoteCommand.isAnswered`.
    case answer(id: Int, refusal: String?)
    /// "Can control" was turned on or off for this device on the Mac, while it was connected.
    case control(canControl: Bool)
    /// What one agent card's browser half shows besides its picture: see `RemoteBrowserPage`. Sent for the cards
    /// the device is watching, when it starts watching one and whenever any of it changes.
    case browserPage(id: String, card: String, page: RemoteBrowserPage)
    /// The newest picture of a watched card's page. At most `Remote.browserFramesASecond` a second, each at most
    /// `Remote.browserFrameLimit` bytes, and none queued behind another: one the device can't take yet is dropped
    /// for the one after it.
    case browserFrame(id: String, card: String, frame: RemoteBrowserFrame)
    /// The text that was selected on a card's page, for the device's Copy. Sent just before Copy's answer.
    case browserCopied(id: String, card: String, text: String)
}

/// Device to Mac.
public enum DeviceMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    /// The flow the device is looking at, or nil for none.
    case open(flowID: String?)
    /// Something for the Mac to do. The device picks the id, and the Mac's answer carries it back.
    case command(id: Int, command: RemoteCommand)
    /// The agent cards of the open flow whose browser is on the device's screen now, which are the only ones
    /// it is sent pictures of. Sent whenever that changes; an empty list stops them all. Watching needs no
    /// "Can control", as watching a terminal needs none.
    case watchBrowsers(flowID: String, cardIDs: [String])
}

/// A place on the canvas, in the canvas's own points.
public struct RemotePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    /// Somewhere a card could be. The Mac moves a card that is too far up or left back to its own edge.
    var isOnCanvas: Bool { x.isFinite && y.isFinite && abs(x) <= Remote.farthestPoint && abs(y) <= Remote.farthestPoint }
}

/// Where a card is and how big, in the canvas's own points.
public struct RemoteFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }

    /// A size a card could be. The Mac makes a card that is too small as big as its kind has to be.
    var isCardSized: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0 && width <= Remote.largestSide && height <= Remote.largestSide
    }
}

/// Changes to a card's settings from a device. A nil field is left as it is, and a setting that belongs to
/// another kind of card is left alone, as on the Mac.
///
/// It has every setting the Mac's own panel has but the folder: an agent's folder is picked with the Mac's
/// folder panel, and a path typed on a device could point an agent anywhere. A schedule set here arrives
/// switched off, as one that came in a flow's file does. Turning it on is a command of its own, `armSchedule`,
/// so that it is always a deliberate act and never the side effect of an edit.
public struct RemoteCardPatch: Codable, Equatable, Sendable {
    public var name: String?
    // Agent
    public var instructions: String?
    /// "" for the person's default, as with effort and permissions.
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    /// The id of a saved role, which gives the card what the role holds, or "" to cut the card loose from its role.
    public var role: String?
    /// The Browser switch: a web browser beside the agent's terminal.
    public var browser: Bool?
    // Start, Script
    public var command: String?
    // Start
    /// What starts runs besides the Run button. It arrives switched off: see `RemoteCommand.armSchedule`.
    public var trigger: Trigger?
    /// True takes the schedule away, so only the Run button starts a run.
    public var removesTrigger: Bool?
    // If, Loop
    public var check: CheckKind?
    public var value: String?
    public var maxTries: Int?
    // Switch
    public var branches: [String]?
    // Prompt
    public var template: String?
    // End
    public var saveTo: String?
    // Note, Approval
    public var text: String?
    // Flow
    /// The id of a flow in the same project for a Flow card to run, or "" for none.
    public var flowRef: String?

    public init() {}

    public var isEmpty: Bool { self == RemoteCardPatch() }

    /// The settings as the Mac's own kind of patch. The role and the schedule are not in it: the Mac
    /// sets those apart. Nothing here can name a folder, a position or a size.
    public var cardPatch: CardPatch {
        var patch = CardPatch()
        patch.name = name
        patch.instructions = instructions
        patch.model = model
        patch.effort = effort
        patch.permissionMode = permissionMode
        patch.browser = browser
        patch.command = command
        patch.check = check
        patch.value = value
        patch.maxTries = maxTries
        patch.branches = branches
        patch.template = template
        patch.saveTo = saveTo
        patch.text = text
        patch.flowRef = flowRef
        return patch
    }

    /// The same patch with its text made safe to show and to enter into a terminal, and its schedule
    /// brought within what the Mac's own panel offers.
    public var cleaned: RemoteCardPatch {
        var patch = self
        patch.name = name.map(Remote.plainLine)
        patch.instructions = instructions.map(Remote.plainText)
        patch.model = model.map(Remote.plainLine)
        patch.effort = effort.map(Remote.plainLine)
        patch.permissionMode = permissionMode.map(Remote.plainLine)
        patch.role = role.map(Remote.plainLine)
        patch.command = command.map(Remote.plainText)
        patch.value = value.map(Remote.plainText)
        patch.branches = branches.map { $0.map(Remote.plainLine) }
        patch.template = template.map(Remote.plainText)
        patch.saveTo = saveTo.map(Remote.plainLine)
        patch.text = text.map(Remote.plainText)
        patch.flowRef = flowRef.map(Remote.plainLine)
        if var trigger {
            trigger.minutes = min(max(trigger.minutes, 1), 7 * 24 * 60)
            trigger.hour = min(max(trigger.hour, 0), 23)
            trigger.minute = min(max(trigger.minute, 0), 59)
            trigger.weekdays = Array(Set(trigger.weekdays.filter { (1...7).contains($0) })).sorted()
            trigger.path = Remote.plainLine(trigger.path)
            patch.trigger = trigger
        }
        return patch
    }

    /// Why this patch can't be made whatever card it is for. Nil when it is fine.
    public var problem: String? {
        if isEmpty { return "There is nothing to change." }
        for short in [name, model, effort, permissionMode, role, flowRef] + (branches ?? []) {
            if let short, !Remote.fitsName(short) { return RemoteCommand.nameTooLong }
        }
        for long in [instructions, command, value, template, text] {
            if let long, !Remote.fitsText(long) { return RemoteCommand.textTooLong }
        }
        for path in [saveTo, trigger?.path] {
            if let path, !Remote.fitsPath(path) { return "That file path is too long. The most a device can send is \(Remote.pathLimit) characters." }
        }
        if let branches, branches.count > Remote.branchLimit { return "That is too many branches. The most a device can give a card is \(Remote.branchLimit)." }
        if let effort, !effort.isEmpty, !Card.effortLevels.contains(effort) {
            return "Unknown effort level \"\(effort)\". Use one of: \(Card.effortLevels.joined(separator: ", "))"
        }
        // The Mac refuses any mode that isn't one of these wherever it comes from. Said here too, so a
        // device can know before it asks.
        if let permissionMode, !permissionMode.isEmpty, !Card.permissionModes.contains(permissionMode) {
            return "Unknown permission mode \"\(permissionMode)\". Use one of: \(Card.permissionModes.joined(separator: ", "))"
        }
        if trigger != nil, removesTrigger == true { return "A schedule can't be set and taken away at once." }
        return nil
    }
}

/// One of the flow's own settings, as the Mac's flow settings offer them.
public enum RemoteFlowOption: Codable, Equatable, Sendable {
    /// How many levels of sub-flow may sit below the flow. Only the flow at the top has this.
    case subflowLimit(levels: Int)
    /// Whether the orchestrator is told when a run ends.
    case notifyOrchestrator(on: Bool)
}

/// The two drags a device sends step by step.
public enum RemoteDrag: Equatable, Sendable {
    case move
    case resize(cardID: String)
}

/// What a device that may control the Mac can ask of it. Each is one thing the Mac's own buttons, keyboard
/// or canvas already do, and the Mac checks it the same way. State never comes back in the answer: what a
/// command changed arrives with the updates the device already gets.
///
/// The ones that edit a flow are held to more than the Mac's own canvas is, because the Mac did not see the
/// person make them: see `isEdit`.
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
    /// An agent card's "Start agent", "Restart agent" or "Restart to apply". With `Remote.orchestratorKey` for
    /// the card, the orchestrator panel's Start, Restart or "Restart to apply".
    case startSession(flowID: String, cardID: String)
    /// A message for a session, entered the way the Mac enters one: held until the session is idle, then
    /// pasted whole and followed by Enter. `key` is a card's id, or `Remote.orchestratorKey`.
    case prompt(flowID: String, key: String, text: String)
    /// Key presses for a session's terminal, as the bytes the keys make.
    case keys(flowID: String, key: String, data: Data)

    // MARK: Editing the graph

    /// A new card of that kind, with the middle of its title bar at that point, as one dropped from the
    /// Mac's list of kinds.
    case addCard(flowID: String, kind: CardKind, x: Double, y: Double)
    /// Where each of these cards now is, by card id. See "Drags" below for `final`.
    case moveCards(flowID: String, moves: [String: RemotePoint], final: Bool)
    case resizeCard(flowID: String, cardID: String, frame: RemoteFrame, final: Bool)
    /// Deletes cards, with the links at either end of each, and links.
    case deleteItems(flowID: String, cardIDs: [String], linkIDs: [String])
    /// A link from one of a card's outputs to another card. `from` and `to` are card ids.
    case addLink(flowID: String, from: String, port: String, to: String)
    /// How many messages a link may carry in one run.
    case setLinkLimit(flowID: String, linkID: String, maxPasses: Int)
    /// Copies of these cards, a step down and right of them, with the links between them.
    case duplicate(flowID: String, cardIDs: [String])
    /// The Mac's Tidy Up.
    case tidy(flowID: String)

    // MARK: Groups

    /// Frames these cards together. With an empty name the Mac gives it one.
    case group(flowID: String, cardIDs: [String], name: String)
    case ungroup(flowID: String, groupID: String)
    case renameGroup(flowID: String, groupID: String, name: String)
    case foldGroup(flowID: String, groupID: String, folded: Bool)

    // MARK: Settings

    case patchCard(flowID: String, cardID: String, patch: RemoteCardPatch)
    case setFlowOption(flowID: String, option: RemoteFlowOption)

    // MARK: Flows

    /// A new flow in a project that is already in the Mac's sidebar. `projectID` is that project's id in the
    /// flow list. With an empty name the Mac gives it one. The new flow arrives in the flow list.
    case newFlow(projectID: String, name: String)
    case renameFlow(flowID: String, name: String)
    /// Deletes the flow and its file. This cannot be undone, so the device asks first, by the flow's name.
    case deleteFlow(flowID: String)

    // MARK: Undo

    /// The Mac's Undo and Redo for the flow. The stack is the Mac's own, shared with whoever is at the Mac.
    case undo(flowID: String)
    case redo(flowID: String)

    // MARK: Runs and sessions, stage 4

    /// A Start card's own Run, or "Run from This Start" in its menu: the flow with several Start cards runs from this one.
    case runFromStart(flowID: String, startCardID: String)
    /// The settings panel's Retry, on a card the last run stopped at: it is given the message it was given, again.
    /// See `RemoteFlowSnapshot.canRetry(_:)` for when the Mac offers it.
    case retry(flowID: String, cardID: String)
    /// The log's Clear: the log and the list of earlier runs are emptied, but for the lines that say what a device
    /// did or that a schedule went on or off, which a device can't clear.
    case clearLog(flowID: String)
    /// Closes the message at the top of the flow, the run state's `banner`.
    case dismissBanner(flowID: String)
    /// The sidebar's "Stop Its Agents": every session of the flow ends, the orchestrator's included, and so does a run.
    case stopAgents(flowID: String)
    /// The Undo beside "Restart to apply": puts an agent card's settings back to what its session is using.
    /// The folder is left as it is: it is only ever changed on the Mac.
    case revertSettings(flowID: String, cardID: String)
    /// A Start card's "Turn on", or turning its schedule off and leaving it set. Turned on, the schedule runs the
    /// flow with nobody watching, on what the flow does now. A later change from a device to what the flow
    /// does turns it off again.
    case armSchedule(flowID: String, cardID: String, on: Bool)

    // MARK: Editing, stage 4

    /// Paste: copies of the fragment's cards, with the links and groups between them. With a point, the top-left
    /// card lands there; without, the copies land a step down and right of where the cards were. A pasted
    /// Script card's command has to be allowed on the Mac, a pasted agent does not start by itself, and no
    /// folder comes with one.
    case paste(flowID: String, fragment: FlowFragment, at: RemotePoint?)
    /// A new agent made from a saved role, with the middle of its title bar at that point, as one dragged from the
    /// Mac's list of roles.
    case addRoleCard(flowID: String, roleID: String, x: Double, y: Double)
    /// A Flow card's "New sub-flow": a new sub-flow with an Input and an Output, which the card then runs. With an
    /// empty name it is named after the card. The Mac's own window does not go into it.
    case newSubflow(flowID: String, cardID: String, name: String)
    /// Pins the flow to the top of the Mac's sidebar, or unpins it.
    case pin(flowID: String, on: Bool)

    // MARK: Roles

    /// "Save as a New Role": an agent card's instructions, model, effort and permissions saved under a name, and
    /// the card tied to it. With an empty name the role is named after the card.
    case saveRole(flowID: String, cardID: String, name: String)
    /// "Update role": the role takes the settings of a card tied to it. No card changes: one that uses the role
    /// takes the new settings when somebody chooses Reset on it.
    case updateRole(roleID: String, flowID: String, cardID: String)
    /// Deletes a saved role. Cards made from it keep their settings.
    case deleteRole(roleID: String)

    // MARK: A project's browser

    /// "Clear browser data": the project's browser forgets every sign-in, cookie and page it kept.
    case clearBrowserData(projectID: String)
    /// Takes up the Mac's own offer to download a browser, which it makes when there is none on the Mac.
    /// What is downloaded, and from where, is the Mac's to decide.
    case installBrowser(projectID: String)
    /// The Restart, or "Try again", that the Mac offers when the browser has stopped or failed.
    case restartBrowser(projectID: String)

    // MARK: A card's browser

    /// The mouse, keys and address bar of an agent card's browser, as the person at the Mac uses them. Only for
    /// a card the device is watching. It acts as the person would, on whatever site the card is on, signed in or
    /// not, so it is part of "Can control" like typing into a terminal.
    case browser(flowID: String, cardID: String, action: RemoteBrowserAction)

    /// The flow a command is for. A new flow has none yet: it names its project. Nor does a command for a saved
    /// role, or for a project's browser.
    public var flowID: String? {
        switch self {
        case .openOnMac(let id), .run(let id, _), .runFrom(let id, _, _), .stop(let id), .approve(let id, _, _),
             .reject(let id, _, _), .allowScript(let id, _), .refuseScript(let id, _), .startSession(let id, _),
             .prompt(let id, _, _), .keys(let id, _, _), .addCard(let id, _, _, _), .moveCards(let id, _, _),
             .resizeCard(let id, _, _, _), .deleteItems(let id, _, _), .addLink(let id, _, _, _), .setLinkLimit(let id, _, _),
             .duplicate(let id, _), .tidy(let id), .group(let id, _, _), .ungroup(let id, _), .renameGroup(let id, _, _),
             .foldGroup(let id, _, _), .patchCard(let id, _, _), .setFlowOption(let id, _), .renameFlow(let id, _),
             .deleteFlow(let id), .undo(let id), .redo(let id), .runFromStart(let id, _), .retry(let id, _), .clearLog(let id),
             .dismissBanner(let id), .stopAgents(let id), .revertSettings(let id, _), .armSchedule(let id, _, _), .paste(let id, _, _),
             .addRoleCard(let id, _, _, _), .newSubflow(let id, _, _), .pin(let id, _), .saveRole(let id, _, _), .updateRole(_, let id, _),
             .browser(let id, _, _): id
        case .newFlow, .deleteRole, .clearBrowserData, .installBrowser, .restartBrowser: nil
        }
    }

    /// Whether this changes a flow, or makes or deletes one. The Mac did not see the person make such a
    /// change, so it treats it as it treats one its orchestrator made: a Script card's command written this
    /// way is asked about before it runs, and a change to what a scheduled flow does turns its schedules off.
    ///
    /// Turning a schedule on or off is not an edit: it changes nothing in the flow, and it is the one thing that
    /// turns a schedule on. Nor is updating or deleting a role, which changes no card.
    public var isEdit: Bool {
        switch self {
        case .openOnMac, .run, .runFrom, .stop, .approve, .reject, .allowScript, .refuseScript, .startSession, .prompt, .keys,
             .runFromStart, .retry, .clearLog, .dismissBanner, .stopAgents, .armSchedule, .pin, .updateRole, .deleteRole,
             .clearBrowserData, .installBrowser, .restartBrowser, .browser: false
        case .addCard, .moveCards, .resizeCard, .deleteItems, .addLink, .setLinkLimit, .duplicate, .tidy, .group, .ungroup,
             .renameGroup, .foldGroup, .patchCard, .setFlowOption, .newFlow, .renameFlow, .deleteFlow, .undo, .redo,
             .revertSettings, .paste, .addRoleCard, .newSubflow, .saveRole: true
        }
    }

    /// Whether this waits behind a run of the same flow that hasn't begun yet, with the edits. Turning a schedule on
    /// or off is not an edit, but it must not overtake one sent before it: a schedule turned on after an edit is
    /// agreed to for the flow as that edit left it.
    public var waitsWithEdits: Bool {
        if case .armSchedule = self { return true }
        return isEdit
    }

    // MARK: Drags
    //
    // A card follows the finger at once on the device, and the Mac is sent where it has got to a few times a
    // second: `moveCards` or `resizeCard` with `final` false. The Mac makes each step and keeps them all in
    // one step of its Undo. The last one, with `final` true, ends the drag and gives Undo its name.
    //
    // A step that isn't the last gets no answer, done or refused, so a device waits for nothing while it
    // drags: `willSend` keeps no record of one. The last step is answered like any other command, and if
    // the steps before it were being refused it is refused for the same reason.
    //
    // The Mac ends a drag itself, keeping what was moved so far as one step of Undo, when the device sends
    // anything other than the next step of that drag, opens another flow, loses "Can control", or goes.

    /// The drag this is a step of, and whether it is the last step. Nil for every other command.
    public var dragStep: (drag: RemoteDrag, isLast: Bool)? {
        switch self {
        case .moveCards(_, _, let final): (.move, final)
        case .resizeCard(_, let cardID, _, let final): (.resize(cardID: cardID), final)
        default: nil
        }
    }

    /// False for a step of a drag that isn't the last. The Mac sends no answer to one.
    public var isAnswered: Bool {
        // The pointer moving in a card's page, and scrolling it, come many times a second, as a drag's steps do.
        if case .browser(_, _, let action) = self { return action.isAnswered }
        return dragStep.map(\.isLast) ?? true
    }

    /// The same command with its text made safe to show and to enter into a terminal. See `Remote.plainText`
    /// and `Remote.plainLine`. The Mac does this to every command before anything else. Key presses are left
    /// as they are: they are keys.
    public var cleaned: RemoteCommand {
        switch self {
        case .run(let id, let command): .run(flowID: id, command: command.map(Remote.plainText))
        case .runFrom(let id, let cardID, let text): .runFrom(flowID: id, cardID: cardID, text: Remote.plainText(text))
        case .approve(let id, let holdID, let text): .approve(flowID: id, holdID: holdID, text: Remote.plainText(text))
        case .reject(let id, let holdID, let note): .reject(flowID: id, holdID: holdID, note: Remote.plainText(note))
        case .prompt(let id, let key, let text): .prompt(flowID: id, key: key, text: Remote.plainText(text))
        case .addLink(let id, let from, let port, let to): .addLink(flowID: id, from: from, port: Remote.plainLine(port), to: to)
        case .group(let id, let cardIDs, let name): .group(flowID: id, cardIDs: cardIDs, name: Remote.plainLine(name))
        case .renameGroup(let id, let groupID, let name): .renameGroup(flowID: id, groupID: groupID, name: Remote.plainLine(name))
        case .patchCard(let id, let cardID, let patch): .patchCard(flowID: id, cardID: cardID, patch: patch.cleaned)
        case .newFlow(let projectID, let name): .newFlow(projectID: projectID, name: Remote.plainLine(name))
        case .renameFlow(let id, let name): .renameFlow(flowID: id, name: Remote.plainLine(name))
        case .paste(let id, let fragment, let at): .paste(flowID: id, fragment: fragment.cleanedFromDevice, at: at)
        case .newSubflow(let id, let cardID, let name): .newSubflow(flowID: id, cardID: cardID, name: Remote.plainLine(name))
        case .saveRole(let id, let cardID, let name): .saveRole(flowID: id, cardID: cardID, name: Remote.plainLine(name))
        case .browser(let id, let cardID, let action): .browser(flowID: id, cardID: cardID, action: action.cleaned)
        case .openOnMac, .stop, .allowScript, .refuseScript, .startSession, .keys, .addCard, .moveCards, .resizeCard,
             .deleteItems, .setLinkLimit, .duplicate, .tidy, .ungroup, .foldGroup, .setFlowOption, .deleteFlow, .undo, .redo,
             .runFromStart, .retry, .clearLog, .dismissBanner, .stopAgents, .revertSettings, .armSchedule, .addRoleCard, .pin,
             .updateRole, .deleteRole, .clearBrowserData, .installBrowser, .restartBrowser: self
        }
    }

    /// Whether the Mac may be a while doing this: starting a run can wait on a condition being judged, and
    /// stopping one waits its turn behind that. The Mac goes on reading what else the device sends meanwhile.
    public var canTakeTime: Bool {
        switch self {
        case .run, .runFrom, .stop, .runFromStart, .retry: true
        default: false
        }
    }

    /// Why this command can't be obeyed whatever state the Mac is in: it carries too much, or nothing.
    /// Nil when it is fine. A device can ask before sending. The Mac asks every time, whatever was sent.
    public var problem: String? {
        if let problem = contentProblem { return problem }
        // Each part may be within its own cap and the whole still be more than the Mac takes in one message,
        // as with a paste of many long cards. Sent, it would end the connection instead of being refused.
        let size = (try? Remote.encode(DeviceMessage.command(id: Int.max, command: self)).count) ?? Int.max
        return size > Remote.largestFromDevice ? Self.tooBig : nil
    }

    private var contentProblem: String? {
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

        case .addCard(_, _, let x, let y):
            return RemotePoint(x: x, y: y).isOnCanvas ? nil : Self.offCanvas
        case .moveCards(_, let moves, _):
            if moves.isEmpty { return "There is nothing to move." }
            if moves.count > Remote.cardLimit { return Self.tooMany }
            return moves.values.allSatisfy(\.isOnCanvas) ? nil : Self.offCanvas
        case .resizeCard(_, _, let frame, _):
            guard RemotePoint(x: frame.x, y: frame.y).isOnCanvas else { return Self.offCanvas }
            return frame.isCardSized ? nil : "A card can't be that size."
        case .deleteItems(_, let cardIDs, let linkIDs):
            if cardIDs.isEmpty, linkIDs.isEmpty { return "There is nothing to delete." }
            return cardIDs.count > Remote.cardLimit || linkIDs.count > Remote.linkLimit ? Self.tooMany : nil
        case .addLink(_, _, let port, _):
            return Remote.fitsName(port) ? nil : Self.nameTooLong
        case .duplicate(_, let cardIDs):
            if cardIDs.isEmpty { return "There is nothing to duplicate." }
            return cardIDs.count > Remote.cardLimit ? Self.tooMany : nil
        case .group(_, let cardIDs, let name):
            if cardIDs.count > Remote.cardLimit { return Self.tooMany }
            return Remote.fitsName(name) ? nil : Self.nameTooLong
        case .renameGroup(_, _, let name), .newFlow(_, let name):
            return Remote.fitsName(name) ? nil : Self.nameTooLong
        case .renameFlow(_, let name):
            if name.isEmpty { return "A flow needs a name." }
            return Remote.fitsName(name) ? nil : Self.nameTooLong
        case .patchCard(_, _, let patch): return patch.problem
        case .setLinkLimit, .tidy, .ungroup, .foldGroup, .setFlowOption, .deleteFlow, .undo, .redo: return nil

        case .paste(_, let fragment, let at):
            if let at, !at.isOnCanvas { return Self.offCanvas }
            return fragment.deviceProblem
        case .addRoleCard(_, _, let x, let y):
            return RemotePoint(x: x, y: y).isOnCanvas ? nil : Self.offCanvas
        case .newSubflow(_, _, let name), .saveRole(_, _, let name):
            return Remote.fitsName(name) ? nil : Self.nameTooLong
        case .runFromStart, .retry, .clearLog, .dismissBanner, .stopAgents, .revertSettings, .armSchedule, .pin, .updateRole,
             .deleteRole, .clearBrowserData, .installBrowser, .restartBrowser: return nil
        case .browser(_, _, let action): return action.problem
        }
    }

    private static func tooLong(_ text: String) -> String? {
        Remote.fitsText(text, characters: Remote.promptLimit) ? nil : "That message is too long. The most a device can send is \(Remote.promptLimit) characters."
    }

    static let nameTooLong = "That name is too long. The most a device can send is \(Remote.nameLimit) characters."
    static let textTooLong = "That text is too long. The most a device can send is \(Remote.textLimit) characters."
    static let offCanvas = "That is off the edge of the canvas."
    static let tooMany = "That is too many at once."
    static let tooBig = "That is too much to send from a device in one go. Try fewer cards, or less text."
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
