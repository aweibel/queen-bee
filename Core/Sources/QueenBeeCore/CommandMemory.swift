import Foundation

/// What the Mac remembers of the commands each device sent lately, so a command a device sends again after a
/// dropped link, with the same id, is never done twice: it is answered with what became of it the first time,
/// or, while that is still being done, once it has been.
///
/// A command is named by the device, the device's epoch and its id: see `RemoteHello.epoch`. A device that comes
/// back with a new epoch has started afresh, and what it sent before is forgotten. Only `kept` commands of each
/// device are remembered, the newest. `Waiter` is whatever stands for a connection waiting for an answer.
public struct CommandMemory<Waiter> {
    /// What the Mac knows of a command that has just arrived.
    public enum Seen: Equatable {
        /// Never seen: it is to be done, and is remembered as being done.
        case new
        /// Being done now, from when it was first sent. The waiter is answered when it has been.
        case running
        /// Done already, with this answer: nil for done, or the refusal.
        case done(String?)
    }

    public let kept: Int
    private enum Entry {
        case running([Waiter])
        case done(String?)
    }
    private struct Device {
        var epoch: String
        var order: [Int] = []
        var entries: [Int: Entry] = [:]
    }
    private var devices: [String: Device] = [:]

    /// Far more than a device sends in the half a minute it waits for an answer.
    public init(kept: Int = 300) { self.kept = kept }

    /// A command has arrived. A new one is remembered as being done; one being done keeps `waiter` to answer.
    public mutating func arrive(device: String, epoch: String, id: Int, waiter: Waiter) -> Seen {
        var entry = devices[device].flatMap { $0.epoch == epoch ? $0 : nil } ?? Device(epoch: epoch)
        defer { devices[device] = entry }
        switch entry.entries[id] {
        case .done(let refusal):
            return .done(refusal)
        case .running(var waiting):
            waiting.append(waiter)
            entry.entries[id] = .running(waiting)
            return .running
        case nil:
            entry.entries[id] = .running([])
            entry.order.append(id)
            // The oldest that are done go first. One still being done is let go only when nothing else can be.
            while entry.order.count > kept {
                let index = entry.order.firstIndex { if case .done = entry.entries[$0] { true } else { false } } ?? 0
                entry.entries[entry.order.remove(at: index)] = nil
            }
            return .new
        }
    }

    /// A command has been done, or refused. Returns who else is waiting to hear, each to be told the same.
    public mutating func finish(device: String, epoch: String, id: Int, refusal: String?) -> [Waiter] {
        guard var entry = devices[device], entry.epoch == epoch, case .running(let waiting) = entry.entries[id] else { return [] }
        entry.entries[id] = .done(refusal)
        devices[device] = entry
        return waiting
    }

    /// The device was unpaired or paired again.
    public mutating func forget(device: String) { devices[device] = nil }

    /// How many commands of a device are remembered, for a test.
    public func count(of device: String) -> Int { devices[device]?.order.count ?? 0 }
}
