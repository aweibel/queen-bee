import QueenBeeCore
import SwiftUI

/// Settings that belong to a whole flow, in the corner a card's settings use.
struct FlowSettingsView: View {
    let controller: FlowController
    @State private var name = ""
    @State private var limit = ""
    @State private var cleared = false
    private var services: AppServices { AppServices.shared }

    var body: some View {
        let top = controller.topFlows
        let isTop = top.count == 1 && top[0] === controller
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .medium)).frame(width: 16)
                TextField("Flow name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.dsMono(Theme.Size.title, .medium))
                    .onSubmit { controller.rename(to: name) }
                    .help("Rename this flow")
                Text(controller.flow.isSubflow == true ? "Sub-flow" : "Flow")
                    .font(.dsMono(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                Button { controller.showsFlowSettings = false } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkSecondary.ui)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.bar.ui)

            if isTop {
                line("Sub-flows can go") {
                    HStack(spacing: 6) {
                        TextField("3", text: $limit)
                            .textFieldStyle(.plain)
                            .font(.dsMono(Theme.Size.body, .medium))
                            .multilineTextAlignment(.center)
                            .frame(width: 34)
                            .fieldBox()
                            .onSubmit(commitLimit)
                            .onChange(of: limit) {
                                // Digits only, and the change is taken as soon as it is a number.
                                let digits = limit.filter(\.isNumber)
                                if digits != limit { limit = digits }
                                if !digits.isEmpty { commitLimit() }
                            }
                        Text(Nesting.levels(controller.ownSubflowLimit).hasSuffix("s") ? "levels deep" : "level deep")
                            .font(.dsSans(Theme.Size.caption))
                            .foregroundStyle(Theme.inkSecondary.ui)
                    }
                }
                let below = controller.levelsBelow
                if below > controller.ownSubflowLimit {
                    // Lowering the limit under what is already built deletes nothing.
                    Label("This flow already goes \(Nesting.levels(below)) deep. The levels past the limit are kept, marked on their Flow cards, and come out Fail when a run reaches them.",
                          systemImage: "exclamationmark.triangle")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.failInk.ui)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.bottom, Theme.Space.s)
                } else {
                    text("A Flow card runs another flow, which can hold Flow cards of its own. This is how far down that may go under this flow. 0 means no sub-flows. It goes \(below) deep now.")
                }
            } else {
                // A sub-flow goes by the flow at the top, so there is one place to set the limit.
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.levelsLeft >= 0
                         ? "This sub-flow may go \(Nesting.levels(controller.levelsLeft)) further down."
                         : "This sub-flow is past the limit, so it is kept but won't be run from the flow above.")
                        .font(.dsSans(Theme.Size.body))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(top, id: \.flow.id) { outer in
                        Button {
                            services.selectedFlowID = outer.flow.id
                            outer.showsFlowSettings = true
                        } label: {
                            Text("The limit is set on \(outer.flow.name): \(Nesting.levels(outer.ownSubflowLimit))")
                        }
                        .buttonStyle(.panel())
                        .help("Go to \(outer.flow.name)'s settings")
                    }
                }
                .padding(Theme.Space.m)
                .overlay(alignment: .top) { divider }
            }

            line("Tell the orchestrator when a run ends") {
                Toggle("", isOn: Binding(get: { controller.flow.notifyOrchestrator }, set: { controller.setNotifiesOrchestrator($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.select.ui)
            }
            text("When on, the orchestrator is sent what each run did and replies about it. That reply uses its model, so turning this off makes runs cheaper.")

            line("Browser data for \(controller.project.name)") {
                Button(cleared ? "Cleared" : "Clear browser data") {
                    cleared = true
                    Task { await controller.project.browser.clearData() }
                }
                .buttonStyle(.panel())
                .disabled(cleared || !controller.project.browser.hasData)
                .help("Signs the agents' browser out of every site and forgets the pages it has kept. It covers every flow in this project.")
            }
            text("Agent cards with a browser share one set of sign-ins across this project, kept apart from your own browser.")
        }
        .frame(width: InspectorView.width)
        .foregroundStyle(Theme.ink.ui)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .floatingPanel()
        .onAppear {
            name = controller.flow.name
            limit = "\(controller.ownSubflowLimit)"
        }
        .onChange(of: controller.flow.name) { name = controller.flow.name }
        .onChange(of: controller.ownSubflowLimit) { if Int(limit) != controller.ownSubflowLimit { limit = "\(controller.ownSubflowLimit)" } }
    }

    private func commitLimit() {
        guard let wanted = Int(limit) else { return limit = "\(controller.ownSubflowLimit)" }
        controller.setSubflowLimit(wanted)
        // A number out of range is brought back into it where you can see it.
        if wanted != controller.ownSubflowLimit { limit = "\(controller.ownSubflowLimit)" }
    }

    private var divider: some View { Rectangle().fill(Theme.hairline.ui).frame(height: 1) }

    private func line<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.inkSecondary.ui)
            Spacer(minLength: Theme.Space.s)
            content()
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(minHeight: 34)
        .overlay(alignment: .top) { divider }
    }

    private func text(_ words: String) -> some View {
        Text(words)
            .font(.dsSans(Theme.Size.caption))
            .foregroundStyle(Theme.inkSecondary.ui)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
    }
}
