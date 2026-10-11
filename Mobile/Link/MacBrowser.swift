import Foundation
import Network
import Observation
import QueenBeeCore

/// A Mac that is showing a pairing code right now.
nonisolated struct FoundMac: Identifiable, Hashable, Sendable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

/// What came of looking for this device's own listener on its Mac.
nonisolated enum ListenerSearch: Sendable {
    case found(NWEndpoint)
    /// iOS won't let the app look: the person turned Local Network off for it.
    case blocked
    case failed
}

/// Finds Macs on the local network: the ones offering to pair, for the person to choose from, and the
/// listener a paired Mac keeps for this device.
@Observable
final class MacBrowser {
    private(set) var macs: [FoundMac] = []
    /// True when iOS won't let the app look for anything on the local network.
    private(set) var isBlocked = false

    @ObservationIgnored private var browser: NWBrowser?

    /// What iOS answers when the person has turned Local Network off for the app (kDNSServiceErr_PolicyDenied).
    private nonisolated static let policyDenied: Int32 = -65570

    private nonisolated static func isBlocked(_ state: NWBrowser.State) -> Bool? {
        switch state {
        case .waiting(.dns(let code)) where code == policyDenied, .failed(.dns(let code)) where code == policyDenied: true
        case .ready: false
        default: nil
        }
    }

    /// Starts listing the Macs that are offering to pair. The list follows them as they come and go.
    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Remote.pairingService, domain: nil), using: NWParameters())
        self.browser = browser
        // Both handlers run on the browser's queue, so what they find is carried over to the main actor.
        browser.stateUpdateHandler = { [weak self] state in
            guard let blocked = Self.isBlocked(state) else { return }
            Task { @MainActor in self?.isBlocked = blocked }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.macs(in: results)
            Task { @MainActor in self?.macs = found }
        }
        browser.start(queue: DispatchQueue(label: "dev.queenbee.mobile.browser"))
    }

    func stop() {
        browser?.cancel()
        browser = nil
        macs = []
    }

    /// One row for each Mac, by name. A Mac reachable two ways (Wi-Fi and a cable, say) is found twice.
    private nonisolated static func macs(in results: Set<NWBrowser.Result>) -> [FoundMac] {
        var byName: [String: FoundMac] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, byName[name] == nil else { continue }
            byName[name] = FoundMac(name: name, endpoint: result.endpoint)
        }
        return byName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Waits until the paired Mac's listener for this device shows up on the network, and returns where it is.
    /// Nil if the wait is cancelled. There is no time limit: a Mac that is asleep may be back in an hour.
    nonisolated static func findListener(deviceID: String, macID: String) async -> ListenerSearch? {
        // The record is asked for along with the name, because it is what says whose listener each one is.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Remote.service, domain: nil), using: NWParameters())
        let search = Search(browser)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                search.begin(continuation) { result in
                    guard case .bonjour(let record) = result.metadata else { return false }
                    return Remote.isListener(record.dictionary, forDevice: deviceID, ofMac: macID)
                }
            }
        } onCancel: {
            search.finish(nil)
        }
    }

    /// One look for a listener. It answers once, from whichever of the browser's queue or a cancelled task gets there first.
    private nonisolated final class Search: @unchecked Sendable {
        private let browser: NWBrowser
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ListenerSearch?, Never>?
        private var isFinished = false

        init(_ browser: NWBrowser) { self.browser = browser }

        func begin(_ continuation: CheckedContinuation<ListenerSearch?, Never>, isWanted: @escaping @Sendable (NWBrowser.Result) -> Bool) {
            let alreadyFinished = lock.withLock {
                if !isFinished { self.continuation = continuation }
                return isFinished
            }
            // Cancelled before it began.
            guard !alreadyFinished else { continuation.resume(returning: nil); return }
            browser.stateUpdateHandler = { [weak self] state in
                if MacBrowser.isBlocked(state) == true { self?.finish(.blocked) }
                if case .failed = state { self?.finish(.failed) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if let match = results.first(where: isWanted) { self?.finish(.found(match.endpoint)) }
            }
            browser.start(queue: DispatchQueue(label: "dev.queenbee.mobile.search"))
        }

        func finish(_ result: ListenerSearch?) {
            let waiting = lock.withLock {
                defer { continuation = nil }
                isFinished = true
                return continuation
            }
            browser.cancel()
            waiting?.resume(returning: result)
        }
    }
}
