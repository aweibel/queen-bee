import Foundation

public enum RemoteSnapshot {
    /// The messages that take a device holding `old` to `new`, in a fixed order. Nothing when they are equal.
    /// `historyChanges` is for a device that takes `.historyChanged`: see `RemoteFeature.historyChanges`.
    public static func updates(from old: RemoteFlowSnapshot, to new: RemoteFlowSnapshot, revision: Int,
                               historyChanges: Bool = false) -> [HostMessage] {
        let id = new.flow.id
        var out: [HostMessage] = []
        if new.flow != old.flow { out.append(.flow(id: id, revision: revision, flow: new.flow)) }
        if new.run != old.run { out.append(.run(id: id, state: new.run)) }
        if new.edit != old.edit { out.append(.edit(id: id, state: new.edit)) }
        if new.log != old.log {
            // Lines are only ever added to the end, until the log is cleared or an earlier run is put on show.
            if let added = linesAdded(from: old.log, to: new.log) {
                out.append(.log(id: id, lines: added, reset: false))
            } else {
                out.append(.log(id: id, lines: new.log, reset: true))
            }
        }
        if new.messages != old.messages {
            for link in Set(old.messages.keys).union(new.messages.keys).sorted() where new.messages[link] != old.messages[link] {
                out.append(.messages(id: id, link: link, all: new.messages[link] ?? []))
            }
        }
        if new.runs != old.runs {
            if historyChanges {
                let change = historyChange(from: old.runs, to: new.runs)
                out.append(.historyChanged(id: id, runs: change.runs, order: change.order))
            } else {
                out.append(.history(id: id, runs: new.runs))
            }
        }
        return out
    }

    /// What takes a device's list of earlier runs from `old` to `new`: the runs it hasn't got as they are now,
    /// and the ids of all of them in order. A run ending sends that one run, not the twenty before it.
    public static func historyChange(from old: [RunRecord], to new: [RunRecord]) -> (runs: [RunRecord], order: [String]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return (new.filter { before[$0.id] != $0 }, new.map(\.id))
    }

    /// A device's list of earlier runs once a `.historyChanged` has been taken: those named in `order`, from
    /// `changed` or else from what it had. A run named that it has neither of can't be shown, and is left out.
    public static func applying(_ changed: [RunRecord], order: [String], to old: [RunRecord]) -> [RunRecord] {
        let known = Dictionary((old + changed).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return order.compactMap { known[$0] }
    }

    /// The lines added to the end of a log, or nil when it changed some other way and is to be sent whole. A log
    /// at its cap drops its oldest lines as new ones come, so what it held still counts as there when the end
    /// of it is the start of the new log, matched line by line with their ids: the device drops the same old
    /// lines when it adds these, which is only so when the new log is exactly at the cap.
    static func linesAdded(from old: [LogLine], to new: [LogLine]) -> [LogLine]? {
        if new.count >= old.count, new.starts(with: old) { return Array(new.dropFirst(old.count)) }
        guard new.count == LogLine.mostKept, let first = new.first, let dropped = old.firstIndex(where: { $0.id == first.id }) else { return nil }
        let kept = old[dropped...]
        guard kept.count <= new.count, new.starts(with: kept) else { return nil }
        return Array(new.dropFirst(kept.count))
    }

    /// A log as a device holds it once `lines` have been added to the end: no longer than the Mac's.
    public static func appending(_ lines: [LogLine], to log: [LogLine]) -> [LogLine] {
        let all = log + lines
        // Only ever trimmed when lines were added: a log the Mac sent whole is kept as it came.
        return lines.isEmpty || all.count <= LogLine.mostKept ? all : Array(all.suffix(LogLine.mostKept))
    }
}

extension RemoteFlowSnapshot {
    /// Whether the Mac offers Retry on a card: the last run stopped there, no run is going, and a message
    /// reached the card in that run, which is what it is given again.
    public func canRetry(_ cardID: String) -> Bool {
        guard run.marks[cardID]?.failed == true, !run.isRunning else { return false }
        return flow.links(into: cardID).contains { !(messages[$0.id] ?? []).isEmpty }
    }
}
