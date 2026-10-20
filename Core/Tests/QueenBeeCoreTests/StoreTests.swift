import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct StoreTests {
    /// A fresh project folder per test, removed when the test's value goes away.
    final class Project {
        let root: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qb-store-\(Flow.newID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func slugsAreSafeFileNames() {
        #expect(FlowStore.slug("Review Loop") == "review-loop")
        #expect(FlowStore.slug("  Triage: bugs & features!  ") == "triage-bugs-features")
        #expect(FlowStore.slug("???") == "flow")
        #expect(FlowStore.slug("") == "flow")
        let long = FlowStore.slug(String(repeating: "abc ", count: 30))
        #expect(long.count <= 40)
        #expect(!long.hasSuffix("-"))
    }

    @Test func aFlowRoundTripsThroughDisk() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        var flow = Flow(name: "Review Loop")
        try flow.addCard(kind: .start, name: "Start")
        try flow.addCard(kind: .agent, name: "Writer")
        try flow.addLink(from: "Start", to: "Writer")

        let url = try store.save(flow, to: nil)
        #expect(url.path == store.directory.appendingPathComponent("review-loop.json").path)
        #expect(store.directory.path == project.root.appendingPathComponent(".queenbee/flows").path)

        let loaded = store.loadAll()
        #expect(loaded.unreadable.isEmpty)
        #expect(loaded.flows.map(\.flow) == [flow])
        #expect(loaded.flows.first?.url.path == url.path)
    }

    @Test func filesArePrettySortedAndEndWithANewline() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        let url = try store.save(Flow(name: "A"), to: nil)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasSuffix("}\n"))
        #expect(text.contains("\n  \"cards\""))
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  \"") else { return nil }
            return String(line.dropFirst(3).prefix { $0 != "\"" })
        }
        #expect(keys == keys.sorted())
        #expect(keys.contains("version"))
    }

    @Test func theFirstSaveWritesAGitignoreAndLeavesNoTempFiles() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        try store.save(Flow(name: "A"), to: nil)
        let ignore = project.root.appendingPathComponent(".queenbee/.gitignore")
        #expect(try String(contentsOf: ignore, encoding: .utf8) == "*\n")

        // A gitignore the person edited is left alone.
        try "flows/\n".write(to: ignore, atomically: true, encoding: .utf8)
        try store.save(Flow(name: "B"), to: nil)
        #expect(try String(contentsOf: ignore, encoding: .utf8) == "flows/\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted() == ["a.json", "b.json"])
    }

    @Test func aTakenNameGetsTheStartOfTheFlowID() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        let first = Flow(id: "aaaa1111", name: "Review")
        let second = Flow(id: "bbbb2222", name: "Review")
        #expect(try store.save(first, to: nil).lastPathComponent == "review.json")
        #expect(try store.save(second, to: nil).lastPathComponent == "review-bbbb.json")
        #expect(store.loadAll().flows.map(\.flow.id) == ["bbbb2222", "aaaa1111"])
    }

    @Test func savingToAGivenURLOverwritesThatFile() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        var flow = Flow(name: "Review")
        let url = try store.save(flow, to: nil)
        flow.name = "Renamed"
        #expect(try store.save(flow, to: url).path == url.path)
        let loaded = store.loadAll()
        #expect(loaded.flows.count == 1)
        #expect(loaded.flows.first?.flow.name == "Renamed")
    }

    @Test func unreadableFilesAreListedAndNeverOverwritten() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        let good = Flow(id: "aaaa1111", name: "Good")
        try store.save(good, to: nil)

        let broken = store.directory.appendingPathComponent("review.json")
        try "{ not json".write(to: broken, atomically: true, encoding: .utf8)

        var future = Flow(id: "cccc3333", name: "Future")
        future.version = Flow.currentVersion + 1
        let futureURL = store.directory.appendingPathComponent("future.json")
        try JSONEncoder().encode(future).write(to: futureURL)

        // The same flow id twice: the first file by name wins.
        let copy = store.directory.appendingPathComponent("zcopy.json")
        try JSONEncoder().encode(good).write(to: copy)

        let loaded = store.loadAll()
        #expect(loaded.flows.map(\.flow) == [good])
        #expect(loaded.unreadable.map(\.lastPathComponent) == ["future.json", "review.json", "zcopy.json"])

        // A new flow whose slug matches the broken file goes somewhere else.
        let review = Flow(id: "dddd4444", name: "Review")
        #expect(try store.save(review, to: nil).lastPathComponent == "review-dddd.json")
        #expect(try String(contentsOf: broken, encoding: .utf8) == "{ not json")

        // Only an explicit url replaces it.
        try store.save(review, to: broken)
        #expect(try JSONDecoder().decode(Flow.self, from: Data(contentsOf: broken)) == review)
    }

    @Test func aFlowWhoseIDsCouldPassForAnotherSessionIsNotLoaded() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        try store.save(Flow(id: "aaaa1111", name: "Good"), to: nil)

        // A session is known to the app as "<flow id>/<card id>", and the orchestrator's is
        // "<flow id>/orchestrator". A file can't be allowed to name a card into either.
        func write(_ name: String, flowID: String, cardID: String) throws {
            let card = Card(id: cardID, kind: .agent, name: "Agent", x: 0, y: 0, width: 240, height: 96)
            let flow = Flow(id: flowID, name: name, cards: [card])
            try JSONEncoder().encode(flow).write(to: store.directory.appendingPathComponent(name + ".json"))
        }
        try write("named-orchestrator", flowID: "bbbb2222", cardID: "orchestrator")
        try write("slash-in-card", flowID: "cccc3333", cardID: "x/orchestrator")
        try write("slash-in-flow", flowID: "dddd/4444", cardID: "eeee5555")
        try write("no-card-id", flowID: "ffff6666", cardID: "")
        try write("plain", flowID: "abcd7777", cardID: "writer1234")

        let loaded = store.loadAll()
        #expect(loaded.flows.map(\.flow.name) == ["Good", "plain"])
        #expect(loaded.unreadable.map(\.lastPathComponent)
                == ["named-orchestrator.json", "no-card-id.json", "slash-in-card.json", "slash-in-flow.json"])
    }

    @Test func deleteRemovesTheFile() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        let url = try store.save(Flow(name: "Gone"), to: nil)
        try store.delete(url)
        #expect(store.loadAll().flows.isEmpty)
        #expect(throws: (any Error).self) { try store.delete(url) }
    }

    // MARK: Surviving a crash

    @Test func savingOverAFlowKeepsTheVersionBeforeBesideIt() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        var flow = Flow(name: "Review")
        let url = try store.save(flow, to: nil)
        // A new file has nothing to keep.
        #expect(!FileManager.default.fileExists(atPath: FlowStore.backupURL(for: url).path))
        flow.name = "Second"
        try store.save(flow, to: url)
        let kept = try JSONDecoder().decode(Flow.self, from: Data(contentsOf: FlowStore.backupURL(for: url)))
        #expect(kept.name == "Review")
        #expect(FlowStore.backupURL(for: url).lastPathComponent.hasPrefix("."))
    }

    @Test func aFlowFileLeftEmptyOrGarbledLoadsFromTheVersionBefore() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        var flow = Flow(id: "aaaa1111", name: "Review")
        let url = try store.save(flow, to: nil)
        flow.name = "Second"
        try store.save(flow, to: url)
        for damage in ["", "{\"cards\": [{\"id\""] {
            try Data(damage.utf8).write(to: url)
            let loaded = store.loadAll()
            #expect(loaded.unreadable.isEmpty)
            #expect(loaded.flows.map(\.flow.name) == ["Review"])
            // It is loaded as the flow in the damaged file, so the next save puts that file right.
            #expect(loaded.flows.first?.url.path == url.path)
        }
    }

    @Test func aFlowFromANewerVersionIsNeverSwappedForTheVersionBefore() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        var flow = Flow(id: "aaaa1111", name: "Review")
        let url = try store.save(flow, to: nil)
        try store.save(flow, to: url)
        flow.version = Flow.currentVersion + 1
        try JSONEncoder().encode(flow).write(to: url)
        let loaded = store.loadAll()
        #expect(loaded.flows.isEmpty)
        #expect(loaded.unreadable.map(\.path) == [url.path])
    }

    @Test func deletingAFlowDeletesTheVersionBeforeToo() throws {
        let project = try Project()
        let store = FlowStore(root: project.root)
        let flow = Flow(name: "Gone")
        let url = try store.save(flow, to: nil)
        try store.save(flow, to: url)
        try store.delete(url)
        #expect(!FileManager.default.fileExists(atPath: FlowStore.backupURL(for: url).path))
    }

    @Test func aProjectWithNoFlowsLoadsEmpty() throws {
        let project = try Project()
        let loaded = FlowStore(root: project.root).loadAll()
        #expect(loaded.flows.isEmpty && loaded.unreadable.isEmpty)
    }
}
