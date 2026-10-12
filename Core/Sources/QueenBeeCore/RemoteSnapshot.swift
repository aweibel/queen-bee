import Foundation

public enum RemoteSnapshot {
    /// The messages that take a device holding `old` to `new`, in a fixed order. Nothing when they are equal.
    public static func updates(from old: RemoteFlowSnapshot, to new: RemoteFlowSnapshot, revision: Int) -> [HostMessage] {
        let id = new.flow.id
        var out: [HostMessage] = []
        if new.flow != old.flow { out.append(.flow(id: id, revision: revision, flow: new.flow)) }
        if new.run != old.run { out.append(.run(id: id, state: new.run)) }
        if new.edit != old.edit { out.append(.edit(id: id, state: new.edit)) }
        if new.log != old.log {
            // Lines are only ever added to the end, until the log is cleared or an earlier run is put on show.
            let grew = new.log.count >= old.log.count && Array(new.log.prefix(old.log.count)) == old.log
            out.append(grew ? .log(id: id, lines: Array(new.log.dropFirst(old.log.count)), reset: false)
                            : .log(id: id, lines: new.log, reset: true))
        }
        if new.messages != old.messages {
            for link in Set(old.messages.keys).union(new.messages.keys).sorted() where new.messages[link] != old.messages[link] {
                out.append(.messages(id: id, link: link, all: new.messages[link] ?? []))
            }
        }
        if new.runs != old.runs { out.append(.history(id: id, runs: new.runs)) }
        return out
    }
}
