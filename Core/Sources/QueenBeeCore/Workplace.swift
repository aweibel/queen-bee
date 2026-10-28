import Foundation

/// Where a flow's agents, scripts and saved answers work: the project folder on a branch, or a
/// git worktree of the project on a branch of its own. It belongs to the whole flow, never to one
/// run, and a sub-flow works wherever the flow at the top of its chain does.
public struct Workplace: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case folder, worktree }

    public var kind: Kind
    /// For `.folder`, the branch the project folder is switched to, or nil to leave it on whatever
    /// branch it is on. For `.worktree`, the worktree's own branch.
    public var branch: String?
    /// For `.worktree`, the branch a new branch starts from when `branch` doesn't exist yet. Nil for
    /// the project's default branch.
    public var base: String?

    public init(kind: Kind, branch: String? = nil, base: String? = nil) {
        self.kind = kind; self.branch = branch; self.base = base
    }

    /// The project folder, on whatever branch it is on: what a flow with no setting does.
    public static let asItIs = Workplace(kind: .folder)

    public static func folder(on branch: String?) -> Workplace { Workplace(kind: .folder, branch: branch) }
    public static func worktree(_ branch: String, from base: String?) -> Workplace {
        Workplace(kind: .worktree, branch: branch, base: base)
    }

    /// Where worktrees live: inside the project's own `.queenbee` folder, which git ignores.
    public static let worktreesFolder = ".queenbee/worktrees"

    // MARK: Branch names

    /// Why `name` can't be a branch, or nil if it can. Stricter than git, so nothing typed here
    /// can reach git as an option or a range.
    public static func problem(branchName name: String) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give the branch a name." }
        if name.hasPrefix("-") { return "A branch name can't start with a dash." }
        if name.contains(where: { $0.isWhitespace }) { return "A branch name can't have spaces in it." }
        if name.contains("..") || name.contains("@{") || name == "@" { return "That isn't a name git allows for a branch." }
        if name.contains(where: { ch in "~^:?*[\\".contains(ch) || ch.asciiValue.map { $0 < 32 || $0 == 127 } == true }) {
            return "A branch name can't have ~ ^ : ? * [ or \\ in it."
        }
        if name.hasPrefix("/") || name.hasSuffix("/") || name.contains("//") || name.hasSuffix(".") || name.hasSuffix(".lock") {
            return "That isn't a name git allows for a branch."
        }
        if name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return "No part of a branch name can start with a dot." }
        return nil
    }

    /// The branch a new worktree for a flow is offered: "qb/" and the flow's name, lower case with dashes.
    public static func suggestedBranch(forFlowNamed name: String, id: String) -> String {
        var slug = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { slug.append(ch) } else if slug.last != "-" { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "qb/" + (slug.isEmpty ? id : String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")))
    }

    /// The folder a worktree for `branch` is made in: one folder per branch, slashes turned to dashes.
    public static func worktreeFolder(for branch: String, in root: URL) -> URL {
        let name = branch.replacingOccurrences(of: "/", with: "-")
        return root.appendingPathComponent(worktreesFolder, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Inheritance

    /// The setting a flow works by, and the flow it comes from when that isn't the flow itself. A flow
    /// that another flow runs takes the setting of the first flow at the top of its chains that has one;
    /// a flow nothing runs has its own.
    public static func effective(for id: String, in flows: [Flow], nesting: Nesting) -> (workplace: Workplace?, from: String?) {
        guard !nesting.outerFlows(of: id).isEmpty else { return (flows.first { $0.id == id }?.workplace, nil) }
        let tops = nesting.topFlows(of: id).filter { $0 != id }
        for top in tops {
            if let set = flows.first(where: { $0.id == top })?.workplace { return (set, top) }
        }
        return (nil, tops.first)
    }

    // MARK: Folders

    /// The folder a card's session runs in. A card with no folder of its own works in the flow's
    /// place; a folder inside the project is moved to the same spot in the worktree; a relative
    /// folder is taken from the flow's place; any other folder is left as it is.
    public static func folder(forCard cwd: String?, projectRoot: URL, workRoot: URL) -> String {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return workRoot.path }
        // In the project folder itself, a card's folder means what it always has.
        guard projectRoot.standardizedFileURL.path != workRoot.standardizedFileURL.path else { return cwd }
        if cwd.hasPrefix("~") { return cwd }
        guard cwd.hasPrefix("/") else { return workRoot.appendingPathComponent(cwd).standardizedFileURL.path }
        let root = projectRoot.standardizedFileURL.path
        let own = URL(fileURLWithPath: cwd).standardizedFileURL.path
        if own == root { return workRoot.path }
        if own.hasPrefix(root + "/") { return workRoot.appendingPathComponent(String(own.dropFirst(root.count + 1))).path }
        return cwd
    }

    // MARK: Worktrees

    /// What `git worktree list --porcelain` says of each worktree: where it is and its branch, if it
    /// has one checked out.
    public struct Worktree: Equatable, Sendable {
        public var path: String
        public var branch: String?
        public init(path: String, branch: String?) { self.path = path; self.branch = branch }
    }

    public static func parseWorktrees(_ porcelain: String) -> [Worktree] {
        var found: [Worktree] = [], current: Worktree?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let current { found.append(current) }
                current = Worktree(path: String(line.dropFirst("worktree ".count)), branch: nil)
            } else if line.hasPrefix("branch "), current != nil {
                let ref = line.dropFirst("branch ".count)
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
            } else if line.isEmpty, let done = current {
                found.append(done); current = nil
            }
        }
        if let current { found.append(current) }
        return found
    }

    /// How to get a worktree on `branch`: use one that already has it, check the branch out in a new
    /// one, or make the branch from `base` in a new one.
    public enum WorktreePlan: Equatable, Sendable {
        case reuse(path: String)
        case add(path: String, branch: String)
        case create(path: String, branch: String, base: String)

        public var path: String {
            switch self { case .reuse(let p), .add(let p, _), .create(let p, _, _): p }
        }
        /// The git arguments that make it, or nil when there is nothing to make. "--" keeps every name
        /// out of git's options.
        public var gitArguments: [String]? {
            switch self {
            case .reuse: nil
            case .add(let path, let branch): ["worktree", "add", "--", path, branch]
            case .create(let path, let branch, let base): ["worktree", "add", "-b", branch, "--", path, base]
            }
        }
    }

    /// The branches checked out in a worktree other than the project folder. git keeps a branch in one
    /// place at a time, so the project folder can't be switched to any of these.
    public static func branchesOpenElsewhere(worktrees: [Worktree], projectRoot: URL) -> [String] {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return worktrees.filter { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path != root }
            .compactMap(\.branch)
    }

    /// Why some branches aren't offered for the project folder, or nil when none are left out. One is named; a
    /// repository can have dozens open in worktrees, so more are counted.
    public static func notListedNote(_ branches: [String]) -> String? {
        guard let first = branches.first else { return nil }
        if branches.count == 1 {
            return "\(first) isn't listed: it's open in a worktree, and git lets a branch be open in only one place. To use it, choose A worktree."
        }
        return "\(branches.count) branches aren't listed: they're open in worktrees, and git lets a branch be open in only one place. To use one, choose A worktree."
    }

    /// A short, stable tag for a branch name (FNV-1a), so two branches whose folders would clash each get their own.
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// Where a new worktree for `branch` goes. Usually `worktreeFolder`, but `feature/foo` and `feature-foo` share
    /// that folder, so when a listed worktree on another branch already has it, or `isOccupied` says something is
    /// there, the branch's own tag is added to the name.
    public static func newWorktreePath(branch: String, root: URL, worktrees: [Worktree], isOccupied: (String) -> Bool = { _ in false }) -> String {
        let usual = worktreeFolder(for: branch, in: root)
        func same(_ a: String, _ b: String) -> Bool {
            URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
                == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let taken = worktrees.contains { $0.branch != branch && same($0.path, usual.path) } || isOccupied(usual.path)
        guard taken else { return usual.path }
        return usual.path + "-" + shortHash(branch)
    }

    /// `isOccupied` is asked about the usual folder for a new worktree: pass a check that the path exists on disk.
    public static func worktreePlan(branch: String, base: String, root: URL, worktrees: [Worktree], branches: [String],
                                    isOccupied: (String) -> Bool = { _ in false }) -> WorktreePlan {
        if let have = worktrees.first(where: { $0.branch == branch }) { return .reuse(path: have.path) }
        let path = newWorktreePath(branch: branch, root: root, worktrees: worktrees, isOccupied: isOccupied)
        return branches.contains(branch) ? .add(path: path, branch: branch) : .create(path: path, branch: branch, base: base)
    }

    // MARK: Showing it

    /// The words in the header's branch chip: where the flow works now, not what it is set to. The two differ
    /// while a switch is refused, or after the folder was switched by hand. `current` is the branch the
    /// project folder is on; `expected` names a worktree git hasn't listed yet.
    public static func chipText(workRoot: URL, projectRoot: URL, current: String?, worktrees: [Worktree], expected: String?) -> String {
        let here = workRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if here == projectRoot.resolvingSymlinksInPath().standardizedFileURL.path { return current ?? "no branch" }
        let listed = worktrees.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == here }
        return "\(listed?.branch ?? expected ?? "no branch") · worktree"
    }

    /// One sentence for the flow's log and the settings: where the flow works.
    public func summary(project: String, current: String?) -> String {
        switch kind {
        case .folder:
            if let branch { return "Works in \(project), switched to \(branch)." }
            return "Works in \(project), on whatever branch it is on" + (current.map { " (now \($0))" } ?? "") + "."
        case .worktree:
            return "Works in a worktree of \(project) on \(branch ?? "its own branch")" + (base.map { ", made from \($0)" } ?? "") + "."
        }
    }
}

