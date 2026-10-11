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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Queen Bee").font(.largeTitle.weight(.semibold))
                    Text("Watch the flows running on your Mac. Pair this device with your Mac once, and it connects by itself from then on.")
                        .foregroundStyle(.secondary)
                }
                StepRow(number: 1, title: "On your Mac",
                        text: "Open Queen Bee and go to Settings. Under Remote, turn on “Let your iPad or iPhone connect”, then choose “Pair a device…”. A code appears.")
                StepRow(number: 2, title: "On this device",
                        text: "Choose your Mac from the list, then point the camera at the code.")
                Text("Both need to be on the same Wi-Fi. Nothing is sent over the internet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(action: next) {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StepRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(text)")
    }
}

/// The Macs showing a pairing code right now.
private struct MacListScreen: View {
    let browser: MacBrowser
    let choose: (FoundMac) -> Void

    var body: some View {
        List {
            if browser.isBlocked {
                Section {
                    Text("Queen Bee isn't allowed to look for your Mac. Turn on Local Network for Queen Bee in Settings, then come back.")
                    Button("Open Settings") { openSettings() }
                }
            } else {
                Section {
                    ForEach(browser.macs) { mac in
                        Button { choose(mac) } label: {
                            Label(mac.name, systemImage: "desktopcomputer")
                        }
                    }
                    if browser.macs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for your Mac…").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("A Mac is listed while it is showing a pairing code. If yours isn't here, choose “Pair a device…” in Queen Bee's settings on the Mac, and check that both are on the same Wi-Fi.")
                }
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
        ScrollView {
            VStack(spacing: 20) {
                if isPairing {
                    ProgressView("Pairing with \(mac.name)…").padding(.vertical, 60)
                } else if pastes {
                    paste
                } else {
                    scan
                }
                if !isPairing, let problem = client.pairingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !isPairing, CodeScanner.isSupported {
                    Button(pastes ? "Scan the code instead" : "Paste the code instead") { pastes.toggle() }
                }
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            CodeScanner { code in
                // A code that didn't work is still in front of the camera, and would be tried again for ever.
                guard code != scanned else { return }
                scanned = code
                client.pair(with: code, at: mac.endpoint)
            }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Camera, looking for the pairing code")
        case .notDetermined:
            ProgressView().padding(.vertical, 60)
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text("Queen Bee isn't allowed to use the camera, so it can't scan the code. Turn on Camera for Queen Bee in Settings, or paste the code instead.")
                Button("Open Settings") { openSettings() }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CodeScanner.isSupported
                 ? "On your Mac, choose “Copy the code as text” under the code. Then paste it here."
                 : "This device has no camera to scan with. On your Mac, choose “Copy the code as text” under the code. Then paste it here.")
            TextField("queenbee-pair:…", text: $typed, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Pairing code")
            if let typedProblem {
                Text(typedProblem).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    typed = strings.first ?? ""
                    typedProblem = nil
                }
                Spacer()
                Button("Pair") { pairWithTyped() }
                    .buttonStyle(.borderedProminent)
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
