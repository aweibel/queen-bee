import QueenBeeCore
import QueenBeeDesign
import SwiftUI

/// The two places at the root of the iPhone app, between them in the floating bar at the foot of the screen.
enum PhoneTab: Hashable {
    case needsYou, flows
}

/// The bar that floats at the foot of the iPhone's first screen: Needs you, Flows, and a button that opens it into
/// a menu with the Mac, Settings and the pinned flows. A bar of the app's own, so it can open out, as Linear's does.
struct PhoneTabBar: View {
    @Environment(RemoteClient.self) private var client
    @Binding var tab: PhoneTab
    @Binding var showsMenu: Bool

    var body: some View {
        let waiting = client.mirror.library?.projects.contains { $0.flows.contains { $0.activity == .needsYou } } ?? false
        HStack(spacing: 2) {
            tabButton(.needsYou, "Needs you", symbol: "tray", marked: waiting)
            tabButton(.flows, "Flows", symbol: "square.stack.3d.up", marked: false)
            Button { withAnimation(DS.Motion.standard) { showsMenu.toggle() } } label: {
                Image(systemName: showsMenu ? "xmark" : "chevron.up.chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textMuted.color)
                    .frame(width: 56, height: 46)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsMenu ? "Close the menu" : "More: your Mac, Settings and pinned flows")
        }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline.color))
    }

    private func tabButton(_ value: PhoneTab, _ title: String, symbol: String, marked: Bool) -> some View {
        let isOn = tab == value
        return Button {
            showsMenu = false
            tab = value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle((isOn ? Palette.text : Palette.textMuted).color)
                .frame(width: 64, height: 46)
                .background((isOn ? Palette.selected : Palette.panel.opacity(0)).color, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if marked { StatusDot(.live, size: 9).padding(.top, 9).padding(.trailing, 16) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// What the bar opens into: the Mac this device is paired with and how the connection is, Settings, and the
/// pinned flows, each a tap away.
struct PhoneMenu: View {
    @Environment(RemoteClient.self) private var client
    let showSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s) {
                ConnectionPill()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(minHeight: DS.Size.touchTarget)
            DSDivider().padding(.horizontal, DS.Space.s)
            item("Settings", symbol: "gearshape") {
                close()
                showSettings()
            }
            let pinned = client.pinnedFlows
            if !pinned.isEmpty {
                SectionHeader("Pinned").padding(.horizontal, DS.Space.s).padding(.top, DS.Space.xs)
                ForEach(pinned) { flow in
                    item(flow.name, tone: flow.activity.tone) {
                        close()
                        client.open(flow.id)
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .frame(width: 280)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.hairline.color))
    }

    private func item(_ title: String, symbol: String? = nil, tone: StatusTone? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Group {
                    if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .medium)) }
                    if let tone { StatusDot(tone, size: 9) }
                }
                .foregroundStyle(Palette.textMuted.color)
                .frame(width: 22)
                Text(title).textRole(.label).foregroundStyle(Palette.text.color).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.l)
            .frame(minHeight: DS.Size.touchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension FlowActivity {
    /// The state as a colour: what the flow's dot shows.
    var tone: StatusTone {
        switch self {
        case .needsYou, .running: .live
        case .failed: .fail
        case .quiet: .neutral
        }
    }
}

/// Every flow that waits on you, is running, or stopped, across the Mac's projects. Tap one to open it.
struct WaitingList: View {
    @Environment(RemoteClient.self) private var client

    private struct Entry: Identifiable {
        let project: RemoteProject
        let flow: RemoteFlowSummary
        var id: String { "\(project.id)/\(flow.id)" }
    }

    var body: some View {
        let all = (client.mirror.library?.projects ?? []).flatMap { project in project.flows.map { Entry(project: project, flow: $0) } }
        let waiting = all.filter { $0.flow.activity == .needsYou }
        let running = all.filter { $0.flow.activity == .running }
        let stopped = all.filter { $0.flow.activity == .failed }
        Group {
            if waiting.isEmpty && running.isEmpty && stopped.isEmpty {
                VStack(spacing: DS.Space.m) {
                    Image(systemName: "checkmark.circle").font(.system(size: 32, weight: .light)).foregroundStyle(Palette.textFaint.color)
                    Text("Nothing needs you").textRole(.headline).foregroundStyle(Palette.text.color)
                    Text("When a flow on your Mac waits for an answer, or is running, it shows here.")
                        .textRole(.body).foregroundStyle(Palette.textMuted.color).multilineTextAlignment(.center)
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Waiting on you", waiting)
                        section("Running", running)
                        section("Stopped", stopped)
                    }
                    .padding(.bottom, 96)
                }
            }
        }
        .dimmedWhileAway(client.state == .connected)
        .background(Palette.panel.color)
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [Entry]) -> some View {
        if !entries.isEmpty {
            Text(title)
                .textRole(.sectionHeader)
                .foregroundStyle(Palette.textFaint.color)
                .padding(.horizontal, DS.Space.xl)
                .padding(.top, DS.Space.l)
                .padding(.bottom, DS.Space.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(entries) { entry in
                Button {
                    if entry.flow.sharedID != true { client.open(entry.flow.id) }
                } label: {
                    HStack(spacing: DS.Space.m) {
                        StatusDot(entry.flow.activity.tone, size: 10)
                            .frame(width: 40, height: 40)
                            .background(Palette.raised.color, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous).strokeBorder(Palette.hairline.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.flow.name).textRole(.headline).foregroundStyle(Palette.text.color).lineLimit(1)
                            Text(entry.project.name).textRole(.caption).foregroundStyle(Palette.textMuted.color).lineLimit(1)
                        }
                        Spacer(minLength: DS.Space.s)
                        FlowActivityBadge(activity: entry.flow.activity)
                    }
                    .padding(.horizontal, DS.Space.xl)
                    .padding(.vertical, DS.Space.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
