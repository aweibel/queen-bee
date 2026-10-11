import AVFoundation
import QueenBeeLink
import SwiftUI

/// The screens a new device goes through: what to do, which Mac, and the code from that Mac's screen.
struct PairingView: View {
    private enum Step: Hashable {
        case macs
        case code(FoundMac)
    }

    @State private var path: [Step] = []
    @State private var browser = MacBrowser()

    var body: some View {
        NavigationStack(path: $path) {
            IntroScreen { path.append(.macs) }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .macs: MacListScreen(browser: browser) { path.append(.code($0)) }
                    case .code(let mac): CodeScreen(mac: mac)
                    }
                }
        }
        #if DEBUG
        .task {
            // A test asks for a screen it has no way to tap its way to.
            switch DebugLaunch.show {
            case "macs": path = [.macs]
            case "code": path = [.macs, .code(FoundMac(name: "Example Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9)))]
            default: break
            }
        }
        #endif
    }
}

private struct IntroScreen: View {
    let next: () -> Void

    var body: some View {
        PairingPage {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Queen Bee")
                    .dsMono(28, .medium)
                    .foregroundStyle(Theme.ink.ui)
                    .accessibilityAddTraits(.isHeader)
                Text("Watch the flows running on your Mac. Pair this device with your Mac once, and it connects by itself from then on.")
                    .dsSans()
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
            VStack(alignment: .leading, spacing: 0) {
                StepRow(number: 1, title: "On your Mac",
                        text: "Open Queen Bee and go to Settings. Under Remote, turn on “Let your iPad or iPhone connect”, then choose “Pair a device…”. A code appears.")
                Hairline()
                StepRow(number: 2, title: "On this device",
                        text: "Choose your Mac from the list, then point the camera at the code.")
            }
            .floatingPanel()
            Text("Both need to be on the same Wi-Fi. Nothing is sent over the internet.")
                .dsSans(Theme.Touch.caption + 1)
                .foregroundStyle(Theme.inkSecondary.ui)
            Button("Continue", action: next)
                .buttonStyle(.panel(.filled, wide: true))
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(number)")
                .dsMono(Theme.Touch.body, .medium)
                .foregroundStyle(Theme.ink.ui)
                .frame(width: 28, height: 28)
                .background(Theme.bar.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline.ui))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).dsMono(Theme.Touch.body, .medium).foregroundStyle(Theme.ink.ui)
                Text(text).dsSans().foregroundStyle(Theme.inkSecondary.ui)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(text)")
    }
}

/// The Macs showing a pairing code right now.
private struct MacListScreen: View {
    let browser: MacBrowser
    let choose: (FoundMac) -> Void

    var body: some View {
        PairingPage {
            if browser.isBlocked {
                Text("Queen Bee isn't allowed to look for your Mac. Turn on Local Network for Queen Bee in Settings, then come back.")
                    .dsSans()
                    .foregroundStyle(Theme.ink.ui)
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.panel(.filled, wide: true))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(browser.macs) { mac in
                        Button { choose(mac) } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: "desktopcomputer").foregroundStyle(Theme.inkSecondary.ui)
                                Text(mac.name).dsMono().foregroundStyle(Theme.ink.ui).lineLimit(1)
                                Spacer(minLength: Theme.Space.s)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.inkSecondary.ui)
                            }
                            .padding(.horizontal, Theme.Space.l)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Hairline()
                    }
                    HStack(spacing: Theme.Space.m) {
                        ProgressView().tint(Theme.inkSecondary.ui)
                        Text(browser.macs.isEmpty ? "Looking for your Mac…" : "Looking for more…")
                            .dsSans()
                            .foregroundStyle(Theme.inkSecondary.ui)
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .frame(minHeight: 52)
                }
                .floatingPanel()
                Text("A Mac is listed while it is showing a pairing code. If yours isn't here, choose “Pair a device…” in Queen Bee's settings on the Mac, and check that both are on the same Wi-Fi.")
                    .dsSans(Theme.Touch.caption + 1)
                    .foregroundStyle(Theme.inkSecondary.ui)
            }
        }
        .navigationTitle("Choose your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { browser.start() }
    }
}

