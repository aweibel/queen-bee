import Foundation
import QueenBeeCore
import Subprocess
import System

/// The few things Queen Bee asks git about a project, and the two it asks git to do: switch the project
/// folder to a branch, and add a worktree. Every name reaches git after "--" or as a value it can't take
/// for an option, and none is typed by anything but the person.
nonisolated enum Git {
    /// What the project's repository looks like right now.
    nonisolated struct Info: Equatable, Sendable {
        /// The branch the project folder is on, or nil when it has none checked out.
        var current: String?
        var branches: [String]
        /// The branch new worktrees start from unless the person picks another: the remote's default, else
        /// main or master, else the current branch.
        var defaultBranch: String
        var worktrees: [Workplace.Worktree]
    }

    nonisolated static let executable = "/usr/bin/git"
    nonisolated static let readLimit = 4_000_000
    /// git asks nothing of anyone here: no password, no editor.
    nonisolated private static var quiet: [Environment.Key: String] {
        var env: [Environment.Key: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment { if let key = Environment.Key(rawValue: k) { env[key] = v } }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["LC_ALL"] = "C"
        return env
    }

    /// Runs git in `folder`. Whether it exited with 0, and what it printed.
    nonisolated static func run(_ arguments: [String], in folder: URL) async -> (ok: Bool, output: String, error: String) {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return (false, "", "git isn't installed on this Mac.") }
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)), arguments: Arguments(arguments), environment: .custom(quiet),
                workingDirectory: FilePath(folder.path), input: .none,
                output: .string(limit: readLimit), error: .string(limit: readLimit))
            return (result.terminationStatus.isSuccess,
                    (result.standardOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    (result.standardError ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (false, "", "git couldn't be started: \(error.localizedDescription)")
        }
    }

    /// The repository at `root`, or nil when the project folder isn't in one.
    nonisolated static func info(at root: URL) async -> Info? {
        guard await run(["rev-parse", "--is-inside-work-tree"], in: root).output == "true" else { return nil }
        let current = await run(["branch", "--show-current"], in: root).output
        let branches = await run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root).output
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let worktrees = Workplace.parseWorktrees(await run(["worktree", "list", "--porcelain"], in: root).output)
        let remote = await run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: root)
        var preferred: String?
        if remote.ok, remote.output.hasPrefix("origin/") {
            let name = String(remote.output.dropFirst("origin/".count))
            if branches.contains(name) { preferred = name }
        }
        let checkedOut: String? = current.isEmpty ? nil : current
        let usual = ["main", "master"].first { branches.contains($0) }
        let fallback = preferred ?? usual ?? checkedOut ?? branches.first ?? "main"
        return Info(current: checkedOut, branches: branches, defaultBranch: fallback, worktrees: worktrees)
    }

    /// Files git tracks that have changes not yet committed, which switching branch could carry along or refuse over.
    nonisolated static func hasUncommittedChanges(at root: URL) async -> Bool {
        let status = await run(["status", "--porcelain", "--untracked-files=no"], in: root)
        return !status.ok || !status.output.isEmpty
    }

    /// Switches the project folder to `branch`. Nil when it worked, else what git said.
    nonisolated static func switchBranch(to branch: String, at root: URL) async -> String? {
        let done = await run(["switch", "--no-guess", branch], in: root)
        return done.ok ? nil : (done.error.isEmpty ? "git couldn't switch to \(branch)." : done.error)
    }

    /// Carries out a worktree plan. Nil when it worked, else what git said.
    nonisolated static func make(_ plan: Workplace.WorktreePlan, at root: URL) async -> String? {
        guard let arguments = plan.gitArguments else { return nil }
        // Kept out of git even in a project that has chosen to commit its .queenbee folder.
        let folder = root.appendingPathComponent(Workplace.worktreesFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try? Data("*\n".utf8).write(to: ignore) }
        let done = await run(arguments, in: root)
        return done.ok ? nil : (done.error.isEmpty ? "git couldn't make the worktree." : done.error)
    }
}
