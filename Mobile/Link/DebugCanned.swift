#if DEBUG
import Foundation
import QueenBeeCore
import UIKit

/// A made-up Mac, for checking terminals without one. Launched with `-qbCanned <n>`, the app looks for no
/// Mac: it is handed the first n steps below, as the messages a Mac would send, through the same door real
/// ones come in by. `scripts/e2e.py terminals` reads back what the terminals then show. Everything here is
/// invented: the flow, the names and every byte of output. None of it is in a release build.
///
///   1  a flow is asked for, and its terminals' first screens arrive before the flow itself does
///   2  the flow arrives
///   3  more output follows on, cut in awkward places
///   4  the agent's program leaves the terminal in a state: another screen, a scroll region, odd modes
///   5  the Mac starts the agent's terminal afresh at a smaller size
enum DebugCanned {
    static var isWanted: Bool { wanted > 0 }
    private static var wanted: Int { UserDefaults.standard.integer(forKey: "qbCanned") }
    /// The last step played, for the test to wait on.
    private(set) static var step = 0

    static let flowID = "canned00"
    static let agentID = "agent001"
    /// How many numbered lines the agent prints at first, and how many more follow on.
    static let firstCount = 120
    static let moreCount = 30
    /// How much smaller the fresh start in step 5 is, and how many lines it prints.
    static let shrink = (cols: 12, rows: 4)
    static let freshCount = 40

    static func play(_ client: RemoteClient) async {
        // The size the Mac would give a terminal in a card this big: whole characters of the same type.
        let card = (width: 480.0, height: 300.0)
        let probe = TerminalMount()
        probe.size(cols: 80, rows: 24)
        let cols = Int((card.width - 12) / probe.cell.width), rows = Int((card.height - CanvasGeometry.titleHeight - 8) / probe.cell.height)

        var flow = Flow(id: flowID, name: "Canned", cards: [
            Card(id: "start001", kind: .start, name: "Start", x: 60, y: 150, width: 240, height: 120),
            Card(id: agentID, kind: .agent, name: "Agent", x: 380, y: 60, width: card.width, height: card.height),
            Card(id: "end00001", kind: .end, name: "Done", x: 940, y: 150, width: 240, height: 120),
        ], links: [QueenBeeCore.Link(id: "l0", from: "start001", to: agentID), QueenBeeCore.Link(id: "l1", from: agentID, to: "end00001")])
        flow.notifyOrchestrator = false
        let sessions: [String: SessionState] = [agentID: .working, TerminalRegistry.orchestratorKey: .idle]
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [],
                                 results: [:], usage: [:], sessions: sessions, awaitingAnswer: [], banner: nil)
        let summary = RemoteFlowSummary(id: flowID, name: "Canned", isSubflow: false, activity: .quiet)
        let other = RemoteFlowSummary(id: "canned01", name: "Another flow", isSubflow: false, activity: .quiet)

        func agent(_ text: String, reset: Bool = false, cols: Int = cols, rows: Int = rows) {
            client.debugTake(.terminal(id: flowID, key: agentID, chunk: TerminalChunk(reset: reset, cols: cols, rows: rows, data: Data(text.utf8))))
        }
        func done(_ n: Int) async -> Bool {
            step = n
            // Read by the state file, which is written again when the terminals say they have changed.
            client.canvas.didChangeWhatIsShown()
            try? await Task.sleep(for: .milliseconds(400))
            return n >= wanted
        }
        func numbers(_ range: ClosedRange<Int>) -> String { range.map { "\($0)\r\n" }.joined() }
        let esc = "\u{1b}"

        // 1
        client.debugTake(.welcome(RemoteWelcome(version: Remote.version, macName: "Example Mac", canControl: false)))
        client.debugTake(.library(RemoteLibrary(projects: [RemoteProject(id: "p", name: "Example project", flows: [summary, other])])))
        client.open(flowID)
        // What a program asks its terminal as it starts: what it is, its colours, its keyboard, the size of
        // a character, where the cursor is. Each has an answer, and every answer must go nowhere.
        let questions = "\(esc)[c\(esc)[>c\(esc)]11;?\(esc)\\\(esc)[?u\(esc)[16t\(esc)[6n"
        let banner = "\(esc)[1;38;5;208m● Agent\(esc)[0m ready in \(esc)[36m~/example\(esc)[0m\r\n\(esc)[2mA made-up session, for checking the terminal.\(esc)[0m\r\n"
        agent(questions + banner + numbers(1 ... firstCount), reset: true)
        let side = (cols: 58, rows: 40)
        let orchestrator = "\(esc)[1mOrchestrator\(esc)[0m\r\n\(esc)[2mRuns the flow called Canned.\(esc)[0m\r\n\r\n"
            + (1 ... 12).map { "\(esc)[32m✓\(esc)[0m step \($0) handed on\r\n" }.joined() + "\r\n\(esc)[7m \(esc)[0m"
        client.debugTake(.terminal(id: flowID, key: TerminalRegistry.orchestratorKey,
                                   chunk: TerminalChunk(reset: true, cols: side.cols, rows: side.rows, data: Data(orchestrator.utf8))))
        // A chunk for a flow that isn't the open one is not this flow's to show.
        client.debugTake(.terminal(id: "canned01", key: agentID, chunk: TerminalChunk(reset: false, cols: cols, rows: rows, data: Data("STRAY\r\n".utf8))))
        if await done(1) { return }

        // 2
        client.debugTake(.opened(RemoteFlowSnapshot(flow: flow, run: run, log: [], messages: [:], runs: [])))
        if await done(2) { return }

        // 3: cut inside a colour change and inside a character of more than one byte.
        let more = "\(esc)[32m✓ still going\(esc)[0m\r\n" + numbers(firstCount + 1 ... firstCount + moreCount) + "\(esc)[1m> \(esc)[0m"
        let bytes = Array(more.utf8)
        var at = 0
        for cut in [3, 6, 40, 41, bytes.count] where cut > at {
            client.debugTake(.terminal(id: flowID, key: agentID, chunk: TerminalChunk(reset: false, cols: cols, rows: rows, data: Data(bytes[at ..< cut]))))
            at = cut
        }
        if await done(3) { return }

        // 4: the other screen, a scroll region, the origin moved, insert mode, reversed colours, no cursor.
        agent("\(esc)[?1049h\(esc)[5;10r\(esc)[?6h\(esc)[4h\(esc)[7m\(esc)[?25lLEFTOVER")
        if await done(4) { return }

        // 5
        agent("after the fresh start\r\n" + numbers(1 ... freshCount), reset: true, cols: cols - shrink.cols, rows: rows - shrink.rows)
        _ = await done(5)
    }
}
#endif
