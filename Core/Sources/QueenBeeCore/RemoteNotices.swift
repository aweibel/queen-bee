import Foundation

/// Something a device tells the person about with a notification: a message held for approval, a script waiting
/// to be allowed, a session asking something, or a flow's run ending.
public struct RemoteNotice: Equatable, Sendable {
    /// The buttons a notification about a held message offers.
    public enum Answer: String, Equatable, Sendable {
        /// Approve and Reject.
        case approval
        /// Allow and Don't Allow, for a script's command.
        case script
    }

    /// The same for as long as what it is about lasts, so it is never told twice and can be taken back.
    public var id: String
    public var title: String
    public var body: String
    public var flowID: String
    /// The held message it is about, and what the person may answer from the notification. Nil answer: only
    /// opening the app. A device that may only watch is never offered one.
    public var holdID: String?
    public var answer: Answer?
    /// What an approval sends back: the held message as it was.
    public var heldText: String?

    public init(id: String, title: String, body: String, flowID: String, holdID: String? = nil, answer: Answer? = nil, heldText: String? = nil) {
        self.id = id; self.title = title; self.body = body; self.flowID = flowID; self.holdID = holdID; self.answer = answer; self.heldText = heldText
    }
}

/// What a device has already told the person about, so that each look at what the Mac sent turns up only what
/// is new. What was already so when the device first saw it is not news: a flow seen for the first time, and the
/// open flow when its copy first arrives, only set the starting point.
public struct RemoteNotices: Equatable, Sendable {
    private var holds: Set<String> = []
    private var asks: Set<String> = []
    private var activity: [String: FlowActivity] = [:]
    /// The flows whose copy has been seen, whose held messages and questions are news from then on.
    private var seen: Set<String> = []

    public init() {}

    /// The longest a notification's text gets.
    static let longest = 180
    /// How recently a run's record must have ended to be the run whose end is being told about.
    static let justEnded: TimeInterval = 120

    /// Takes the device's copy of what the Mac sent, as it is now. Returns what is new since the last look, and
    /// the ids of notices about things that have since gone, such as a message approved at the Mac.
    public mutating func update(from mirror: RemoteMirror, now: Date = Date()) -> (new: [RemoteNotice], gone: [String]) {
        var new: [RemoteNotice] = []
        var gone: [String] = []
        let names = Dictionary((mirror.library?.projects ?? []).flatMap(\.flows).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        if let snapshot = mirror.snapshot {
            let flowID = snapshot.flow.id
            let flowName = names[flowID] ?? snapshot.flow.name
            let isNews = seen.contains(flowID)
            seen.insert(flowID)
            func cardName(_ id: String) -> String { snapshot.flow.card(id)?.name ?? (id == Remote.orchestratorKey ? "The orchestrator" : "A card") }

            let holdNow = Set(snapshot.run.holds.map { "hold-\(flowID)-\($0.id)" })
            for hold in snapshot.run.holds where isNews && !holds.contains("hold-\(flowID)-\(hold.id)") {
                let id = "hold-\(flowID)-\(hold.id)"
                switch hold.kind {
                case .approval:
                    new.append(RemoteNotice(id: id, title: "Approval waiting", body: Self.cut("\(cardName(hold.cardID)) in \(flowName): \(hold.text)"),
                                            flowID: flowID, holdID: hold.id, answer: mirror.canControl ? .approval : nil, heldText: hold.text))
                case .script:
                    let answer: RemoteNotice.Answer? = mirror.canControl && hold.canBeAllowedFromDevice ? .script : nil
                    let words = hold.allowOnMac == true ? " Allow it on your Mac." : ""
                    new.append(RemoteNotice(id: id, title: "A script is waiting for you",
                                            body: Self.cut("\(cardName(hold.cardID)) in \(flowName) wants to run: \(hold.command).\(words)"),
                                            flowID: flowID, holdID: hold.id, answer: answer))
                default:
                    break
                }
            }
            gone += holds.filter { $0.hasPrefix("hold-\(flowID)-") && !holdNow.contains($0) }
            holds = holds.filter { !$0.hasPrefix("hold-\(flowID)-") }.union(holdNow)

            let askNow = Set(snapshot.run.awaitingAnswer.map { "ask-\(flowID)-\($0)" })
            for key in snapshot.run.awaitingAnswer where isNews && !asks.contains("ask-\(flowID)-\(key)") {
                new.append(RemoteNotice(id: "ask-\(flowID)-\(key)", title: "\(cardName(key)) needs you", body: Self.cut("In \(flowName)."), flowID: flowID))
            }
            gone += asks.filter { $0.hasPrefix("ask-\(flowID)-") && !askNow.contains($0) }
            asks = asks.filter { !$0.hasPrefix("ask-\(flowID)-") }.union(askNow)
        }

        for flow in (mirror.library?.projects ?? []).flatMap(\.flows) {
            let before = activity[flow.id]
            activity[flow.id] = flow.activity
            guard let before, before != flow.activity else { continue }
            switch flow.activity {
            case .quiet where before == .running:
                // A run stopped by the person or at a limit goes quiet too, so only the run's own record says it
                // finished. That is known for the open flow once its history has come, as a run that has just
                // ended; an older record is an earlier run's, and then how it ended isn't said.
                let latest = mirror.snapshot.flatMap { $0.flow.id == flow.id ? $0.runs.max { $0.started < $1.started } : nil }
                    .flatMap { now.timeIntervalSince($0.ended) < Self.justEnded ? $0 : nil }
                let title = latest.map { "\(flow.name): \($0.summary)" } ?? "\(flow.name)'s run has ended"
                new.append(RemoteNotice(id: "done-\(flow.id)", title: title, body: "Open it to see what the run did.", flowID: flow.id))
            case .failed:
                new.append(RemoteNotice(id: "done-\(flow.id)", title: "\(flow.name) stopped", body: "The run didn't finish. Open it to see why.", flowID: flow.id))
            // The open flow's held messages and questions say more than this.
            case .needsYou where flow.id != mirror.snapshot?.flow.id:
                new.append(RemoteNotice(id: "needs-\(flow.id)", title: "\(flow.name) needs you", body: "Something in it is waiting for you.", flowID: flow.id))
            default:
                break
            }
            if before == .needsYou, flow.activity != .needsYou { gone.append("needs-\(flow.id)") }
        }
        return (new, gone)
    }

    private static func cut(_ text: String) -> String {
        let line = Remote.plainLine(text)
        return line.count > longest ? String(line.prefix(longest - 1)) + "…" : line
    }
}
