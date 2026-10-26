import QueenBeeCore
import QueenBeeDesign
import SwiftUI

/// One of the places above the projects in the sidebar, in the inset panel: what waits on you, the runs, the
/// schedules, or the paired devices, across every flow.
struct PlaceView: View {
    let place: AppServices.Place
    @Binding var showsSidebar: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                if !showsSidebar { Spacer().frame(width: 64) }
                Button { showsSidebar.toggle() } label: { Image(systemName: "sidebar.leading") }
                    .buttonStyle(.dsIcon)
                    .accessibilityLabel(showsSidebar ? "Hide projects" : "Show projects")
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.textMuted.color)
                Text(title).textRole(.body).fontWeight(.medium).foregroundStyle(Palette.text.color)
                Spacer()
            }
            .padding(.leading, DS.Space.s)
            .padding(.trailing, DS.Space.m)
            .frame(height: DS.Size.header)
            DSDivider()
            switch place {
            case .needsYou: NeedsYouList()
            case .runs: RunsList()
            case .schedules: SchedulesList()
            case .devices: DevicesPlace()
            case .flow: EmptyView()
            }
        }
    }

    private var title: String {
        switch place {
        case .needsYou: "Needs you"
        case .runs: "Runs"
        case .schedules: "Schedules"
        case .devices: "Devices"
        case .flow: ""
        }
    }

    private var icon: String {
        switch place {
        case .needsYou: "tray"
        case .runs: "play.circle"
        case .schedules: "clock"
        case .devices: "ipad.and.iphone"
        case .flow: "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: Parts the places share

/// The band over a group of rows: a mark, a name and how many.
private struct GroupHeader: View {
    let title: String
    let count: Int
    let tone: StatusTone

    var body: some View {
        HStack(spacing: DS.Space.s) {
            StatusDot(tone, size: 9)
            Text(title).textRole(.body).fontWeight(.medium).foregroundStyle(Palette.text.color)
            Text("\(count)").textRole(.body).foregroundStyle(Palette.textFaint.color).monospacedDigit()
            Spacer()
        }
        .padding(.horizontal, DS.Space.xl)
        .frame(height: DS.Size.groupHeader)
        .background(Palette.raised.color)
        .overlay(alignment: .bottom) { DSDivider() }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A row in a place's list: highlighted under the pointer, filled when chosen.
private struct PlaceRow<Content: View>: View {
    var isSelected = false
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) { content }
                .textRole(.body)
                .padding(.horizontal, DS.Space.xl)
                .frame(maxWidth: .infinity, minHeight: DS.Size.listRow, alignment: .leading)
                .background((isSelected ? Palette.accentTint : isHovered ? Palette.hover : Palette.panel.opacity(0)).color)
                .overlay(alignment: .bottom) { DSDivider() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A flow's name, as a small rounded tag at the end of a row.
private struct FlowTag: View {
    let controller: FlowController

    var body: some View {
        Text(controller.flow.name)
            .textRole(.caption)
            .foregroundStyle(Palette.textMuted.color)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.s)
            .frame(height: 22)
            .overlay(Capsule().strokeBorder(Palette.hairlineStrong.color))
    }
}

/// What a place says when it has nothing to show.
private struct EmptyPlace: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(Palette.textFaint.color)
            Text(title).textRole(.headline).foregroundStyle(Palette.text.color)
            Text(text).textRole(.body).foregroundStyle(Palette.textMuted.color).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Needs you

/// Every card waiting on you, in every open project. Click one to go to it.
private struct NeedsYouList: View {
    private var services: AppServices { AppServices.shared }

    var body: some View {
        let waiting = services.needingYou
        if waiting.isEmpty {
            EmptyPlace(symbol: "checkmark.circle", title: "Nothing needs you",
                       text: "When an agent asks you something, or an Approval or Script card waits for your go-ahead, it shows here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    GroupHeader(title: "Waiting on you", count: waiting.count, tone: .live)
                    ForEach(waiting, id: \.card.id) { entry in
                        PlaceRow { services.reveal(flowID: entry.controller.flow.id, cardID: entry.card.id) } content: {
                            Image(systemName: CanvasGeometry.icon(for: entry.card.kind))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Palette.liveText.color)
                                .frame(width: 16)
                            Text(entry.card.name).foregroundStyle(Palette.text.color).lineLimit(1)
                            Text(asks(entry.card, in: entry.controller)).foregroundStyle(Palette.textMuted.color).lineLimit(1)
                            Spacer(minLength: DS.Space.s)
                            FlowTag(controller: entry.controller)
                        }
                    }
                }
            }
        }
    }

    private func asks(_ card: Card, in controller: FlowController) -> String {
        switch card.kind {
        case .approval: "is waiting for your approval"
        case .script: "wants to run a command"
        default: "is asking you something in its terminal"
        }
    }
}

// MARK: Runs

/// Every flow's runs, the ones going now first, then the ones that stopped, then the ones that finished.
/// Choosing one shows its log beside the list.
private struct RunsList: View {
    @State private var chosen: String?
    private var services: AppServices { AppServices.shared }

    private struct Entry: Identifiable {
        let controller: FlowController
        /// Nil for the run going now, which isn't recorded until it ends.
        let record: RunRecord?
        var id: String { record?.id ?? "live:\(controller.flow.id)" }
        var started: Date { record?.started ?? .distantFuture }
        var number: Int? { record.map(\.number) ?? RunRecord.nextNumber(after: controller.runs) }
    }

    var body: some View {
        let live = services.allFlows.filter(\.isRunning).map { Entry(controller: $0, record: nil) }
        let past = services.allFlows.flatMap { controller in controller.runs.map { Entry(controller: controller, record: $0) } }
            .sorted { $0.started > $1.started }
        let stopped = past.filter { $0.record?.outcome != .finished }
        let done = past.filter { $0.record?.outcome == .finished }
        if live.isEmpty && past.isEmpty {
            EmptyPlace(symbol: "play.circle", title: "No runs yet",
                       text: "Each time a flow runs, from its Run button, a schedule or the orchestrator, it is listed here with what it did and what it cost.")
        } else {
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        group("Running", live, tone: .live)
                        group("Stopped", stopped, tone: .fail)
                        group("Done", done, tone: .pass)
                    }
                }
                .frame(maxWidth: .infinity)
                if let id = chosen, let entry = (live + past).first(where: { $0.id == id }), let record = entry.record {
                    DSDivider(vertical: true)
                    RunPeek(controller: entry.controller, record: record) { chosen = nil }
                        .frame(width: 380)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [Entry], tone: StatusTone) -> some View {
        if !entries.isEmpty {
            GroupHeader(title: title, count: entries.count, tone: tone)
            ForEach(entries) { entry in
                PlaceRow(isSelected: chosen == entry.id) {
                    if entry.record == nil {
                        services.selectedFlowID = entry.controller.flow.id
                    } else {
                        chosen = chosen == entry.id ? nil : entry.id
                    }
                } content: {
                    Text(entry.number.map { "#\($0)" } ?? "")
                        .textRole(.monoCaption)
                        .foregroundStyle(Palette.textFaint.color)
                        .frame(width: 40, alignment: .leading)
                    outcomeMark(entry.record)
                    Text(entry.controller.flow.name).foregroundStyle(Palette.text.color).lineLimit(1)
                    Text(detail(entry)).foregroundStyle(Palette.textMuted.color).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    if let record = entry.record, !record.cost.isZero {
                        Text(record.cost.price).textRole(.monoCaption).foregroundStyle(Palette.textMuted.color)
                    }
                    Text(entry.record.map { RunPicker.label(for: $0.started) } ?? "now")
                        .textRole(.caption)
                        .foregroundStyle(Palette.textFaint.color)
                        .frame(width: 84, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeMark(_ record: RunRecord?) -> some View {
        Group {
            switch record?.outcome {
            case nil: StatusDot(.live, size: 7)
            case .finished?: Image(systemName: "checkmark").foregroundStyle(Palette.pass.color)
            case .stopped?: Image(systemName: "stop.fill").foregroundStyle(Palette.textMuted.color)
            case .failed?: Image(systemName: "xmark").foregroundStyle(Palette.fail.color)
            }
        }
        .font(.system(size: 11, weight: .bold))
        .frame(width: 16)
    }

    private func detail(_ entry: Entry) -> String {
        guard let record = entry.record else {
            let handOffs = entry.controller.handOffs
            return "Running · \(handOffs) \(handOffs == 1 ? "hand-off" : "hand-offs")"
        }
        return "\(record.summary) · \(record.handOffs) \(record.handOffs == 1 ? "hand-off" : "hand-offs")"
    }
}

/// One run beside the list: how it ended, its log, and the way to see it on the canvas.
private struct RunPeek: View {
    let controller: FlowController
    let record: RunRecord
    let close: () -> Void
    private var services: AppServices { AppServices.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack {
                    Text([record.number.map { "#\($0)" }, controller.project.name].compactMap { $0 }.joined(separator: " · "))
                        .textRole(.caption)
                        .foregroundStyle(Palette.textFaint.color)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.dsIcon)
                        .accessibilityLabel("Close")
                }
                Text(controller.flow.name).textRole(.title).foregroundStyle(Palette.text.color)
                HStack(spacing: 6) {
                    StatusPill(record.summary, tone: record.outcome == .finished ? .pass : record.outcome == .failed ? .fail : .neutral)
                    if !record.cost.isZero { StatusPill(record.cost.price, tone: .neutral, dot: false) }
                }
            }
            .padding(DS.Space.l)
            DSDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(record.log) { line in
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                            Text(line.date, format: .dateTime.hour().minute())
                                .textRole(.monoCaption)
                                .foregroundStyle(Palette.textFaint.color)
                                .lineLimit(1)
                                .fixedSize()
                            Text(line.text).textRole(.body).foregroundStyle(Palette.textMuted.color)
                        }
                    }
                }
                .padding(DS.Space.l)
            }
            DSDivider()
            Button {
                services.selectedFlowID = controller.flow.id
                controller.view(run: record.id)
            } label: { Text("Show on the canvas").frame(maxWidth: .infinity) }
                .buttonStyle(.ds(.secondary, wide: true))
                .padding(DS.Space.m)
        }
    }
}

// MARK: Schedules

/// Every Start card with a schedule, in every flow: which are on and when each runs next.
private struct SchedulesList: View {
    private var services: AppServices { AppServices.shared }

    private struct Entry: Identifiable {
        let controller: FlowController
        let card: Card
        let trigger: Trigger
        var id: String { "\(controller.flow.id)/\(card.id)" }
    }

    var body: some View {
        let all = services.allFlows.flatMap { controller in
            controller.flow.cards.compactMap { card in
                card.kind == .start ? card.trigger.map { Entry(controller: controller, card: card, trigger: $0) } : nil
            }
        }
        let on = all.filter { $0.controller.isArmed($0.card) }
        let off = all.filter { !$0.controller.isArmed($0.card) }
        if all.isEmpty {
            EmptyPlace(symbol: "clock", title: "No schedules",
                       text: "A Start card can run its flow on a schedule or when a file changes. Choose one in its settings, and it shows here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    group("On", on, tone: .pass)
                    group("Off", off, tone: .neutral)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [Entry], tone: StatusTone) -> some View {
        if !entries.isEmpty {
            GroupHeader(title: title, count: entries.count, tone: tone)
            ForEach(entries) { entry in
                let armed = entry.controller.isArmed(entry.card)
                PlaceRow { AppServices.shared.reveal(flowID: entry.controller.flow.id, cardID: entry.card.id) } content: {
                    Image(systemName: entry.trigger.kind == .file ? "doc" : "clock")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textMuted.color)
                        .frame(width: 16)
                    Text(entry.trigger.summary).foregroundStyle(Palette.text.color).lineLimit(1)
                    Text("from \(entry.card.name)").foregroundStyle(Palette.textMuted.color).lineLimit(1)
                    Spacer(minLength: DS.Space.s)
                    if armed, let next = entry.controller.nextFires[entry.card.id] {
                        Text("Next \(RunPicker.label(for: next))").textRole(.caption).foregroundStyle(Palette.textMuted.color)
                    }
                    FlowTag(controller: entry.controller)
                    if armed {
                        Button("Turn off") { entry.controller.turnScheduleOff(onCard: entry.card.id) }
                            .buttonStyle(.ds(.ghost))
                    } else {
                        // A schedule that came in the flow's file, or from an undo, runs only once it is turned on here.
                        Button("Turn on") { entry.controller.setTrigger(entry.trigger, onCard: entry.card.id) }
                            .buttonStyle(.ds(.secondary))
                    }
                }
            }
        }
    }
}

// MARK: Devices

/// The paired iPads and iPhones, and pairing another: the same controls as in Settings.
private struct DevicesPlace: View {
    var body: some View {
        Form { RemoteSettingsSection() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
    }
}
