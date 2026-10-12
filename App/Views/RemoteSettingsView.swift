import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Remote part of Settings: whether paired devices may connect, which are paired, and pairing another.
struct RemoteSettingsSection: View {
    @AppStorage(RemoteHost.enabledKey) private var enabled = false
    @State private var showsPairing = false
    private var host: RemoteHost { RemoteHost.shared }

    var body: some View {
        Section {
            Toggle("Let your iPad or iPhone connect", isOn: $enabled)
                .onChange(of: enabled) { host.setOn(enabled) }
            if enabled {
                ForEach(host.devices.devices) { device in
                    LabeledContent {
                        HStack(spacing: Theme.Space.s) {
                            if host.sessions.contains(where: { $0.device.id == device.id }) { Badge(text: "connected", tone: .live) }
                            Toggle("Can control", isOn: Binding(get: { device.canControl },
                                                                set: { host.setCanControl($0, for: device.id) }))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .help(device.canControl ? "\(device.name) can start and stop runs, answer approvals, type into sessions and edit flows on this Mac."
                                      : "\(device.name) can only watch.")
                            Button("Remove") { host.remove(device.id) }
                                .help("\(device.name) will no longer be able to connect to this Mac.")
                        }
                    } label: {
                        Text(device.name).lineLimit(1).truncationMode(.tail)
                    }
                }
                if !host.devices.devices.isEmpty {
                    Text("A device with “Can control” on can start and stop runs, answer approvals, type into sessions and edit flows on this Mac. It is off for every device until you turn it on.")
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Pair a device…") {
                    host.beginPairing()
                    showsPairing = true
                }
                if let problem = host.problem {
                    Text(problem)
                        .font(.dsSans(Theme.Size.caption))
                        .foregroundStyle(Theme.failInk.ui)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Remote")
        } footer: {
            Text("An iPad or iPhone you have paired can see your flows and their terminals while it is on the same Wi-Fi as this Mac. It can only watch unless you turn on “Can control” for it. Nothing is sent over the internet.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showsPairing, onDismiss: { host.cancelPairing() }) {
            PairingSheet()
        }
    }
}

/// The one-time code a device scans, with how long it has left.
private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var host: RemoteHost { RemoteHost.shared }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a device").font(.dsSans(Theme.Size.heading, .semibold))
            if let offer = host.pairing {
                if let image = Self.qr(offer.code.text) {
                    // Black on white whatever the app's appearance, or a camera can't read it.
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Pairing code")
                }
                Text("Open Queen Bee on your iPad or iPhone, choose this Mac and scan the code.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Works once, for \(max(0, Int(offer.expires.timeIntervalSince(context.date)))) more seconds.")
                        .foregroundStyle(.secondary)
                }
                Text("Anyone who sees this code can pair while it works, so treat it like a password.")
                    .font(.dsSans(Theme.Size.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy the code as text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(offer.code.text, forType: .string)
                }
                .help("For a device with no camera. Anyone who has the code can pair while it works.")
            } else {
                Text(host.problem ?? "This code has been used or has run out.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .font(.dsSans(Theme.Size.body))
        .padding(22)
        .frame(width: 320)
        // The code goes away when a device has used it or its time is up.
        .onChange(of: host.pairing == nil) { if host.pairing == nil { dismiss() } }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
