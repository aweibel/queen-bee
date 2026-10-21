import Foundation

/// Starting a flow from outside the app: the `qb run` command, and `queenbee://run` links. Both give the flow a
/// message as if it were typed into its Start card. The command can wait for the run to end and print its answer;
/// a link only starts the run, and only once the person has said yes to it in the app.
public enum OutsideRun {
    /// What `qb run` asks the app for.
    public struct Request: Equatable, Sendable {
        /// The project folder, as a full path.
        public var project: String
        /// The flow's id, or its name.
        public var flow: String
        /// What the run starts with. Empty for the Start card's own command.
        public var message: String
        /// Whether to wait for the run to end.
        public var wait: Bool

        public init(project: String, flow: String, message: String = "", wait: Bool = true) {
            self.project = project; self.flow = flow; self.message = message; self.wait = wait
        }

        public var payload: JSONValue {
            ["project": .string(project), "flow": .string(flow), "message": .string(message), "wait": .bool(wait)]
        }

        /// The request a payload holds, or nil when it names no folder or no flow.
        public init?(payload: JSONValue) {
            guard let project = payload["project"]?.stringValue, !project.isEmpty,
                  let flow = payload["flow"]?.stringValue, !flow.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            self.init(project: project, flow: flow, message: payload["message"]?.stringValue ?? "", wait: payload["wait"]?.boolValue != false)
        }
    }

    /// How `qb run` exits.
    public enum Exit {
        /// An answer reached an End card, or, with --no-wait, the run started.
        public static let answered: Int32 = 0
        /// The run ended with no answer: stopped, failed, or with nothing reaching an End card.
        public static let noAnswer: Int32 = 1
        /// The command was written wrongly.
        public static let usage: Int32 = 2
        /// No run started: the app wasn't open, or it refused, and says why.
        public static let notStarted: Int32 = 3
    }

    public static let usage = """
    usage: qb run <project folder> <flow name or id> [message] [--no-wait]
      Starts the flow with the message, as if it were typed into its Start card, waits for the run to end and
      prints what reached its End cards. With no message, the Start card's own command is used. --no-wait
      returns as soon as the run has started. Queen Bee must be open, and the folder one you have opened in it.

    """

    /// The request in `qb run`'s arguments, the ones after "run". A relative folder is taken from `currentDirectory`.
    public static func parse(_ arguments: [String], currentDirectory: String) -> Request? {
        var wait = true
        var words: [String] = []
        for argument in arguments {
            if argument == "--no-wait" { wait = false } else { words.append(argument) }
        }
        guard (2...3).contains(words.count), !words[0].isEmpty, !words[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let folder = (words[0] as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        let project = URL(fileURLWithPath: folder, relativeTo: folder.hasPrefix("/") ? nil : base).standardizedFileURL.path
        return Request(project: project, flow: words[1], message: words.count == 3 ? words[2] : "", wait: wait)
    }

    // MARK: The app's answers

    public static func refusal(_ why: String) -> JSONValue { ["error": .string(why)] }

    public static func started(runID: String, flow: String) -> JSONValue {
        ["started": true, "run": .string(runID), "flow": .string(flow)]
    }

    /// The app's answer once the run has ended. `answers` is what reached the flow's End cards, in canvas order.
    /// A nil record is a run whose flow was closed before it ended.
    public static func ended(runID: String, flow: String, record: RunRecord?, answers: [String]) -> JSONValue {
        guard let record else {
            return ["started": true, "run": .string(runID), "flow": .string(flow), "finished": false,
                    "summary": "was closed before it ended", "answers": []]
        }
        return ["started": true, "run": .string(runID), "flow": .string(flow),
                "finished": .bool(record.outcome == .finished && !answers.isEmpty),
                "summary": .string(record.summary), "last": .string(record.log.last?.text ?? ""),
                "answers": .array(answers.map(JSONValue.string))]
    }

    /// What `qb run` prints, to standard output and standard error, and the code it exits with.
    public static func outcome(of reply: JSONValue) -> (stdout: String, stderr: String, exitCode: Int32) {
        if let error = reply["error"]?.stringValue { return ("", error + "\n", Exit.notStarted) }
        guard reply["started"]?.boolValue == true else { return ("", "Queen Bee didn't start the run.\n", Exit.notStarted) }
        let flow = reply["flow"]?.stringValue ?? "The flow"
        let run = reply["run"]?.stringValue ?? ""
        guard let summary = reply["summary"]?.stringValue else {
            return ("", "Started run \(run) of \(flow).\n", Exit.answered)
        }
        let answers = (reply["answers"]?.arrayValue ?? []).compactMap(\.stringValue)
        let printed = answers.isEmpty ? "" : answers.joined(separator: "\n\n") + "\n"
        if reply["finished"]?.boolValue == true { return (printed, "", Exit.answered) }
        let last = reply["last"]?.stringValue ?? ""
        let why = "The run of \(flow) \(summary)\(answers.isEmpty ? " with no answer" : "")." + (last.isEmpty ? "" : " \(last)")
        return (printed, why + "\n", Exit.noAnswer)
    }

    // MARK: Finding the app

    /// The app's socket: the one `QB_SOCKET` names, as inside an agent's session, or else the installed app's, or
    /// else the one a build from source keeps. Nil when none is there, which is when the app isn't open.
    public static func socketPath(environment: [String: String], home: String, exists: (String) -> Bool) -> String? {
        if let named = environment["QB_SOCKET"], !named.isEmpty { return named }
        let support = (home as NSString).appendingPathComponent("Library/Application Support")
        return ["QueenBee", "QueenBee-Dev"].map { (support as NSString).appendingPathComponent("\($0)/qb.sock") }.first(where: exists)
    }

    // MARK: Links

    /// A `queenbee://run?flow=<id>&message=<text>` link: the flow, by id or name, and the message, which may be
    /// left out for the Start card's own command. Nil for any other link, and for a message longer than a paired
    /// device may send.
    public static func link(_ url: URL) -> (flow: String, message: String)? {
        guard url.scheme?.lowercased() == "queenbee", url.host?.lowercased() == "run",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let flow = items.first(where: { $0.name == "flow" })?.value?.trimmingCharacters(in: .whitespaces), !flow.isEmpty else { return nil }
        let message = items.first(where: { $0.name == "message" })?.value ?? ""
        guard message.count <= Remote.promptLimit else { return nil }
        return (flow, Remote.plainText(message))
    }
}
