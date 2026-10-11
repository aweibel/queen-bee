import SwiftUI

@main
struct QueenBeeMobileApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Stands in until there is a Mac to pair with and flows to show.
struct RootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Queen Bee")
                .font(.largeTitle.weight(.semibold))
            Text("Watch the flows running on your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}
