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
    /// Every listener that says it is the one, with the service name each goes by. Usually one. Anything on the
    /// network can copy a Mac's record, so the device tries each in turn, the one that let it in before first.
    case found([(endpoint: NWEndpoint, name: String?)])
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
    /// True between `start` and `stop`: the list of Macs is on screen.
    @ObservationIgnored private var isWanted = false
    /// Goes up with each browser made, so one that has been replaced can't speak for the new one.
    @ObservationIgnored private var generation = 0
    /// How long to leave it before looking again after the look failed, so a look that keeps failing doesn't spin.
    private static let retry: Duration = .seconds(1)

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
        isWanted = true
        guard browser == nil else { return }
        generation += 1
        let mine = generation
        let browser = NWBrowser(for: .bonjour(type: Remote.pairingService, domain: nil), using: NWParameters())
        self.browser = browser
        // Both handlers run on the browser's queue, so what they find is carried over to the main actor.
        browser.stateUpdateHandler = { [weak self] state in
            let blocked = Self.isBlocked(state)
            let failed = if case .failed = state { true } else { false }
            guard blocked != nil || failed else { return }
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                if let blocked { self.isBlocked = blocked }
                // A browser that has failed finds nothing more. Blocked, a new one would only fail the same way.
                if failed, blocked != true { self.lookAgainSoon() }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.macs(in: results)
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.macs = found
            }
        }
        browser.start(queue: DispatchQueue(label: "dev.queenbee.mobile.browser"))
    }

    func stop() {
        isWanted = false
        discard()
        macs = []
    }

    /// Looks afresh, if the list is on screen. For when the app comes back to the front: the browser may have
    /// died while it was away, or Local Network may have been turned on in Settings. The Macs already listed
    /// stay until the new look says otherwise.
    func restart() {
        guard isWanted else { return }
        discard()
        start()
    }

    private func discard() {
        browser?.cancel()
        browser = nil
        generation += 1
    }

    private func lookAgainSoon() {
        discard()
        let mine = generation
        Task {
            try? await Task.sleep(for: Self.retry)
            if isWanted, generation == mine { start() }
        }
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
    /// Nil if the wait is cancelled. There is no time limit: a Mac that is asleep may be back in an hour. The caller
    /// sets one by cancelling, as it does when it can also reach the Mac by address.
    /// `onAllowed` is called, on the browser's queue, when iOS has let the app look.
    nonisolated static func findListener(deviceID: String, macID: String, onAllowed: @escaping @Sendable () -> Void) async -> ListenerSearch? {
        // The record is asked for along with the name, because it is what says whose listener each one is.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Remote.service, domain: nil), using: NWParameters())
        let search = Search(browser, onAllowed: onAllowed)
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
        private let onAllowed: @Sendable () -> Void

        init(_ browser: NWBrowser, onAllowed: @escaping @Sendable () -> Void) {
            self.browser = browser
            self.onAllowed = onAllowed
        }

        func begin(_ continuation: CheckedContinuation<ListenerSearch?, Never>, isWanted: @escaping @Sendable (NWBrowser.Result) -> Bool) {
            let alreadyFinished = lock.withLock {
                if !isFinished { self.continuation = continuation }
                return isFinished
            }
            // Cancelled before it began.
            guard !alreadyFinished else { continuation.resume(returning: nil); return }
            browser.stateUpdateHandler = { [weak self] state in
                switch MacBrowser.isBlocked(state) {
                case .some(true): self?.finish(.blocked)
                case .some(false): self?.onAllowed()
                case nil: break
                }
                if case .failed = state { self?.finish(.failed) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let matches = results.filter(isWanted).map { result -> (endpoint: NWEndpoint, name: String?) in
                    if case .service(let name, _, _, _) = result.endpoint { return (result.endpoint, name) }
                    return (result.endpoint, nil)
                }
                if !matches.isEmpty { self?.finish(.found(matches)) }
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
