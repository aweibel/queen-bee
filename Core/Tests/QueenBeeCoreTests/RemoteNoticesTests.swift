import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteNoticesTests {
    private func library(_ activity: FlowActivity) -> RemoteLibrary {
        RemoteLibrary(projects: [RemoteProject(id: "/p", name: "P", flows: [
            RemoteFlowSummary(id: "f1", name: "Demo", isSubflow: false, activity: activity),
            RemoteFlowSummary(id: "f2", name: "Other", isSubflow: false, activity: .running),
        ])])
    }

    private func mirror(canControl: Bool, holds: [PendingHold] = []) -> RemoteMirror {
        var mirror = RemoteMirror()
        _ = mirror.apply(.welcome(RemoteWelcome(version: Remote.version, macName: "Mac", canControl: canControl)))
        _ = mirror.apply(.library(library(.running)))
        mirror.willOpen("f1")
        var snapshot = WireSamples.snapshot
        snapshot.run.holds = holds
        snapshot.run.awaitingAnswer = []
        _ = mirror.apply(.opened(snapshot))
        return mirror
    }

    private func run(with holds: [PendingHold], asking: [String] = []) -> HostMessage {
        var state = WireSamples.run
        state.holds = holds
        state.awaitingAnswer = asking
        return .run(id: "f1", state: state)
    }

    private let approval = PendingHold(id: "h1", cardID: "c1", kind: .approval, text: "Ship it?", from: "A")
    private let script = PendingHold(id: "h2", cardID: "c1", kind: .script, text: "", from: "A", command: "rm -rf build", needsAllow: true)

    @Test func whatWasAlreadySoIsNotNews() {
        var notices = RemoteNotices()
        let mirror = mirror(canControl: true, holds: [approval])
        #expect(notices.update(from: mirror).new.isEmpty)
    }

    @Test func aNewApprovalCanBeAnsweredFromTheNotification() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: true)
        _ = notices.update(from: mirror)
        _ = mirror.apply(run(with: [approval]))
        let new = notices.update(from: mirror).new
        #expect(new == [RemoteNotice(id: "hold-f1-h1", title: "Approval waiting", body: "Writer in Demo: Ship it?", flowID: "f1",
                                     holdID: "h1", answer: .approval, heldText: "Ship it?")])
        // Told once.
        #expect(notices.update(from: mirror).new.isEmpty)
        // Answered at the Mac: taken back.
        _ = mirror.apply(run(with: []))
        #expect(notices.update(from: mirror).gone == ["hold-f1-h1"])
    }

    /// A device that may only watch is told, and offered nothing to press.
    @Test func aDeviceThatOnlyWatchesIsOfferedNoButtons() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: false)
        _ = notices.update(from: mirror)
        _ = mirror.apply(run(with: [approval, script]))
        let new = notices.update(from: mirror).new
        #expect(new.count == 2)
        #expect(new.allSatisfy { $0.answer == nil })
    }

    @Test func aScriptOnlyTheMacCanAllowIsOfferedNoButtons() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: true)
        _ = notices.update(from: mirror)
        _ = mirror.apply(run(with: [script, PendingHold(id: "h3", cardID: "c1", kind: .script, text: "", from: "A", command: "ls",
                                                         needsAllow: true, allowOnMac: true)]))
        let new = notices.update(from: mirror).new
        #expect(new.map(\.answer) == [.script, nil])
        #expect(new[1].body.hasSuffix("Allow it on your Mac."))
    }

    @Test func aSessionAskingIsNews() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: true)
        _ = notices.update(from: mirror)
        _ = mirror.apply(run(with: [], asking: ["c1"]))
        #expect(notices.update(from: mirror).new.map(\.title) == ["Writer needs you"])
    }

    @Test func aRunEndingIsNewsOnlyOnce() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: true)
        _ = notices.update(from: mirror)
        _ = mirror.apply(.library(library(.quiet)))
        #expect(notices.update(from: mirror).new.map(\.title) == ["Demo finished"])
        #expect(notices.update(from: mirror).new.isEmpty)
        _ = mirror.apply(.library(library(.failed)))
        #expect(notices.update(from: mirror).new.map(\.title) == ["Demo stopped"])
    }

    @Test func longTextIsCutShortOnOneLine() {
        var notices = RemoteNotices()
        var mirror = mirror(canControl: true)
        _ = notices.update(from: mirror)
        _ = mirror.apply(run(with: [PendingHold(id: "h9", cardID: "c1", kind: .approval, text: String(repeating: "a\n", count: 400), from: "A")]))
        let body = notices.update(from: mirror).new.first?.body ?? ""
        #expect(body.count == 180)
        #expect(!body.contains("\n"))
    }
}