/// Getting the code off the Mac's screen: with the camera, or pasted in as text.
private struct CodeScreen: View {
    @Environment(RemoteClient.self) private var client
    let mac: FoundMac

    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var pastes = !CodeScanner.isSupported
    @State private var scanned: PairingCode?
    @State private var typed = ""
    @State private var typedProblem: String?

    private var isPairing: Bool { client.state == .pairing }

    var body: some View {
        PairingPage {
            if isPairing {
                HStack(spacing: Theme.Space.m) {
                    ProgressView().tint(Theme.inkSecondary.ui)
                    Text("Pairing with \(mac.name)…").dsSans().foregroundStyle(Theme.ink.ui)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if pastes {
                paste
            } else {
                scan
            }
            if !isPairing, let problem = client.pairingProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .dsSans()
                    .foregroundStyle(Theme.failInk.ui)
                    .padding(Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.failTint.ui, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
            if !isPairing, CodeScanner.isSupported {
                Button(pastes ? "Scan the code instead" : "Paste the code instead") { pastes.toggle() }
                    .buttonStyle(.panel(.quiet))
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Asked for here, the first time, so the question comes up when the person has just chosen to scan.
            if camera == .notDetermined, CodeScanner.isSupported {
                camera = await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
            }
        }
    }

    @ViewBuilder private var scan: some View {
        switch camera {
        case .authorized:
            Text("Point the camera at the code on your Mac's screen.")
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
                .frame(maxWidth: .infinity, alignment: .leading)
            CodeScanner { code in
                // A code that didn't work is still in front of the camera, and would be tried again for ever.
                guard code != scanned else { return }
                scanned = code
                client.pair(with: code, at: mac.endpoint)
            }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.ink.ui, lineWidth: Theme.Stroke.card))
                .accessibilityLabel("Camera, looking for the pairing code")
        case .notDetermined:
            ProgressView().tint(Theme.inkSecondary.ui).frame(maxWidth: .infinity).padding(.vertical, 60)
        default:
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Queen Bee isn't allowed to use the camera, so it can't scan the code. Turn on Camera for Queen Bee in Settings, or paste the code instead.")
                    .dsSans()
                    .foregroundStyle(Theme.ink.ui)
                Button("Open Settings") { openSettings() }.buttonStyle(.panel())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(CodeScanner.isSupported
                 ? "On your Mac, choose “Copy the code as text” under the code. Then paste it here."
                 : "This device has no camera to scan with. On your Mac, choose “Copy the code as text” under the code. Then paste it here.")
                .dsSans()
                .foregroundStyle(Theme.ink.ui)
            TextField("queenbee-pair:…", text: $typed, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.plain)
                .dsMono()
                .foregroundStyle(Theme.ink.ui)
                .frame(minHeight: 28)
                .fieldBox()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Pairing code")
            if let typedProblem {
                Text(typedProblem).dsSans(Theme.Touch.caption + 1).foregroundStyle(Theme.failInk.ui)
            }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    typed = strings.first ?? ""
                    typedProblem = nil
                }
                .tint(Theme.ink.ui)
                .buttonBorderShape(.roundedRectangle(radius: Theme.Radius.card))
                Spacer()
                Button("Pair") { pairWithTyped() }
                    .buttonStyle(.panel(.filled))
                    .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func pairWithTyped() {
        guard let code = PairingCode(text: typed) else {
            typedProblem = "That isn't a Queen Bee pairing code. Copy it again from your Mac."
            return
        }
        typedProblem = nil
        client.pair(with: code, at: mac.endpoint)
    }
}

/// One pairing screen: its parts in a column on the paper, kept to a width that reads well on an iPad.
private struct PairingPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) { content }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
        }
        .background { Paper() }
    }
}
