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

    @Test func theFolderCantBeSwitchedToABranchAWorktreeHasOpen() {
        let root = URL(fileURLWithPath: "/Users/k/acme", isDirectory: true)
        let listed = [
            Workplace.Worktree(path: root.path, branch: "main"),
            Workplace.Worktree(path: Workplace.worktreeFolder(for: "qb/x", in: root).path, branch: "qb/x"),
            Workplace.Worktree(path: "/Users/k/elsewhere", branch: "dev"),
            Workplace.Worktree(path: "/Users/k/detached", branch: nil),
        ]
        #expect(Workplace.branchesOpenElsewhere(worktrees: listed, projectRoot: root) == ["qb/x", "dev"])
        #expect(Workplace.branchesOpenElsewhere(worktrees: listed, projectRoot: URL(fileURLWithPath: "/Users/k/acme/")) == ["qb/x", "dev"])
        #expect(Workplace.branchesOpenElsewhere(worktrees: [listed[0]], projectRoot: root).isEmpty)
    }

    @Test func theNoteNamesOneBranchLeftOutAndCountsMore() {
        #expect(Workplace.notListedNote([]) == nil)
        #expect(Workplace.notListedNote(["qb/x"])
                == "qb/x isn't listed: it's open in a worktree, and git lets a branch be open in only one place. To use it, choose A worktree.")
        let many = (1...42).map { "cursor/\($0)" }
        #expect(Workplace.notListedNote(many)
                == "42 branches aren't listed: they're open in worktrees, and git lets a branch be open in only one place. To use one, choose A worktree.")
        #expect(Workplace.notListedNote(["a", "b"])?.hasPrefix("2 branches aren't listed") == true)
    }

    @Test func theChipSaysWhereTheFlowWorksNowNotWhatItIsSetTo() {
        let root = URL(fileURLWithPath: "/Users/k/acme", isDirectory: true)
        let worktree = Workplace.worktreeFolder(for: "qb/x", in: root)
        let listed = [Workplace.Worktree(path: root.path, branch: "main"), Workplace.Worktree(path: worktree.path, branch: "qb/x")]
        #expect(Workplace.chipText(workRoot: root, projectRoot: root, current: "main", worktrees: listed, expected: nil) == "main")
        #expect(Workplace.chipText(workRoot: root, projectRoot: root, current: nil, worktrees: listed, expected: nil) == "no branch")
        // Set to dev, but the switch was refused: the folder is still on main, and the chip says so.
        #expect(Workplace.chipText(workRoot: root, projectRoot: root, current: "main", worktrees: listed, expected: "dev") == "main")
        // Set to a worktree that couldn't be made: the flow still works in the folder.
        #expect(Workplace.chipText(workRoot: root, projectRoot: root, current: "main", worktrees: listed, expected: "qb/y") == "main")
        #expect(Workplace.chipText(workRoot: worktree, projectRoot: root, current: "main", worktrees: listed, expected: nil) == "qb/x · worktree")
        #expect(Workplace.chipText(workRoot: worktree, projectRoot: root, current: "main", worktrees: [], expected: "qb/x") == "qb/x · worktree")
        #expect(Workplace.chipText(workRoot: URL(fileURLWithPath: "/Users/k/acme/"), projectRoot: root, current: "dev", worktrees: listed, expected: nil) == "dev")
        #expect(Workplace.worktree("qb/x", from: nil).summary(project: "acme", current: "main") == "Works in a worktree of acme on qb/x.")
        #expect(Workplace.folder(on: "dev").summary(project: "acme", current: "main") == "Works in acme, switched to dev.")
    }

    // MARK: The form's choices

    private func choice(_ saved: Workplace?, current: String? = "main", branches: [String] = ["main", "dev", "qb/x", "cursor/a"],
                        worktrees: [Workplace.Worktree]? = nil) -> WorkplaceChoice {
        let listed = worktrees ?? [.init(path: root.path, branch: current), .init(path: "/Users/k/acme/.claude/worktrees/a", branch: "cursor/a")]
        return WorkplaceChoice(saved: saved, current: current, branches: branches, defaultBranch: "main", worktrees: listed,
                               projectRoot: root, projectName: "acme", flowName: "Fix login", flowID: "f1")
    }

    @Test func theFormStartsFromWhatTheFlowIsSetTo() {
        let none = choice(nil)
        #expect(none.mode == .folder && none.newName == "qb/fix-login" && none.base == "main")
        #expect(choice(.asItIs).mode == .folder)
        #expect(choice(.folder(on: "dev")).mode == .folder)

        let existing = choice(.worktree("qb/x", from: "dev"))
        #expect(existing.mode == .existingBranch && existing.existing == "qb/x")
        #expect(existing.workplace == .worktree("qb/x", from: nil))

        let gone = choice(.worktree("qb/new", from: "dev"))
        #expect(gone.mode == .newBranch && gone.newName == "qb/new" && gone.base == "dev")
        #expect(gone.workplace == .worktree("qb/new", from: "dev"))
        #expect(choice(.worktree("qb/new", from: nil)).base == "main")
    }

    @Test func theFolderNoLongerSwitchesBranchesAndSaysSoForOldSettings() {
        let old = choice(.folder(on: "dev"))
        #expect(old.legacyNote == "This flow was set to switch your folder to dev. Applying here leaves your folder on the branch it's on.")
        #expect(old.notes.contains(old.legacyNote!))
        #expect(old.workplace == .folder(on: nil))
        #expect(choice(.asItIs).legacyNote == nil && choice(nil).legacyNote == nil)
        #expect(choice(nil).notes == ["Agents work in acme itself, on whatever branch it has checked out (now main). Your own edits there show up for them too."])
        #expect(choice(nil).workplace == .folder(on: nil) && choice(nil).canApply)
    }

    @Test func aDetachedHeadIsExplainedPlainly() {
        let detached = choice(nil, current: nil)
        #expect(detached.notes.first?.contains("no branch checked out (a detached HEAD)") == true)
        #expect(detached.existingChoices.allSatisfy { $0.disabledReason == nil })
    }

    @Test func aNewBranchCantTakeTheNameOfOneThatExists() {
        var form = choice(nil)
        form.mode = .newBranch
        #expect(form.problem == nil && form.workplace == .worktree("qb/fix-login", from: "main"))
        form.newName = " dev "
        #expect(form.problem == "A branch called dev already exists. Choose it under Existing branch.")
        form.newName = "bad name"
        #expect(form.problem == Workplace.problem(branchName: "bad name"))
        form.newName = "qb/ok"; form.base = "nope"
        #expect(form.problem != nil && !form.canApply)
        form.base = "cursor/a"
        #expect(form.canApply)
    }

    @Test func theFoldersBranchCantBeAnExistingWorktreeBranch() {
        var form = choice(nil)
        form.mode = .existingBranch
        #expect(form.problem == "Choose a branch.")
        let current = form.existingChoices.first { $0.branch == "main" }
        #expect(current?.disabledReason == "Checked out in your folder" && current?.isPinned == true)
        // A saved setting whose branch has since been checked out in the folder can't be applied.
        let stale = choice(.worktree("dev", from: nil), current: "dev")
        #expect(stale.mode == .existingBranch && stale.existing == "dev")
        #expect(stale.problem == "Checked out in your folder" && !stale.canApply)
        form.existing = "dev"
        #expect(form.canApply && form.workplace == .worktree("dev", from: nil))
        form.existing = "gone"
        #expect(form.problem == "gone isn't a branch any more. Choose another.")
    }

    @Test func aBranchOpenInAnotherWorktreeIsNotedAndCanBePicked() {
        var form = choice(nil)
        form.mode = .existingBranch
        let open = form.existingChoices.first { $0.branch == "cursor/a" }
        #expect(open?.note == "Has a worktree: the flow works in it" && open?.disabledReason == nil)
        form.existing = "cursor/a"
        #expect(form.canApply && form.notes == ["A worktree on cursor/a is already there, so the flow works in it."])
        form.existing = "dev"
        #expect(form.notes == ["Adds a worktree of acme on dev. Your folder stays as it is."])
        // Any local branch, including one open elsewhere, can start a new branch.
        #expect(form.baseChoices.map(\.branch).contains("cursor/a"))
    }

    @Test func branchesWhoseFoldersWouldClashGetDistinctPaths() {
        let have = [Workplace.Worktree(path: "/Users/k/acme/.queenbee/worktrees/feature-foo", branch: "feature/foo")]
        let plan = Workplace.worktreePlan(branch: "feature-foo", base: "main", root: root, worktrees: have, branches: ["main", "feature/foo"])
        let usual = "/Users/k/acme/.queenbee/worktrees/feature-foo"
        #expect(plan.path != usual && plan.path.hasPrefix(usual + "-"))
        #expect(plan == Workplace.worktreePlan(branch: "feature-foo", base: "main", root: root, worktrees: have, branches: ["main", "feature/foo"]))
        // The branch that has the folder keeps it.
        #expect(Workplace.worktreePlan(branch: "feature/foo", base: "main", root: root, worktrees: have, branches: ["feature/foo"]) == .reuse(path: usual))
        // A folder already on disk is not built over.
        let onDisk = Workplace.worktreePlan(branch: "dev", base: "main", root: root, worktrees: [], branches: ["dev"], isOccupied: { $0 == "/Users/k/acme/.queenbee/worktrees/dev" })
        #expect(onDisk.path.hasPrefix("/Users/k/acme/.queenbee/worktrees/dev-") && onDisk.path != "/Users/k/acme/.queenbee/worktrees/dev")
        // Nothing in the way: the usual folder.
        #expect(Workplace.worktreePlan(branch: "dev", base: "main", root: root, worktrees: [], branches: ["dev"]).path == "/Users/k/acme/.queenbee/worktrees/dev")
    }

    @Test func theNextFreeFolderIsChosenInOrderAndTheSameWayEachTime() {
        let dir = "/Users/k/acme/.queenbee/worktrees/"
        let tag = Workplace.shortHash("feature-foo")
        func path(_ taken: Set<String>, listed: [Workplace.Worktree] = []) -> String {
            Workplace.newWorktreePath(branch: "feature-foo", root: root, worktrees: listed, isOccupied: { taken.contains($0) })
        }
        #expect(path([]) == dir + "feature-foo")
        #expect(path([dir + "feature-foo"]) == dir + "feature-foo-" + tag)
        #expect(path([dir + "feature-foo", dir + "feature-foo-" + tag]) == dir + "feature-foo-" + tag + "-2")
        // A listed worktree of any branch holds its folder; a folder left on disk does too.
        let listed = [Workplace.Worktree(path: dir + "feature-foo", branch: "other"), .init(path: dir + "feature-foo-" + tag, branch: nil)]
        #expect(path([], listed: listed) == dir + "feature-foo-" + tag + "-2")
        #expect(path([dir + "feature-foo-" + tag + "-2"], listed: listed) == dir + "feature-foo-" + tag + "-3")
        #expect(path([dir + "feature-foo"]) == path([dir + "feature-foo"]))
        // Everything taken: the last candidate, not a crash.
        #expect(Workplace.newWorktreePath(branch: "x", root: root, worktrees: [], isOccupied: { _ in true }).hasSuffix("-50"))
    }

    @Test func aBranchCheckedOutInTheFolderCantHaveAWorktreeToo() {
        let listed = [Workplace.Worktree(path: "/Users/k/acme/", branch: "main"), .init(path: "/elsewhere", branch: "dev")]
        let message = Workplace.worktreeProblem(branch: "main", root: root, worktrees: listed)
        #expect(message == "main is checked out in your folder, so it can't have a worktree too. Switch your folder to another branch, or choose another branch for the flow.")
        #expect(Workplace.worktreeProblem(branch: "dev", root: root, worktrees: listed) == nil)
        #expect(Workplace.worktreeProblem(branch: "new", root: root, worktrees: listed) == nil)
    }

    @Test func aSelectedBranchThatIsGoneOrNowInTheFolderBlocksApply() {
        var form = choice(nil)
        form.mode = .existingBranch
        form.existing = "dev"
        #expect(form.canApply)
        let gone = form.revalidated(current: "main", branches: ["main", "qb/x"], defaultBranch: "main", worktrees: form.worktrees)
        #expect(gone.problem == "dev isn't a branch any more. Choose another." && gone.existing == "dev")
        let taken = form.revalidated(current: "dev", branches: form.branches, defaultBranch: "main", worktrees: form.worktrees)
        #expect(taken.problem == "Checked out in your folder")
        form.mode = .newBranch; form.newName = "qb/ok"; form.base = "dev"
        let noBase = form.revalidated(current: "main", branches: ["main"], defaultBranch: "main", worktrees: form.worktrees)
        #expect(noBase.problem != nil && noBase.newName == "qb/ok")
    }
}