/// What the "Where this flow works" form shows and decides, apart from how it looks: the choices, the notes under
/// them, what is wrong with the inputs, and the setting Apply would save. The facts about the repository are
/// plain values so this can be tested without git.
public struct WorkplaceChoice: Equatable, Sendable {
    public enum Mode: Equatable, Sendable { case folder, newBranch, existingBranch }

    /// One local branch offered under "Existing branch".
    public struct ExistingBranch: Equatable, Sendable, Identifiable {
        public var id: String { branch }
        public var branch: String
        public var note: String?
        public var disabledReason: String?
        public var isPinned: Bool
    }

    /// One local branch offered as the start of a new branch.
    public struct Base: Equatable, Sendable, Identifiable {
        public var id: String { branch }
        public var branch: String
        public var isPinned: Bool
    }

    // The repository.
    public let projectName: String
    public let projectRoot: URL
    /// The branch the project folder is on, or nil at a detached HEAD.
    public let current: String?
    /// Local branches only.
    public let branches: [String]
    public let defaultBranch: String
    public let worktrees: [Workplace.Worktree]
    /// A flow set to switch the project folder to this branch, from before the folder stopped switching.
    public let legacyFolderBranch: String?

    // What the person has chosen.
    public var mode: Mode
    public var newName: String
    public var base: String
    public var existing: String?

