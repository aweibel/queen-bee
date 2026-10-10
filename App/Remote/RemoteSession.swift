import Foundation
import QueenBeeCore
import QueenBeeLink

/// One connected device: what it is sent, and the flow it has open.
final class RemoteSession {
    let connection: LinkConnection
    let device: PairedDevice
    private let outbox: AsyncStream<HostMessage>.Continuation
    private var pump: Task<Void, Never>?

    init(connection: LinkConnection, device: PairedDevice) {
        self.connection = connection
        self.device = device
        let (stream, continuation) = AsyncStream.makeStream(of: HostMessage.self)
        outbox = continuation
        // One sender, so messages leave in the order they were queued.
        pump = Task { [weak self] in
            for await message in stream {
                do { try await connection.send(message) } catch { connection.close(); return }
                self?.sent(message)
            }
        }
    }

    func send(_ message: HostMessage) { outbox.yield(message) }

    /// Called after each message has gone. Task 9 uses it to count terminal bytes.
    private func sent(_ message: HostMessage) {}

    /// Reads what the device sends until the connection ends.
    func run() async {
        while let message = try? await connection.receive(DeviceMessage.self) {
            switch message {
            case .open(let flowID): open(flowID.flatMap { id in AppServices.shared.allFlows.first { $0.flow.id == id } })
            case .hello: break
            }
        }
        close()
    }

    /// Task 9 fills this in.
    private func open(_ controller: FlowController?) {}

    func close() {
        open(nil)
        outbox.finish()
        connection.close()
    }
}
