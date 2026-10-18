import Foundation
import Observation
import QueenBeeCore

/// One project folder in the sidebar and the flows saved in it.
@Observable
final class ProjectModel {
    let root: URL
    @ObservationIgnored let store: FlowStore
    @ObservationIgnored private var watcher: FileWatcher?
    private(set) var controllers: [FlowController] = []
    /// Flow files that couldn't be read. Listed, never written.
    private(set) var unreadable: [URL] = []
    /// The browser the project's agent cards share. It only starts when a card with a browser needs it.
    @ObservationIgnored private(set) lazy var browser = BrowserHost(projectRoot: root, support: AppServices.shared.supportDirectory)

    var name: String { root.lastPathComponent }

    /// The flow with this id, if it is open in the project.
    func controller(_ id: String) -> FlowController? { controllers.first { $0.flow.id == id } }

    /// Every flow in the project, for working out how they nest.
    var nesting: Nesting { Nesting(flows: controllers.map(\.flow)) }

    init(root: URL) {
        self.root = root
        store = FlowStore(root: root)
        let loaded = store.loadAll()
        unreadable = loaded.unreadable
        controllers = loaded.flows.map { FlowController(flow: $0.flow, fileURL: $0.url, project: self) }
        controllers.forEach { AppServices.shared.register($0) }
        // A flow file that appears later, for instance one an agent wrote, is picked up without reopening the project.
        watcher = FileWatcher(url: store.directory) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
    }

    /// Takes in flow files that have appeared in the folder since it was read. Flows already
    /// open are left exactly as they are.
    func rescan() {
        let loaded = store.loadAll()
        let known = Set(controllers.map { $0.fileURL.standardizedFileURL.path })
        var ids = Set(controllers.map(\.flow.id))
        for file in loaded.flows where !known.contains(file.url.standardizedFileURL.path) && ids.insert(file.flow.id).inserted {
            let controller = FlowController(flow: file.flow, fileURL: file.url, project: self)
            controllers.append(controller)
            AppServices.shared.register(controller)
        }
        let unread = loaded.unreadable.filter { !known.contains($0.standardizedFileURL.path) }
        if unread != unreadable { unreadable = unread }
    }

    /// A new flow made to sit inside a Flow card: an Input to receive the message and an
    /// Output for the answer that goes back.
    func newSubflow(named wanted: String) -> FlowController? {
        var name = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Sub-flow" }
        var n = 2
        let base = name
        while controllers.contains(where: { $0.flow.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        var flow = Flow(name: name)
        flow.isSubflow = true
        _ = try? flow.addCard(kind: .start, name: "Input", x: 240, y: 120)
        _ = try? flow.addCard(kind: .end, name: "Output", x: 600, y: 120)
        guard let url = try? store.save(flow, to: nil) else { return nil }
        let controller = FlowController(flow: flow, fileURL: url, project: self)
        controllers.append(controller)
        AppServices.shared.register(controller)
        return controller
    }

    /// A new flow with its Start card. With no name it is called "Flow" and the next number. `select` puts it
    /// on the canvas, which is what the person at this Mac wants and what a paired device must not do.
    @discardableResult
    func newFlow(named wanted: String? = nil, select: Bool = true) -> FlowController? {
        var n = controllers.count + 1
        var name = "Flow \(n)"
        while controllers.contains(where: { $0.flow.name == name }) { n += 1; name = "Flow \(n)" }
        if let wanted = wanted?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty { name = wanted }
        var flow = Flow(name: name)
        _ = try? flow.addCard(kind: .start, x: 240, y: 120)
        guard let url = try? store.save(flow, to: nil) else { return nil }
        let controller = FlowController(flow: flow, fileURL: url, project: self)
        controllers.append(controller)
        AppServices.shared.register(controller)
        if select { AppServices.shared.selectedFlowID = flow.id }
        return controller
    }

    /// Deletes a flow and its file. With `toTrash` the file goes to the Trash instead, which is how a paired
    /// device's delete is done: a mistake there, or a device in the wrong hands, destroys nothing. False
    /// when the file couldn't be moved there, and then the flow is still in the project.
    @discardableResult
    func delete(_ controller: FlowController, toTrash: Bool = false) -> Bool {
        if toTrash {
            // Saved first, so what goes to the Trash is the flow as it last was. Its sessions are stopped only once
            // the file has gone: a flow that stays in the project keeps its agents and browser tabs running.
            controller.saveNow()
            guard Self.trash(controller.fileURL) else { return false }
            controller.shutDown(saving: false)
        } else {
            // Saves what was not saved yet, so the file is the flow as it last was.
            controller.shutDown()
            try? store.delete(controller.fileURL)
        }
        controller.forgetHistory()
        AppServices.shared.unregister(flowID: controller.flow.id)
        controllers.removeAll { $0 === controller }
        if AppServices.shared.selectedFlowID == controller.flow.id {
            AppServices.shared.selectedFlowID = (controllers.first ?? AppServices.shared.allFlows.first)?.flow.id
        }
        return true
    }

    private static func trash(_ url: URL) -> Bool {
        #if DEBUG
        // A test copy of the app puts what it throws away in a folder of the test's, not in the Trash of whoever runs the tests.
        if TestHarness.isEnabled, let folder = ProcessInfo.processInfo.environment["QB_TRASH_DIR"], !folder.isEmpty {
            let into = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
            return (try? FileManager.default.moveItem(at: url, to: into.appendingPathComponent(url.lastPathComponent))) != nil
        }
        #endif
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// Stops every session this project started.
    func close() {
        watcher?.stop()
        controllers.forEach { $0.shutDown(); AppServices.shared.unregister(flowID: $0.flow.id) }
        browser.terminate()
    }
}