    public init(saved: Workplace?, current: String?, branches: [String], defaultBranch: String, worktrees: [Workplace.Worktree],
                projectRoot: URL, projectName: String, flowName: String, flowID: String) {
        self.projectName = projectName; self.projectRoot = projectRoot
        self.current = current; self.branches = branches; self.defaultBranch = defaultBranch; self.worktrees = worktrees
        legacyFolderBranch = saved?.kind == .folder ? saved?.branch : nil
        mode = .folder
        newName = Workplace.suggestedBranch(forFlowNamed: flowName, id: flowID)
        base = defaultBranch
        existing = nil
        if saved?.kind == .worktree, let branch = saved?.branch {
            if branches.contains(branch) {
                mode = .existingBranch
                existing = branch
            } else {
                mode = .newBranch
                newName = branch
                base = saved?.base ?? defaultBranch
            }
        }
    }

    /// The outer choice: the folder or a worktree.
    public var kind: Workplace.Kind {
        get { mode == .folder ? .folder : .worktree }
        set { mode = newValue == .folder ? .folder : (mode == .folder ? .newBranch : mode) }
    }

    public var trimmedName: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Choices

    private var openElsewhere: Set<String> {
        Set(Workplace.branchesOpenElsewhere(worktrees: worktrees, projectRoot: projectRoot))
    }

