import QueenBeeCore
import SwiftUI

/// The first-run walk-through: one panel over the window, four steps, each with a small
/// drawing made from the same parts the canvas uses. Shown once, and again from the Help menu.
struct OnboardingView: View {
    static let seenKey = "hasSeenWelcome"

    let finish: () -> Void
    @State private var step = 0
    private var services: AppServices { AppServices.shared }

    private struct Step {
        let title: String
        let text: String
    }

    private static let steps = [
        Step(title: "Flows of agents, on a canvas",
             text: "Queen Bee runs Claude Code agents as a flow. Each card does one job, and links carry every finished reply to the cards that come next."),
        Step(title: "Every agent is a live Claude Code",
             text: "Each agent card has its own Claude Code running on it, live. Click into one and type, just as you would in any Claude Code window, or let the flow hand it work. When it finishes, its reply travels along the link to the next card."),
        Step(title: "Logic cards decide where a reply goes",
             text: "If / Else, Switch, Loop until and the rest decide which card gets each reply next. A link turns orange while a message is travelling along it, and green once the run has been that way, with a count of how many times."),
        Step(title: "The orchestrator builds and runs it",
             text: "Every flow has an orchestrator beside the canvas. Tell it what you want and it lays out the cards, links them, runs the flow and reports back. You can also build by hand from the palette."),
    ]

    private var isLast: Bool { step == Self.steps.count - 1 }

    var body: some View {
        ZStack {
            // The window is fogged with its own paper, so the backdrop works in light and dark.
            Theme.paper.ui.opacity(0.78)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {} // The window behind waits until the walk-through is closed.
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    DotPaper()
                    illustration
                        .id(step)
                        .transition(.opacity)
                }
                .frame(height: 190)
                .clipped()
                Rectangle().fill(Theme.hairline.ui).frame(height: 1)

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(Self.steps[step].title)
                        .font(.dsSans(Theme.Size.heading, .medium))
                    Text(Self.steps[step].text)
                        .font(.dsSans(Theme.Size.title))
                        .foregroundStyle(Theme.inkSecondary.ui)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if isLast { ClaudeCheck() }
                }
                .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.l)
                .id(step)
                .transition(.opacity)

                footer
            }
            .frame(width: 520)
            .foregroundStyle(Theme.ink.ui)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .floatingPanel()
        }
        .animation(Theme.Motion.standard, value: step)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Skip", action: finish)
                .buttonStyle(.panel(.quiet))
                .keyboardShortcut(.cancelAction)
                .opacity(isLast ? 0 : 1)
                .disabled(isLast)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Self.steps.indices, id: \.self) { i in
                    Capsule()
                        .fill((i == step ? Theme.ink : Theme.hairline).ui)
                        .frame(width: i == step ? 16 : 6, height: 6)
                }
            }
            .accessibilityLabel("Step \(step + 1) of \(Self.steps.count)")
            Spacer()
            Button("Back") { step -= 1 }
                .buttonStyle(.panel())
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(step == 0)
            if isLast {
                Button(services.projects.isEmpty ? "Add project folder…" : "Done") {
                    let needsFolder = services.projects.isEmpty
                    finish()
                    if needsFolder { WorkspaceView.pickProjectFolder() }
                }
                .buttonStyle(.panel(.filled))
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { step += 1 }
                    .buttonStyle(.panel(.filled))
                    .keyboardShortcut(.defaultAction)
                // The right arrow goes on too, without taking Return away from Next.
                Button("") { step += 1 }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.l)
    }

    @ViewBuilder private var illustration: some View {
        switch step {
        case 0:
            HStack(spacing: 0) {
                MiniCard(icon: "play", name: "Start", width: 92) { MiniText("Write a slogan") }
                MiniLink(tone: .pass)
                MiniCard(icon: "terminal", name: "Writer", width: 110) { MiniTerminal("› drafting") }
                MiniLink(tone: .pass)
                MiniCard(icon: "terminal", name: "Reviewer", width: 110) { MiniTerminal("› reviewing") }
                MiniLink(tone: .plain)
                MiniCard(icon: "flag", name: "Done", width: 92) { MiniText("The answer") }
            }
        case 1:
            HStack(spacing: 0) {
                MiniCard(icon: "terminal", name: "Writer", width: 160) { MiniTerminal("› draft a slogan\n● Fresh bread, warm\n  smiles.", height: 62) }
                MiniLink(tone: .live, width: 56)
                MiniCard(icon: "terminal", name: "Reviewer", badge: "working", live: true, width: 160) { MiniTerminal("● reading the draft…", height: 62) }
            }
        case 2:
            HStack(alignment: .center, spacing: 0) {
                MiniCard(icon: "terminal", name: "Reviewer", width: 120) { MiniTerminal("● APPROVED") }
                MiniLink(tone: .pass, width: 40)
                MiniCard(icon: "arrow.triangle.branch", name: "Approved?", badge: "✓ 2", width: 132) {
                    VStack(alignment: .trailing, spacing: 3) {
                        MiniText("Has \"APPROVED\"")
                        Text("Yes").font(.dsSans(10, .medium)).foregroundStyle(Theme.liveInk.ui)
                            .padding(.horizontal, 5).background(Theme.liveTint.ui)
                        Text("No").font(.dsSans(10, .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(6)
                }
                MiniLink(tone: .pass, width: 40)
                MiniCard(icon: "flag", name: "Done", badge: "✓", width: 96) { MiniText("Saved to slogan.txt") }
            }
        default:
            HStack(alignment: .top, spacing: Theme.Space.l) {
                HStack(spacing: 0) {
                    MiniCard(icon: "play", name: "Start", width: 76) { MiniText("…") }
                    MiniLink(tone: .plain, width: 26)
                    MiniCard(icon: "terminal", name: "Writer", width: 96) { MiniTerminal("›") }
                }
                .padding(.top, 34)
                MiniCard(icon: "sparkles", name: "Orchestrator", badge: "idle", width: 210) {
                    MiniTerminal("› a writer and a reviewer\n  that loop until approved\n● Built it: 4 cards, 4 links.", height: 96)
                }
            }
        }
    }
}

/// Whether Claude Code is installed and new enough, said on the walk-through's last step.
private struct ClaudeCheck: View {
    @State private var version: String?
    @State private var checked = false
    private var services: AppServices { AppServices.shared }

    var body: some View {
        let environment = services.environment
        HStack(spacing: 6) {
            if environment == nil || (environment?.claude != nil && !checked) {
                Badge(text: "Looking for Claude Code…")
            } else if environment?.claude == nil {
                Badge(text: "Queen Bee can't find Claude Code. Install it, then reopen Queen Bee.", symbol: "xmark", tone: .fail)
            } else if let version, version.compare(ResolvedEnvironment.minimumClaude, options: .numeric) == .orderedAscending {
                Badge(text: "Claude Code \(version) is too old: update to \(ResolvedEnvironment.minimumClaude) or later", symbol: "xmark", tone: .fail)
            } else if let version {
                Badge(text: "Claude Code \(version) is ready", symbol: "checkmark", tone: .pass)
            } else {
                Badge(text: "Claude Code is installed, but its version couldn't be read. It needs \(ResolvedEnvironment.minimumClaude) or later.")
            }
        }
        .padding(.top, Theme.Space.xs)
        .task(id: environment?.claude) {
            guard let environment, environment.claude != nil else { return }
            version = await environment.claudeVersion()
            checked = true
        }
    }
}

// MARK: The drawings' parts

/// The canvas's dot matrix, for behind a drawing.
private struct DotPaper: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.paper.ui))
            let step: CGFloat = 20
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(Theme.dot.ui))
                    x += step
                }
                y += step
            }
        }
    }
}

