import Foundation

/// Where each flow's canvas was last looking, and how far zoomed, so going back to a flow, or opening the app
/// again, puts it where it was left. Kept in the app's settings rather than the flow file: it is how this Mac
/// was looking at the flow, not part of the flow.
enum CanvasPlaces {
    struct Place: Equatable {
        var origin: CGPoint
        var zoom: CGFloat
    }

    private static let key = "canvasPlaces"
    /// Flows come and go; past this many, the ones looked at longest ago are forgotten.
    private static let kept = 200
    /// A test copy starts every canvas where a fresh one starts, so what it checks doesn't depend on earlier runs.
    private static var isOn: Bool { !TestHarness.isEnabled }

    /// A flow's id comes from its file, so a copied project's flows share ids. The folder tells them apart.
    static func id(flow: String, project: URL) -> String { project.standardizedFileURL.path + "|" + flow }

    static func place(for id: String) -> Place? {
        guard isOn, let saved = (UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]])?[id], saved.count >= 3,
              saved[2] > 0 else { return nil }
        return Place(origin: CGPoint(x: saved[0], y: saved[1]), zoom: CGFloat(saved[2]))
    }

    static func save(_ place: Place, for id: String) {
        guard isOn else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[id] = [Double(place.origin.x), Double(place.origin.y), Double(place.zoom), Date().timeIntervalSince1970]
        if all.count > kept {
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(all.count - kept).map(\.key)
            oldest.forEach { all[$0] = nil }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
