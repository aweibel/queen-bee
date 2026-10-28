import QueenBeeCore
import QueenBeeDesign
import SwiftUI

/// The branch chip in the flow's header: the branch the flow works on, and "worktree" when it
/// works in one. Clicking it shows where the flow works, and changes it.
struct WorkplaceChip: View {
    let controller: FlowController
    let text: String
    @State private var showsForm = false

    var body: some View {
        Button { showsForm.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.textMuted.color)
                // A long branch name is cut short in the middle rather than taking over the header.
                Text(text).textRole(.mono).lineLimit(1).truncationMode(.middle).frame(maxWidth: 260)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.textFaint.color)
            }
            .fixedSize()
        }
        .buttonStyle(.ds(.ghost))
        .help("Where this flow works. Click to check or change it.")
        .popover(isPresented: $showsForm, arrowEdge: .bottom) {
            WorkplaceForm(controller: controller, isFirstRun: false) { showsForm = false }
                // A popover's glass takes its tint from what is behind it, which can be a dark terminal while the
                // app is light, leaving the form's ink on a dark ground. The app's own surface keeps them apart.
                .presentationBackground(Theme.surface.ui)
        }
    }
}

/// Where a flow works: the project folder on a branch, or a worktree on a branch of its own. The same form
/// asks the first time a flow opens, and opens from the header's branch chip after that.
struct WorkplaceForm: View {
    let controller: FlowController
    /// The question asked when the flow first opens, rather than the chip's popover.
    let isFirstRun: Bool
    let done: () -> Void

    /// What the form shows and decides. Nil until the repository has been read.
    @State private var model: WorkplaceChoice?
    @State private var isApplying = false

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
        if let model {
            let isFolder = model.mode == .folder
            Picker("", selection: Binding(get: { model.kind }, set: { self.model?.kind = $0 })) {
                Text("This folder").tag(Workplace.Kind.folder)
                Text("A worktree").tag(Workplace.Kind.worktree)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if !isFolder {
                Picker("", selection: Binding(get: { model.mode }, set: { self.model?.mode = $0 })) {
                    Text("New branch").tag(WorkplaceChoice.Mode.newBranch)
                    Text("Existing branch").tag(WorkplaceChoice.Mode.existingBranch)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch model.mode {
            case .folder:
                EmptyView()
            case .newBranch:
                row("New branch") {
                    TextField("qb/my-flow", text: Binding(get: { model.newName }, set: { self.model?.newName = $0 }))
                        .textFieldStyle(.plain)
                        .font(.dsSans(Theme.Size.body, .medium))
                        .fieldBox()
                }
                row("Starting from") {
                    SearchPicker(model.baseChoices.map { SearchPickerItem(id: $0.branch, title: $0.branch, isPinned: $0.isPinned) },
                                 selection: model.base, placeholder: "Choose a branch", prompt: "Search local branches") {
                        self.model?.base = $0
                    }
                }
            case .existingBranch:
                row("Branch") {
                    SearchPicker(model.existingChoices.map {
                        SearchPickerItem(id: $0.branch, title: $0.branch, note: $0.note, disabledReason: $0.disabledReason, isPinned: $0.isPinned)
                    }, selection: model.existing, placeholder: "Choose a local branch", prompt: "Search local branches") {
                        self.model?.existing = $0
                    }
                }
            }
            ForEach(model.notes, id: \.self) { note($0) }
            if let problem = model.problem {
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
                Button(isFirstRun ? "Use this" : "Apply") { apply(model) }
                    .buttonStyle(.panel(.filled))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply || isApplying || (!isFirstRun && (controller.isRunning || controller.isStartingRun)))
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title)
                .font(.dsSans(Theme.Size.body, .medium))
                .frame(width: 88, alignment: .leading)
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

    /// Starts from what the flow is set to now, else from the project folder as it is.
    private func fill() {
        guard let git = controller.git else { return }
        model = WorkplaceChoice(saved: controller.workplaceSetting.workplace, current: git.current, branches: git.branches,
                                defaultBranch: git.defaultBranch, worktrees: git.worktrees, projectRoot: controller.project.root,
                                projectName: controller.project.name, flowName: controller.flow.name, flowID: controller.flow.id)
    }

    private func apply(_ model: WorkplaceChoice) {
        let chosen = model.workplace
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
