import QueenBeeCore
import SwiftUI

/// The chip after the project's name in the title bar: the branch the flow works on, and "worktree" when it
/// works in one. Clicking it shows where the flow works, and changes it.
struct WorkplaceChip: View {
    let controller: FlowController
    let text: String
    @State private var showsForm = false

    var body: some View {
        Button { showsForm.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                Text(text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .font(.dsMono(Theme.Size.caption, .medium))
            .foregroundStyle(Theme.select.ui)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Theme.select.ui.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
            // Its whole width, always: the title bar measures its item once, and would otherwise cut the
            // branch short when the chip's words change after the flow opens.
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Where this flow works. Click to check or change it.")
        .popover(isPresented: $showsForm, arrowEdge: .bottom) {
            WorkplaceForm(controller: controller, isFirstRun: false) { showsForm = false }
        }
    }
}

/// Where a flow works: the project folder on a branch, or a worktree on a branch of its own. The same form
/// asks the first time a flow opens, and opens from the title bar's chip after that.
struct WorkplaceForm: View {
    let controller: FlowController
    /// The question asked when the flow first opens, rather than the chip's popover.
    let isFirstRun: Bool
    let done: () -> Void

    @State private var kind = Workplace.Kind.folder
    /// The branch the project folder is switched to. Nil to leave it as it is.
    @State private var folderBranch: String?
    @State private var worktreeBranch = ""
    @State private var base = ""
    @State private var isApplying = false
    @State private var isReady = false

    var body: some View {
        let setting = controller.workplaceSetting
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isFirstRun ? "Where should this flow work?" : "Where this flow works")
                    .font(.dsSans(Theme.Size.title, .semibold))
                Text("\(controller.flow.name), in \(controller.project.name)")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            if let from = setting.from {
                inherited(from: from, setting: setting.workplace ?? .asItIs)
            } else if let git = controller.git {
                choices(git)
            } else {
                Text("\(controller.project.name) isn't a git repository, so the flow works in the folder itself.")
                    .font(.dsSans(Theme.Size.body))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
        .task {
            await controller.refreshGit()
            fill()
        }
    }

    private func inherited(from outer: FlowController, setting: Workplace) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(setting.summary(project: controller.project.name, current: controller.git?.current))
                .font(.dsSans(Theme.Size.body))
                .fixedSize(horizontal: false, vertical: true)
            Text("A sub-flow works wherever the flow that runs it does, so the setting is \(outer.flow.name)'s.")
                .font(.dsSans(Theme.Size.caption))
                .foregroundStyle(Theme.inkSecondary.ui)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Open \(outer.flow.name)") {
                    done()
                    AppServices.shared.selectedFlowID = outer.flow.id
                }
                .buttonStyle(.panel(.outline))
            }
        }
    }

    @ViewBuilder
    private func choices(_ git: Git.Info) -> some View {
        Picker("", selection: $kind) {
            Text("This folder").tag(Workplace.Kind.folder)
            Text("A worktree").tag(Workplace.Kind.worktree)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        switch kind {
        case .folder:
            row("Branch") {
                MenuField(options: folderOptions(git), selection: folderBranch) { folderBranch = $0 }
            }
            note("Agents work in \(controller.project.name) itself" + (folderBranch.map { ", switched to \($0)." } ?? ", on whatever branch it is on.")
                 + " Your own edits there show up for them too.")
            let elsewhere = openElsewhere(git)
            if !elsewhere.isEmpty {
                note("Not listed: \(elsewhere.joined(separator: ", ")). "
                     + (elsewhere.count == 1 ? "It's" : "They're")
                     + " open in a worktree, and git lets a branch be open in only one place. To use "
                     + (elsewhere.count == 1 ? "it" : "one") + ", choose A worktree.")
            }
        case .worktree:
            row("Branch") {
                TextField("qb/my-flow", text: $worktreeBranch)
                    .textFieldStyle(.plain)
                    .font(.dsMono(Theme.Size.body, .medium))
                    .fieldBox()
            }
            if !git.branches.contains(trimmed(worktreeBranch)) {
                row("Made from") {
                    MenuField(options: git.branches.map { (value: $0, label: $0) }, selection: base) { base = $0 }
                }
            }
            note(worktreeNote(git))
        }
        if let problem {
            Text(problem)
                .font(.dsSans(Theme.Size.caption))
                .foregroundStyle(Theme.failInk.ui)
                .fixedSize(horizontal: false, vertical: true)
        }
        if controller.isRunning && !isFirstRun {
            note("Stop the run to change where the flow works.")
        }
        HStack(spacing: Theme.Space.s) {
            Spacer()
            Button(isFirstRun ? "Not now" : "Cancel") {
                if isFirstRun { Task { await controller.answerWorkplaceQuestion(nil) } }
                done()
            }
            .buttonStyle(.panel(.quiet))
            .keyboardShortcut(.cancelAction)
            Button(isFirstRun ? "Use this" : "Apply") { apply() }
                .buttonStyle(.panel(.filled))
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady || problem != nil || isApplying || (!isFirstRun && (controller.isRunning || controller.isStartingRun)))
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(.dsSans(Theme.Size.body, .medium))
                .frame(width: 76, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.dsSans(Theme.Size.caption))
            .foregroundStyle(Theme.inkSecondary.ui)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func folderOptions(_ git: Git.Info) -> [(value: String?, label: String)] {
        let current = git.current.map { " (\($0))" } ?? ""
        let asItIs: [(value: String?, label: String)] = [(value: nil, label: "Leave as it is" + current)]
        let elsewhere = openElsewhere(git)
        return asItIs + git.branches.filter { !elsewhere.contains($0) }.map { (value: Optional($0), label: $0) }
    }

    /// Branches the project folder can't be switched to, because a worktree has them open.
    private func openElsewhere(_ git: Git.Info) -> [String] {
        Workplace.branchesOpenElsewhere(worktrees: git.worktrees, projectRoot: controller.project.root).filter { git.branches.contains($0) }
    }

    private func worktreeNote(_ git: Git.Info) -> String {
        let name = trimmed(worktreeBranch)
        if git.worktrees.contains(where: { $0.branch == name }) {
            return "A worktree on \(name) is already there, so the flow works in it."
        }
        if git.branches.contains(name) {
            return "A separate copy of \(controller.project.name) on \(name). Your folder stays as it is."
        }
        return "A separate copy of \(controller.project.name) on a new branch, \(name.isEmpty ? "named above" : name), made from \(base). Your folder stays as it is."
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var problem: String? {
        guard isReady, kind == .worktree else { return nil }
        return Workplace.problem(branchName: trimmed(worktreeBranch))
    }

    /// Starts from what the flow is set to now, else from the project folder as it is.
    private func fill() {
        let git = controller.git
        let now = controller.workplaceSetting.workplace
        kind = now?.kind ?? .folder
        folderBranch = now?.kind == .folder ? now?.branch : nil
        // A branch a worktree has opened since can't be offered, so the form starts from the folder as it is.
        if let branch = folderBranch, let git, openElsewhere(git).contains(branch) { folderBranch = nil }
        worktreeBranch = now?.kind == .worktree ? (now?.branch ?? "") : Workplace.suggestedBranch(forFlowNamed: controller.flow.name, id: controller.flow.id)
        base = now?.base ?? git?.defaultBranch ?? "main"
        isReady = true
    }

    private func apply() {
        let chosen: Workplace = kind == .folder
            ? .folder(on: folderBranch)
            : .worktree(trimmed(worktreeBranch), from: base)
        isApplying = true
        Task {
            if isFirstRun {
                await controller.answerWorkplaceQuestion(chosen)
            } else {
                await controller.setWorkplace(chosen)
            }
            isApplying = false
            done()
        }
    }
}
