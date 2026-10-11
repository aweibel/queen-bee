import Foundation
import QueenBeeCore

/// Does what a paired device asks, if that device may control this Mac.
///
/// Every command becomes one call the Mac's own buttons or keyboard already make, checked the way those
/// are. There is nothing here that adds a project, changes Settings, pairs or removes a device, or edits a
/// flow or a card, so no message from a device can do any of those.
enum RemoteCommands {
    /// Nil when it was done. Otherwise why not, in words the device shows the person.
    static func obey(_ command: RemoteCommand, from deviceID: String) async -> String? {
        let host = RemoteHost.shared
        // Asked of the list as it is now, for every command: "Can control" turned off a moment ago is off.
        guard host.isOn, let device = host.devices.devices.first(where: { $0.id == deviceID }), device.canControl else {
            return Remote.watchOnlyRefusal
        }
        // The size is checked here whatever the device's own app would have let through.
        if let problem = command.problem { return problem }
        let services = AppServices.shared
        guard let controller = services.allFlows.first(where: { $0.flow.id == command.flowID }) else {
            return "That flow is no longer on your Mac."
        }
        let name = Remote.oneLine(device.name)

        switch command {
        case .openOnMac:
            guard services.environment != nil else { return notReady }
            // What choosing the flow in the sidebar does to its sessions, without choosing it: the Mac's
            // window goes on showing what it showed.
            controller.open()
            return nil

        case .run(_, let command):
            guard !controller.isRunning else { return alreadyRunning }
            // The Run button is greyed out when the Start card has nothing to start with.
            if isBlank(command), !controller.canRun {
                return "Nothing to run yet: give the Start card something to start with and link it to a card."
            }
            let start = await controller.start(command: command, note: "Run started from \(name)")
            return start.began ? nil : start.status

        case .runFrom(_, let cardID, let text):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard !controller.isRunning else { return alreadyRunning }
            guard acceptsInput(card) else { return "Nothing to run: that card takes no input." }
            guard !isBlank(text) else { return "Nothing to run: there is no message to give \(card.name)." }
            let start = await controller.start(from: cardID, message: text, note: "Run started from \(name)")
            return start.began ? nil : start.status

        case .stop:
            guard controller.isRunning else { return "No run is going." }
            controller.noteFromDevice("Stopped from \(name)")
            await controller.stop()
            return nil

        case .approve(_, let holdID, let text):
            guard controller.holds.first(where: { $0.id == holdID })?.kind == .approval else { return holdGone }
            controller.approve(holdID, text: text)
            return nil

        case .reject(_, let holdID, let note):
            guard controller.holds.first(where: { $0.id == holdID })?.kind == .approval else { return holdGone }
            controller.reject(holdID, note: note)
            return nil

        case .allowScript(_, let holdID):
            guard let hold = controller.holds.first(where: { $0.id == holdID }), hold.kind == .script else { return holdGone }
            guard hold.needsAllow else { return "That command has already been allowed." }
            controller.allowScript(holdID)
            return nil

        case .refuseScript(_, let holdID):
            guard let hold = controller.holds.first(where: { $0.id == holdID }), hold.kind == .script else { return holdGone }
            // The Mac only offers "Don't run" while the command is waiting to be allowed.
            guard hold.needsAllow else { return "That command has already been allowed." }
            controller.refuseScript(holdID)
            return nil

        case .startSession(_, let cardID):
            guard let card = controller.flow.card(cardID) else { return cardGone }
            guard card.kind == .agent else { return "Only an agent card has a session to start." }
            guard services.environment != nil else { return notReady }
            controller.startSession(forCard: cardID)
            return nil

        case .prompt(_, let key, let text):
            guard let session = running(key, in: controller) else { return notRunning }
            session.send(text)
            let who = key == FlowController.orchestratorKey ? "the orchestrator" : controller.flow.card(key)?.name ?? "a session"
            controller.noteFromDevice("\(name) sent a message to \(who)")
            return nil

        case .keys(_, let key, let data):
            guard let session = running(key, in: controller) else { return notRunning }
            session.type(data)
            return nil
        }
    }

    private static let alreadyRunning = "A run is already going. Stop it before starting another."
    private static let cardGone = "That card is no longer in the flow."
    private static let holdGone = "That is no longer waiting for an answer."
    private static let notRunning = "That session isn't running."
    private static var notReady: String { AppServices.shared.problem ?? "Claude Code isn't ready yet." }

    private static func isBlank(_ text: String?) -> Bool { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A session that is there and running. Looked up without making one: asking the flow for a card's
    /// session makes it, and a device naming a card that has none must not.
    private static func running(_ key: String, in controller: FlowController) -> TerminalSession? {
        guard let session = controller.sessions[key], session.isLive else { return nil }
        return session
    }
}
