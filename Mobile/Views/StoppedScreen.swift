import SwiftUI

/// A full-screen message for when carrying on needs the person to do something. One thing to do, each time,
/// and where that may not be the way out, a quieter way to forget the Mac and start again.
struct StoppedScreen: View {
    enum Reason: Equatable {
        /// The Mac no longer knows this device. The text is the Mac's.
        case pairAgain(String)
        /// The two apps are on different versions. The text is the Mac's, and says which one to update.
        case update(String)
        /// iOS won't let the app look for the Mac, by name.
        case localNetwork(String)
    }

    let reason: Reason
    let perform: () -> Void
    /// Forgets the Mac. Given when the message covers the settings, where that is otherwise done.
    var forget: (() -> Void)?
    @State private var asksToForget = false

    init(_ reason: Reason, forget: (() -> Void)? = nil, perform: @escaping () -> Void) {
        self.reason = reason
        self.forget = forget
        self.perform = perform
    }

    private var words: (symbol: String, title: String, text: String, action: String) {
        switch reason {
        case .pairAgain(let text):
            ("link.badge.plus", "Pair this device again", text, "Pair again")
        case .update(let text):
            ("arrow.down.circle", "Update needed", text, "Try again")
        case .localNetwork(let mac):
            ("wifi.slash", "Queen Bee can't look for \(mac)",
             "Queen Bee finds your Mac over your Wi-Fi, and it isn't allowed to. In Settings, turn on Local Network for Queen Bee, then come back.",
             "Open Settings")
        }
    }

    var body: some View {
        ZStack {
            Paper()
            Plate(symbol: words.symbol, title: words.title, text: words.text) {
                Button(words.action, action: perform)
                    .buttonStyle(.panel(.filled, wide: true))
                if let forget {
                    Button("Forget this Mac") { asksToForget = true }
                        .buttonStyle(.panel(.quiet))
                        .confirmationDialog("Forget this Mac?", isPresented: $asksToForget, titleVisibility: .visible) {
                            Button("Forget this Mac", role: .destructive, action: forget)
                        } message: {
                            Text("This device will have to be paired again before it can connect.")
                        }
                }
            }
        }
    }
}
