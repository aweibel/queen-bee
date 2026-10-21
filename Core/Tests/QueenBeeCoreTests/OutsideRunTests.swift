import Foundation
import Testing
@testable import QueenBeeCore

/// Starting a flow from outside the app: `qb run`, and `queenbee://run` links.
@Suite struct OutsideRunTests {
    struct Unreachable: Error {}

    private func run(_ arguments: [String], reply: JSONValue?) -> (stdout: String, stderr: String, exitCode: Int32, sent: [WireRequest]) {
        var sent: [WireRequest] = []
        let result = HelperCommand.runFlow(arguments: arguments, currentDirectory: "/Users/me") { request in
            sent.append(request)
            guard let reply else { throw Unreachable() }
            return reply
        }
        return (String(decoding: result.stdout, as: UTF8.self), String(decoding: result.stderr, as: UTF8.self), result.exitCode, sent)
    }

    // MARK: The command

    @Test func theArgumentsNameAFolderAFlowAndAMessage() {
        #expect(OutsideRun.parse(["/work/site", "Review", "Check the homepage"], currentDirectory: "/x")
                == OutsideRun.Request(project: "/work/site", flow: "Review", message: "Check the homepage", wait: true))
        // A relative folder is from where the command was typed, and the message may be left out.
        #expect(OutsideRun.parse(["site/../app", "a1b2c3d4", "--no-wait"], currentDirectory: "/work")
                == OutsideRun.Request(project: "/work/app", flow: "a1b2c3d4", message: "", wait: false))
        #expect(OutsideRun.parse(["only-a-folder"], currentDirectory: "/work") == nil)
        #expect(OutsideRun.parse(["a", "b", "c", "d"], currentDirectory: "/work") == nil)
        #expect(OutsideRun.parse(["a", " "], currentDirectory: "/work") == nil)
    }

    @Test func aRequestSurvivesTheTripToTheApp() {
        let request = OutsideRun.Request(project: "/work/site", flow: "Review", message: "Go", wait: false)
        #expect(OutsideRun.Request(payload: request.payload) == request)
        #expect(OutsideRun.Request(payload: ["flow": "Review"]) == nil)
    }

    @Test func anAnswerIsPrintedAndExitsZero() {
        let reply = OutsideRun.ended(runID: "r1", flow: "Review", record: record(.finished, ending: .finishedWithAnswer), answers: ["All good", "Saved"])
        let result = run(["/work", "Review", "Go"], reply: reply)
        #expect(result.sent == [WireRequest(kind: "run", session: "", payload: OutsideRun.Request(project: "/work", flow: "Review", message: "Go").payload)])
        #expect(result.stdout == "All good\n\nSaved\n" && result.stderr.isEmpty && result.exitCode == 0)
    }

    @Test func aRunWithNoAnswerSaysHowItEndedAndExitsOne() {
        let reply = OutsideRun.ended(runID: "r1", flow: "Review", record: record(.stopped, ending: .spentLimit), answers: [])
        let result = run(["/work", "Review"], reply: reply)
        #expect(result.stdout.isEmpty && result.exitCode == OutsideRun.Exit.noAnswer)
        #expect(result.stderr == "The run of Review stopped at its spending limit with no answer. Run stopped\n")
        let closed = run(["/work", "Review"], reply: OutsideRun.ended(runID: "r1", flow: "Review", record: nil, answers: []))
        #expect(closed.exitCode == OutsideRun.Exit.noAnswer && closed.stderr.contains("was closed before it ended"))
    }

    @Test func noWaitSaysTheRunStarted() {
        let result = run(["/work", "Review", "--no-wait"], reply: OutsideRun.started(runID: "r9", flow: "Review"))
        #expect(result.sent.first?.payload["wait"] == false)
        #expect(result.stderr == "Started run r9 of Review.\n" && result.exitCode == 0)
    }

    @Test func aRefusalOrAnAppThatIsntOpenExitsThree() {
        let refused = run(["/work", "Review"], reply: OutsideRun.refusal("No flow called Review"))
        #expect(refused.stderr == "No flow called Review\n" && refused.exitCode == OutsideRun.Exit.notStarted)
        let closed = run(["/work", "Review"], reply: nil)
        #expect(closed.stderr.hasPrefix("Couldn't reach Queen Bee") && closed.exitCode == OutsideRun.Exit.notStarted)
        let wrong = run(["/work"], reply: nil)
        #expect(wrong.stderr == OutsideRun.usage && wrong.exitCode == OutsideRun.Exit.usage && wrong.sent.isEmpty)
    }

    @Test func theSocketIsTheNamedOneOrTheFirstAppsThatIsOpen() {
        let home = "/Volumes/Home"
        let installed = "/Volumes/Home/Library/Application Support/QueenBee/qb.sock"
        let dev = "/Volumes/Home/Library/Application Support/QueenBee-Dev/qb.sock"
        #expect(OutsideRun.socketPath(environment: ["QB_SOCKET": "/s"], home: home) { _ in false } == "/s")
        #expect(OutsideRun.socketPath(environment: [:], home: home) { $0 == dev } == dev)
        #expect(OutsideRun.socketPath(environment: [:], home: home) { _ in true } == installed)
        #expect(OutsideRun.socketPath(environment: [:], home: home) { _ in false } == nil)
    }

    // MARK: Links

    @Test func aLinkNamesTheFlowAndTheMessage() throws {
        let link = try #require(OutsideRun.link(url("queenbee://run?flow=a1b2c3d4&message=Hello%20there%0Aand%20more")))
        #expect(link.flow == "a1b2c3d4" && link.message == "Hello there\nand more")
        #expect(OutsideRun.link(url("queenbee://run?flow=a1b2"))?.message == "")
    }

    @Test func otherLinksAndHugeMessagesAreNotRuns() throws {
        #expect(OutsideRun.link(url("queenbee://open?flow=a1")) == nil)
        #expect(OutsideRun.link(url("https://run?flow=a1")) == nil)
        #expect(OutsideRun.link(url("queenbee://run?message=hi")) == nil)
        let long = String(repeating: "a", count: Remote.promptLimit + 1)
        #expect(OutsideRun.link(url("queenbee://run?flow=a1&message=\(long)")) == nil)
        // What a terminal would act on is taken out.
        #expect(OutsideRun.link(url("queenbee://run?flow=a1&message=hi%1B%5B2J"))?.message == "hi[2J")
    }

    private func url(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/") }

    private func record(_ outcome: RunRecord.Outcome, ending: RunEnding) -> RunRecord {
        RunRecord(id: "r1", started: Date(), ended: Date(), outcome: outcome, command: "Go",
                  log: [LogLine(date: Date(), text: "Run stopped")], results: [:], marks: [:], linkPasses: [:],
                  messages: [:], handOffs: 1, ending: ending)
    }
}
