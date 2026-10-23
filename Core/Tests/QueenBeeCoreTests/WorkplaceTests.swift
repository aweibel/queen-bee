import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct WorkplaceTests {
    private let root = URL(fileURLWithPath: "/Users/k/acme", isDirectory: true)

    /// Parent runs Child by name, and Child runs Grandchild.
    private func family(parent: Workplace? = nil, child: Workplace? = nil) -> [Flow] {
        func runs(_ name: String, _ flow: inout Flow) {
            var patch = CardPatch()
            patch.flowRef = name
            _ = try? flow.addCard(kind: .flow, name: "Run \(name)", patch: patch)
        }
        var top = Flow(id: "p", name: "Parent")
        top.workplace = parent
        runs("Child", &top)
        var middle = Flow(id: "c", name: "Child")
        middle.workplace = child
        runs("Grandchild", &middle)
        return [top, middle, Flow(id: "g", name: "Grandchild")]
    }

    @Test func aFlowFromBeforeTheSettingHasNone() throws {
        let data = try JSONEncoder().encode(Flow(id: "f1", name: "Old"))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["workplace"] == nil)
        json["workplace"] = nil
        let read = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.workplace == nil)
    }

    @Test func theSettingIsKeptInTheFlowsFile() throws {
        var flow = Flow(id: "f1", name: "New")
        flow.workplace = .worktree("qb/new", from: "main")
        let read = try JSONDecoder().decode(Flow.self, from: JSONEncoder().encode(flow))
        #expect(read.workplace == .worktree("qb/new", from: "main"))
    }

    @Test func subFlowsWorkWhereTheFlowAtTheTopDoes() {
        let flows = family(parent: .worktree("qb/parent", from: "main"), child: .folder(on: "dev"))
        let nesting = Nesting(flows: flows)
        let own = Workplace.effective(for: "p", in: flows, nesting: nesting)
        #expect(own.workplace == .worktree("qb/parent", from: "main") && own.from == nil)
        // The child's own setting is ignored: one place for the whole chain.
        for id in ["c", "g"] {
            let found = Workplace.effective(for: id, in: flows, nesting: nesting)
            #expect(found.workplace == .worktree("qb/parent", from: "main"))
            #expect(found.from == "p")
        }
    }

    @Test func aSubFlowUnderAFlowWithNoSettingHasNoneEither() {
        let flows = family(child: .folder(on: "dev"))
        let found = Workplace.effective(for: "g", in: flows, nesting: Nesting(flows: flows))
        #expect(found.workplace == nil && found.from == "p")
    }

    @Test func branchNamesThatCouldReachGitAsSomethingElseAreRefused() {
        for good in ["main", "qb/fix-login", "release/1.4", "feature_x"] {
            #expect(Workplace.problem(branchName: good) == nil, "\(good)")
        }
        for bad in ["", "  ", "-f", "--force", "a b", "a..b", "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b", "/a", "a/", "a//b",
                    "a.", "a.lock", ".hidden", "qb/.x", "@", "a@{1}", "a\u{7}"] {
            #expect(Workplace.problem(branchName: bad) != nil, "\(bad)")
        }
    }

    @Test func aNewWorktreeIsOfferedABranchNamedForTheFlow() {
        #expect(Workplace.suggestedBranch(forFlowNamed: "Fix login bug", id: "ab12") == "qb/fix-login-bug")
        #expect(Workplace.suggestedBranch(forFlowNamed: "  Ship it!! v2 ", id: "ab12") == "qb/ship-it-v2")
        #expect(Workplace.suggestedBranch(forFlowNamed: "日本語", id: "ab12") == "qb/ab12")
        #expect(Workplace.problem(branchName: Workplace.suggestedBranch(forFlowNamed: String(repeating: "word ", count: 30), id: "x")) == nil)
    }

    @Test func worktreesLiveInsideTheProjectsQueenBeeFolder() {
        #expect(Workplace.worktreeFolder(for: "qb/fix-login", in: root).path == "/Users/k/acme/.queenbee/worktrees/qb-fix-login")
    }

    @Test func gitsListOfWorktreesIsRead() {
        let porcelain = """
        worktree /Users/k/acme
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/k/acme/.queenbee/worktrees/qb-fix
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/qb/fix

        worktree /tmp/detached
        HEAD 3333333333333333333333333333333333333333
        detached
        """
        #expect(Workplace.parseWorktrees(porcelain) == [
            .init(path: "/Users/k/acme", branch: "main"),
            .init(path: "/Users/k/acme/.queenbee/worktrees/qb-fix", branch: "qb/fix"),
            .init(path: "/tmp/detached", branch: nil),
        ])
    }

    @Test func aWorktreeIsReusedCheckedOutOrMade() {
        let have = [Workplace.Worktree(path: "/Users/k/acme", branch: "main"), .init(path: "/elsewhere/fix", branch: "qb/fix")]
        let reuse = Workplace.worktreePlan(branch: "qb/fix", base: "main", root: root, worktrees: have, branches: ["main", "qb/fix"])
        #expect(reuse == .reuse(path: "/elsewhere/fix") && reuse.gitArguments == nil)

        let add = Workplace.worktreePlan(branch: "dev", base: "main", root: root, worktrees: have, branches: ["main", "dev"])
        #expect(add.gitArguments == ["worktree", "add", "--", "/Users/k/acme/.queenbee/worktrees/dev", "dev"])

        let create = Workplace.worktreePlan(branch: "qb/new", base: "main", root: root, worktrees: have, branches: ["main"])
        #expect(create.gitArguments == ["worktree", "add", "-b", "qb/new", "--", "/Users/k/acme/.queenbee/worktrees/qb-new", "main"])
        #expect(create.path == "/Users/k/acme/.queenbee/worktrees/qb-new")
    }

    @Test func cardFoldersFollowTheFlowIntoItsWorktree() {
        let worktree = Workplace.worktreeFolder(for: "qb/x", in: root)
        // In the project folder itself, nothing changes.
        #expect(Workplace.folder(forCard: nil, projectRoot: root, workRoot: root) == root.path)
        #expect(Workplace.folder(forCard: "/Users/k/acme/web", projectRoot: root, workRoot: root) == "/Users/k/acme/web")
        // In a worktree, a card's folder inside the project moves with it; one outside stays put.
        #expect(Workplace.folder(forCard: "", projectRoot: root, workRoot: worktree) == worktree.path)
        #expect(Workplace.folder(forCard: "/Users/k/acme", projectRoot: root, workRoot: worktree) == worktree.path)
        #expect(Workplace.folder(forCard: "/Users/k/acme/web", projectRoot: root, workRoot: worktree) == worktree.path + "/web")
        #expect(Workplace.folder(forCard: "web/app", projectRoot: root, workRoot: worktree) == worktree.path + "/web/app")
        #expect(Workplace.folder(forCard: "/Users/k/other", projectRoot: root, workRoot: worktree) == "/Users/k/other")
        #expect(Workplace.folder(forCard: "/Users/k/acme-old", projectRoot: root, workRoot: worktree) == "/Users/k/acme-old")
        #expect(Workplace.folder(forCard: "~/notes", projectRoot: root, workRoot: worktree) == "~/notes")
    }

    @Test func theChipSaysWhichBranchAndWhetherItIsAWorktree() {
        #expect(Workplace.asItIs.chipText(current: "main") == "main")
        #expect(Workplace.asItIs.chipText(current: nil) == "no branch")
        #expect(Workplace.folder(on: "dev").chipText(current: "main") == "dev")
        #expect(Workplace.worktree("qb/x", from: "main").chipText(current: "main") == "qb/x · worktree")
        #expect(Workplace.worktree("qb/x", from: nil).summary(project: "acme", current: "main") == "Works in a worktree of acme on qb/x.")
        #expect(Workplace.folder(on: "dev").summary(project: "acme", current: "main") == "Works in acme, switched to dev.")
    }
}