    public static let inYourFolder = "Checked out in your folder"
    public static let hasWorktreeNote = "Has a worktree: the flow works in it"

    /// Why `branch` can't be the flow's worktree branch, or nil.
    public func disabledReason(forExisting branch: String) -> String? {
        branch == current ? Self.inYourFolder : nil
    }

    /// Every local branch, for "Existing branch".
    public var existingChoices: [ExistingBranch] {
        branches.map { name in
            ExistingBranch(branch: name,
                           note: openElsewhere.contains(name) ? Self.hasWorktreeNote : nil,
                           disabledReason: disabledReason(forExisting: name),
                           isPinned: name == current || name == defaultBranch)
        }
    }

    /// Every local branch, for "Starting from". Any will do, even one open in a worktree.
    public var baseChoices: [Base] {
        branches.map { Base(branch: $0, isPinned: $0 == current || $0 == defaultBranch) }
    }

    // MARK: Words

    /// Notes about where the person's saved setting differs from what Apply will save.
    public var legacyNote: String? {
        guard mode == .folder, let legacyFolderBranch else { return nil }
        return "This flow was set to switch your folder to \(legacyFolderBranch). Applying here leaves your folder on the branch it's on."
    }

    /// What the choice means, in plain words, to show under it.
    public var notes: [String] {
        switch mode {
        case .folder:
            var found: [String] = []
            if let current {
                found.append("Agents work in \(projectName) itself, on whatever branch it has checked out (now \(current)). Your own edits there show up for them too.")
            } else {
                found.append("Agents work in \(projectName) itself, which is at a commit with no branch checked out (a detached HEAD). Your own edits there show up for them too.")
            }
            if let legacyNote { found.append(legacyNote) }
            return found
        case .newBranch:
            return ["Makes the new branch \(trimmedName.isEmpty ? "named above" : trimmedName) from \(base) in a new worktree of \(projectName). Your folder stays as it is."]
        case .existingBranch:
            guard let existing else { return [] }
            if worktrees.contains(where: { $0.branch == existing }) {
                return ["A worktree on \(existing) is already there, so the flow works in it."]
            }
            return ["Adds a worktree of \(projectName) on \(existing). Your folder stays as it is."]
        }
    }

    // MARK: Checking

    /// What is wrong with the inputs, or nil when Apply can go ahead. The selected existing branch is checked
    /// here on its own, whatever the picker shows.
    public var problem: String? {
        switch mode {
        case .folder:
            return nil
        case .newBranch:
            if let bad = Workplace.problem(branchName: trimmedName) { return bad }
            if branches.contains(trimmedName) {
                return "A branch called \(trimmedName) already exists. Choose it under Existing branch."
            }
            if !branches.contains(base) { return "\(base) isn't a local branch. Choose one to start from." }
            return nil
        case .existingBranch:
            guard let existing else { return "Choose a branch." }
            if !branches.contains(existing) { return "\(existing) isn't a local branch." }
            return disabledReason(forExisting: existing)
        }
    }

    public var canApply: Bool { problem == nil }

    /// The setting Apply saves. The folder is never switched, so it is always left on its branch.
    public var workplace: Workplace {
        switch mode {
        case .folder: .folder(on: nil)
        case .newBranch: .worktree(trimmedName, from: base)
        case .existingBranch: .worktree(existing ?? "", from: nil)
        }
    }
}
