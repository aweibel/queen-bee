import QueenBeeCore
import SwiftUI

/// The panel beside the canvas, for what the open flow's orchestrator and its runs have to say. On an iPhone
/// it comes up as a sheet of its own. The details of what is selected aren't one of its tabs: beside the
/// canvas they come up over it, as a page pushed on top, and on an iPhone in their own sheet.
struct InspectorPanel: View {
    @Environment(RemoteClient.self) private var client
    /// Up as a sheet over the canvas, as on an iPhone, and not beside it. Said by whoever puts it up: in the
    /// column beside the canvas the size class is compact too.
    var isSheet = false

    var body: some View {
        let panel = client.panel, tab = panel.page.tab
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TabStrip(selected: tab) { panel.show($0) }
                // A sheet needs its own way out. Beside the canvas, the bar's button hides the panel.
                if isSheet {
                    Button("Close") { client.closeSheet(.tabs) }.buttonStyle(.panel(.quiet))
                        .padding(.trailing, Theme.Space.xs)
                        .accessibilityHint("Closes the panel.")
                }
            }
            .frame(minHeight: Theme.Touch.target)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if !isSheet { panel.tabsHeight = $0 } }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { if !isSheet { panel.tabsTop = $0 } }
            // Clear of the handle a sheet is dragged by.
            .padding(.top, isSheet ? Theme.Space.m : 0)
            .background(Theme.bar.ui)
            Hairline()
            if isSheet { SheetRefusal() }
            if let run = client.canvas.viewedRun {
                EarlierRunNotice(run: run)
                    .padding(.horizontal, Theme.Space.l)
                    .background(Theme.barHover.ui)
                Hairline()
            }
            if tab.pages.count > 1 {
                PageSwitch(pages: tab.pages, counts: counts, selected: panel.page) { panel.show($0) }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.s)
                Hairline()
            }
            page(panel.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .dimmedWhileAway(client.state == .connected)
        }
        .background(Theme.surface.ui)
        .animation(Theme.Motion.standard, value: client.canvas.viewedRun?.id)
    }

    /// How many lines, answers and runs there are, beside the names of their pages, as on the Mac's tabs.
    private var counts: [PanelPage: Int] {
        guard let snapshot = client.mirror.snapshot else { return [:] }
        let run = RunOnShow(snapshot, viewed: client.canvas.viewedRun)
        return [.log: run.log.count, .output: run.results.count, .runs: snapshot.runs.count]
    }

    @ViewBuilder private func page(_ page: PanelPage) -> some View {
        if page == .orchestrator {
            OrchestratorPanel()
        } else if let snapshot = client.mirror.snapshot {
            let run = RunOnShow(snapshot, viewed: client.canvas.viewedRun)
            switch page {
            case .log: LogPage(lines: run.log, canClear: client.canClearLog && run.earlier == nil)
            case .output: OutputPage(flow: snapshot.flow, results: run.results)
            case .runs: RunsPage(snapshot: snapshot)
            case .cost: CostPage(sheet: CostSheet(snapshot, run: run, flows: client.openFlow?.project.flows ?? []), flowName: snapshot.flow.name)
            case .orchestrator: EmptyView()
            }
        } else {
            NothingOpen(text: nothingOpen(page))
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nothingOpen(_ page: PanelPage) -> String {
        switch page {
        case .orchestrator: "Open a flow to see the session that runs it."
        case .log: "Open a flow to see what its runs did, step by step."
        case .output: "Open a flow to see the answers its runs ended with."
        case .runs: "Open a flow to see its earlier runs."
        case .cost: "Open a flow to see what it has used."
        }
    }
}

/// The panel beside the canvas on an iPad. While something is selected its details are pushed over the
/// panel, with the system's slide, and a way back that names the tab under them. Going back, by that or by
/// the system's swipe from the edge, is putting the selection away, and so is a tap on the bare canvas: the
/// details are there exactly while something is selected. Selecting something else changes what they say
/// in place, so there is never more than the one page on top.
struct PanelColumn: View {
    @Environment(RemoteClient.self) private var client

    private var path: Binding<[DetailsRoute]> {
        Binding {
            client.wantsDetails ? [DetailsRoute()] : []
        } set: { new in
            if new.isEmpty, client.wantsDetails { client.closeDetails() }
        }
    }

    var body: some View {
        NavigationStack(path: path) {
            InspectorPanel()
                // The tab's name is what the way back from the details says. The bar itself is the panel's own.
                .navigationTitle(client.panel.page.tab.title)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DetailsRoute.self) { _ in
                    DetailsScreen(back: client.panel.page.tab.title)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
    }
}

/// The one page that can be pushed over the panel.
struct DetailsRoute: Hashable {}

/// What the Mac wouldn't do, said at the top of a sheet. As a sheet the panel covers the foot of the canvas,
/// where a refusal is said, so it is said here too: what the Mac wouldn't do is never out of sight of the
/// button that asked for it.
struct SheetRefusal: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        if client.isSheetUp, let refusal = client.controls.refusal {
            RefusalNotice(text: refusal.text, alignment: .leading) { client.controls.refusal = nil }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
            Hairline()
        }
    }
}