/// A card as the canvas draws one, small.
private struct MiniCard<Content: View>: View {
    let icon: String
    let name: String
    var badge: String?
    var live = false
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 8, weight: .medium))
                Text(name).font(.dsSans(10, .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.dsSans(9, .medium))
                        .foregroundStyle((live ? Theme.liveInk : badge.hasPrefix("✓") ? Theme.passInk : Theme.inkSecondary).ui)
                        .padding(.horizontal, 3)
                        .background((live ? Theme.liveTint : badge.hasPrefix("✓") ? Theme.passTint : NSColor.clear).ui,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Theme.bar.ui)
            Rectangle().fill(Theme.hairline.ui).frame(height: 1)
            content
        }
        .frame(width: width)
        .background(Theme.surface.ui)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder((live ? Theme.live : Theme.ink).ui, lineWidth: live ? Theme.Stroke.link : Theme.Stroke.card))
    }
}

private struct MiniTerminal: View {
    let text: String
    var height: CGFloat = 44

    init(_ text: String, height: CGFloat = 44) {
        self.text = text
        self.height = height
    }

    var body: some View {
        Text(text)
            .font(.dsMono(10))
            .foregroundStyle(Theme.terminalInk.ui)
            .lineSpacing(1)
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(Theme.terminal.ui)
    }
}

private struct MiniText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.dsSans(10))
            .foregroundStyle(Theme.inkSecondary.ui)
            .lineLimit(2)
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
    }
}

/// A link between two cards: ink at rest, green once travelled, marching orange while live.
private struct MiniLink: View {
    enum Tone { case plain, pass, live }
    let tone: Tone
    var width: CGFloat = 28
    @State private var phase: CGFloat = 0

    var body: some View {
        let color = (tone == .live ? Theme.live : tone == .pass ? Theme.passInk : Theme.ink).ui
        ZStack(alignment: .trailing) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 5))
                path.addLine(to: CGPoint(x: width - 5, y: 5))
            }
            .stroke(color, style: StrokeStyle(lineWidth: tone == .live ? 2 : Theme.Stroke.link, dash: tone == .live ? [6, 6] : [], dashPhase: phase))
            Path { path in
                path.move(to: CGPoint(x: width, y: 5))
                path.addLine(to: CGPoint(x: width - 7, y: 1))
                path.addLine(to: CGPoint(x: width - 7, y: 9))
                path.closeSubpath()
            }
            .fill(color)
        }
        .frame(width: width, height: 10)
        .onAppear {
            guard tone == .live, Theme.Motion.isAllowed else { return }
            withAnimation(.linear(duration: Theme.Motion.march).repeatForever(autoreverses: false)) { phase = -12 }
        }
    }
}
