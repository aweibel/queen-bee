import SwiftUI

/// Project folders and their flows, in a panel that floats over the canvas's left edge.
/// Each flow's row says what it needs from you.
struct SidebarView: View {
    @State private var search = ""
    @State private var renaming: String?
    @State private var draftName = ""
    @State private var deleting: FlowController?
    private var services: AppServices { AppServices.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                TextField("Flows and cards", text: $search)
                    .textFieldStyle(.plain)
                    .font(.dsSans(Theme.Size.body))
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Theme.inkSecondary.ui)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(Theme.bar.ui)
            Rectangle().fill(Theme.hairline.ui).frame(height: 1)
            if !RemoteHost.shared.sessions.isEmpty {
                let controls = RemoteHost.shared.sessions.contains { $0.device.canControl }
                let names = RemoteHost.shared.sessions.map { $0.device.canControl ? "\($0.device.name) · can control" : $0.device.name }
                    .joined(separator: ", ")
                Label(names, systemImage: "ipad.and.iphone")
                    .font(.dsMono(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(controls ? "Connected to this Mac now. A device that can control can start and stop runs, answer approvals and type into sessions. You can turn that off, or remove a device, in Settings."
                          : "Connected to this Mac now. You can remove a device in Settings.")
                Rectangle().fill(Theme.hairline.ui).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let pinned = services.allFlows.filter { services.pinnedFlowIDs.contains($0.flow.id) && matches($0) }
                    if !pinned.isEmpty {
                        header("Pinned")
                        ForEach(pinned, id: \.flow.id) { row(for: $0) }
                    }
                    ForEach(services.projects, id: \.root) { project in
                        header(project.name) {
                            Button { project.newFlow() } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                                .buttonStyle(.plain)
                                .help("New flow in \(project.name)")
                        }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.root]) }
                            Button("Remove from This List") { services.removeProject(project) }
                        }
                        ForEach(nested(project), id: \.controller.flow.id) { entry in
                            row(for: entry.controller, outer: entry.outer)
                                .padding(.leading, CGFloat(entry.depth) * 14)
                        }
                        ForEach(project.unreadable, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: "exclamationmark.triangle")
                                .font(.dsMono(Theme.Size.caption))
                                .foregroundStyle(Theme.failInk.ui)
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.vertical, 4)
                                .help("Queen Bee can't read this file as a flow, so it has left it alone.")
                        }
                    }
                }
                .padding(Theme.Space.xs)
            }

            Rectangle().fill(Theme.hairline.ui).frame(height: 1)
            Button { WorkspaceView.pickProjectFolder() } label: {
                Label("Add Project Folder…", systemImage: "folder.badge.plus")
                    .font(.dsSans(Theme.Size.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink.ui)
            .padding(Theme.Space.s)
        }
        .confirmationDialog("Delete \"\(deleting?.flow.name ?? "")\"?",
                            isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Flow", role: .destructive) {
                if let deleting { deleting.project.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its agents are stopped and the flow is removed. What the agents said stays in Claude Code's history.")
        }
    }

    private func header(_ title: String) -> some View {
        header(title) { EmptyView() }
    }

    private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(.dsMono(Theme.Size.caption))
                .lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .foregroundStyle(Theme.inkSecondary.ui)
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
    }

    /// A flow matches a search by its own name or by the name of any card in it.
    private func matches(_ controller: FlowController) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return controller.flow.name.localizedCaseInsensitiveContains(query)
            || controller.flow.cards.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// A project's flows in order, with each sub-flow listed under the flow whose Flow card
    /// runs it. A sub-flow nothing uses any more is listed with the rest, so it isn't lost.
    private func nested(_ project: ProjectModel) -> [(controller: FlowController, depth: Int, outer: FlowController?)] {
        let all = project.controllers
        func inner(of controller: FlowController) -> [FlowController] { controller.innerFlows }
        let used = Set(all.flatMap(inner).map(\.flow.id))
        var listed: Set<String> = []
        var rows: [(FlowController, Int, FlowController?)] = []
        func add(_ controller: FlowController, _ depth: Int, _ outer: FlowController?) {
            guard listed.insert(controller.flow.id).inserted else { return }
            if matches(controller) { rows.append((controller, depth, outer)) }
            for child in inner(of: controller) where child.flow.isSubflow == true { add(child, depth + 1, controller) }
        }
        for controller in all where !(controller.flow.isSubflow == true && used.contains(controller.flow.id)) { add(controller, 0, nil) }
        for controller in all { add(controller, 0, nil) }
        return rows
    }

    @ViewBuilder
    private func row(for controller: FlowController, outer: FlowController? = nil) -> some View {
        let id = controller.flow.id
        let selected = services.selectedFlowID == id
        FlowRow(isSelected: selected) {
            if renaming == id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        controller.rename(to: draftName)
                        renaming = nil
                    }
            } else {
                if controller.flow.isSubflow == true {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.inkSecondary.ui)
                }
                Text(controller.flow.name).lineLimit(1)
                Spacer(minLength: 4)
                activity(of: controller)
            }
        }
        .onTapGesture {
            // A sub-flow picked here is entered from the flow it sits under, so the way back shows.
            if let outer {
                services.enter(controller, from: outer)
                controller.showWholeFlowSoon()
            } else {
                services.selectedFlowID = id
            }
        }
        .contextMenu {
            Button("Rename") { draftName = controller.flow.name; renaming = id }
            Button(services.pinnedFlowIDs.contains(id) ? "Unpin" : "Pin") { services.togglePin(id) }
            Button("Stop Its Agents") { controller.shutDown() }
            Divider()
            Button("Delete…", role: .destructive) { deleting = controller }
        }
    }

    @ViewBuilder
    private func activity(of controller: FlowController) -> some View {
        switch controller.activity {
        case .needsYou: Badge(text: "needs you", tone: .live)
        case .running: Badge(text: "running", tone: .live)
        case .failed: Badge(text: "stopped", tone: .fail)
        case .quiet: EmptyView()
        }
    }
}

/// One flow in the list: tinted under the pointer, marked with an ink rule when it is the one on the canvas.
private struct FlowRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(isSelected ? Theme.ink.ui : .clear)
                .frame(width: 2, height: 14)
            content
        }
        .font(.dsMono(Theme.Size.body, isSelected ? .medium : .regular))
        .foregroundStyle(Theme.ink.ui)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.bar.ui : isHovered ? Theme.barHover.ui.opacity(0.6) : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.quick, value: isHovered)
    }
}