/// The panel's tabs in a row. They fit as they are. At a larger text size, or in a narrower column, the row
/// scrolls sideways and keeps the tab on show in view.
private struct TabStrip: View {
    let selected: PanelTab
    let pick: (PanelTab) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(PanelTab.allCases) { tab in
                        TabButton(title: tab.title, isOn: tab == selected) { pick(tab) }.id(tab)
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isTabBar)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selected) { withAnimation(Theme.Motion.standard) { proxy.scrollTo(selected, anchor: .center) } }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
    }
}

/// One of the panel's tabs: its name, ruled underneath when it is the one on show.
private struct TabButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .dsSans(Theme.Touch.body, isOn ? .medium : .regular)
                .foregroundStyle((isOn ? Theme.ink : Theme.inkSecondary).ui)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .frame(minHeight: Theme.Touch.target)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isOn ? Theme.ink.ui : .clear).frame(height: Theme.Stroke.selected)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// The pages that share a tab, side by side: the one on show is inked in.
private struct PageSwitch: View {
    let pages: [PanelPage]
    let counts: [PanelPage: Int]
    let selected: PanelPage
    let pick: (PanelPage) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(pages) { page in
                let isOn = page == selected, count = counts[page] ?? 0
                Button { pick(page) } label: {
                    HStack(spacing: Theme.Space.xs + 2) {
                        Text(page.title).dsSans(Theme.Touch.body, .medium)
                        if count > 0 { Text("\(count)").dsSans(Theme.Touch.caption).opacity(0.75) }
                    }
                    .lineLimit(1)
                    .foregroundStyle((isOn ? Theme.surface : Theme.ink).ui)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(isOn ? Theme.ink.ui : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(count > 0 ? "\(page.title), \(count)" : page.title)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.outline.ui, lineWidth: Theme.Stroke.card))
        .animation(Theme.Motion.quick, value: selected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
    }
}

/// Says that an earlier run is on show, with the way back. It is in the panel and over the canvas, so the
/// way back is there whichever of them the person is looking at.
struct EarlierRunNotice: View {
    @Environment(RemoteClient.self) private var client
    let run: RunRecord

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Showing the run from \(Clock.run(run.started)).")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.ink.ui)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            Button("Back to latest") { client.canvas.view(nil) }
                .buttonStyle(.panel())
                // The sentence wraps to make room. The way back is never cut short.
                .fixedSize()
                .accessibilityHint("Shows the latest run again.")
        }
        .padding(.vertical, Theme.Space.xs + 2)
    }
}

/// What a page of the panel says when no flow is open.
struct NothingOpen: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("No flow open").dsSans(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
            Text(text).dsSans().foregroundStyle(Theme.inkSecondary.ui)
        }
    }
}

/// The session that runs the open flow: what it is doing, and its terminal as the Mac's side panel has it.
/// The terminal here is a picture that follows the session. Reading back through it is done full screen.
/// Under it is a box for sending the orchestrator a message, when this device may.
struct OrchestratorPanel: View {
    @Environment(RemoteClient.self) private var client
    private let key = TerminalRegistry.orchestratorKey

    var body: some View {
        if client.openFlow == nil {
            NothingOpen(text: "Open a flow to see the session that runs it.")
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if client.terminals.sizes[key] != nil {
            let caption = SessionCaption(key: key, client: client)
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Text("Runs this flow").dsSans().foregroundStyle(Theme.inkSecondary.ui)
                    if let badge = caption.badge { Badge(text: badge.text, tone: badge.tone) }
                    Spacer(minLength: Theme.Space.s)
                    if let button = client.abilities.orchestrator { OrchestratorButton(button: button) }
                    Button { client.openTerminal(key) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink.ui)
                            .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the terminal full screen")
                }
                .padding(.leading, Theme.Space.l)
                Hairline()
                // The Mac's padding around its terminal, on the terminal's own colour.
                TerminalPicture(key: key)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.terminal.ui)
                // A message for the orchestrator can be written here. Keys are for the full-screen view.
                ComposerBar(key: key, isCompact: true)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Not started").dsSans(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                Text("The session that runs this flow hasn't been started on your Mac.").dsSans().foregroundStyle(Theme.inkSecondary.ui)
                if let button = client.abilities.orchestrator { OrchestratorButton(button: button).padding(.top, Theme.Space.xs) }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The orchestrator panel's own button, as the Mac's panel has it: Start, Restart, "Restart to apply" when the flow's
/// details have changed under it, or a small ↻ while it runs as it should.
private struct OrchestratorButton: View {
    @Environment(RemoteClient.self) private var client
    let button: PressButton

    var body: some View {
        let state = client.mirror.snapshot?.run.sessions[Remote.orchestratorKey] ?? .notStarted
        let isLive = state != .notStarted && state != .exited
        Group {
            if isLive, button.title == "Restart" {
                Button { client.press(button.press) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink.ui)
                        .frame(width: Theme.Touch.target, height: Theme.Touch.target)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Restart the orchestrator")
            } else {
                Button(button.title) { client.press(button.press) }
                    .buttonStyle(.panel(button.isMain ? .live : .outline))
                    .fixedSize()
            }
        }
        .disabled(!button.isEnabled)
        .accessibilityHint(button.hint)
    }
}
