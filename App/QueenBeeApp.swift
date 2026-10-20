import AppKit
import QueenBeeCore
import Sparkle
import SwiftUI

@main
struct QueenBeeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Theme.modeKey) private var mode = Theme.Mode.system.rawValue
    @AppStorage("showsSidebar") private var showsSidebar = true
    @AppStorage("showsPanel") private var showsPanel = true
    private var services: AppServices { AppServices.shared }

    var body: some Scene {
        WindowGroup(id: "workspace") {
            WorkspaceView()
        }
        .defaultSize(width: 1500, height: 950)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.updater.checkForUpdates(nil) }
                    .disabled(!delegate.updateChecker.canCheck)
            }
            CommandGroup(after: .newItem) {
                Button("New Flow") { services.current?.project.newFlow() ?? services.projects.first?.newFlow() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(services.projects.isEmpty)
                Button("Add Project Folder…") { WorkspaceView.pickProjectFolder() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Flow") {
                Button("Run") { if let c = services.current { Task { await c.run() } } }
                    .keyboardShortcut("r")
                    .disabled(services.current == nil || services.current?.isRunning == true)
                Button("Stop") { if let c = services.current { Task { await c.stop() } } }
                    .keyboardShortcut(".")
                    .disabled(services.current?.isRunning != true)
                Divider()
                Button("Tidy Up") { services.current?.tidy() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(services.current == nil)
                Button("Group") { services.current?.groupSelection() }
                    .keyboardShortcut("g")
                    .disabled((services.current?.selection.cardIDs.count ?? 0) < 2)
                Button("Ungroup") { services.current?.ungroupSelection() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(services.current?.selectedGroup == nil)
                Divider()
                Button("Duplicate") { services.current?.duplicateSelection() }
                    .keyboardShortcut("d")
                    .disabled(services.current?.selection.cardIDs.isEmpty != false)
                Menu("Add Card") {
                    ForEach(CardKindMenu.kinds, id: \.self) { kind in
                        Button(kind.label) { services.current?.addCard(kind) }
                    }
                }
                .disabled(services.current == nil)
            }
            // The app's own Undo and Redo, so they reach the flow wherever the keyboard is:
            // after a click on the palette or a drag from a port, nothing on the canvas has it.
            CommandGroup(replacing: .undoRedo) {
                Button(services.current?.undoTitle ?? "Undo") { services.current?.undo() }
                    .keyboardShortcut("z")
                    .disabled(services.current == nil)
                Button(services.current?.redoTitle ?? "Redo") { services.current?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(services.current == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find a Card or Flow…") { services.showsFind.toggle() }
                    .keyboardShortcut("f")
                    .disabled(services.projects.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("Welcome to Queen Bee") { services.showsWelcome = true }
            }
            CommandGroup(after: .toolbar) {
                Button(showsSidebar ? "Hide Projects" : "Show Projects") { showsSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                Button(showsPanel ? "Hide Panel" : "Show Panel") { showsPanel.toggle() }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Zoom In") { services.current?.canvas?.zoom(by: 1.25) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { services.current?.canvas?.zoom(by: 0.8) }
                    .keyboardShortcut("-")
                Button("Actual Size") { services.current?.canvas?.zoomToActualSize() }
                    .keyboardShortcut("0")
                Button("Zoom to Fit") { services.current?.canvas?.zoomToFit() }
                    .keyboardShortcut("9")
                Divider()
                Menu("Appearance") {
                    // Buttons, not a Picker: a menu Picker changes the stored value but nothing
                    // would then tell the app to switch.
                    ForEach(Theme.Mode.allCases, id: \.rawValue) { item in
                        Toggle(item.label, isOn: Binding(get: { mode == item.rawValue }, set: { _ in
                            mode = item.rawValue
                            Theme.apply(item)
                        }))
                    }
                }
                Divider()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSignal: DispatchSourceSignal?
    /// Checks the release feed and installs new versions. Left idle in a debug build, which isn't a release.
    let updater: SPUStandardUpdaterController = {
        #if DEBUG
        SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        #else
        SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A second copy would fight the first over the socket: hand over to the first and quit.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != me }
        if let first = others.first, !TestHarness.isEnabled {
            first.activate()
            exit(0)
        }
        AppServices.shared.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.apply(Theme.mode)
        Notifier.start()

        // `kill` and a logout send SIGTERM, which would skip applicationWillTerminate. Turn it into a normal quit.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSignal = source

        // A second copy of the app, which is what a test run is, starts without a window. Ask for one.
        if TestHarness.isEnabled {
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                let file = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.items.contains { $0.keyEquivalent == "n" } }
                if let item = file?.items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }), let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                }
            }
        }
    }

    /// Whether the updater is free to check, kept current for the menu.
    private(set) lazy var updateChecker = UpdateChecker(updater.updater)

    /// Stops every session the app started, so no `claude` process outlives the app.
    func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.shutDown()
    }

    // Sessions belong to the app, not to a window: closing the window leaves them running,
    // and clicking the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Follows Sparkle's "can check now" flag, which changes as the updater starts up and while a check runs.
/// The menu reads `canCheck`, so its item turns on and off with it.
@Observable
final class UpdateChecker {
    private(set) var canCheck = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(_ updater: SPUUpdater) {
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheck = value }
        }
    }
}

enum CardKindMenu {
    static let kinds: [CardKind] = [.agent, .start, .ifElse, .switchCard, .and, .or, .prompt, .loop, .forEach, .approval, .script, .flow, .end, .note]
}

enum LaunchArguments {
    private static var used = false

    /// `--float` keeps a test copy's window above others without taking focus. Terminals stop
    /// painting in a hidden window, so a check that looks at the window needs it on screen.
    static var floats: Bool { CommandLine.arguments.contains("--float") }

    /// `--welcome` shows the first-run walk-through in a test copy, which otherwise skips it.
    static var welcome: Bool { CommandLine.arguments.contains("--welcome") }

    /// `--open <folder>` adds that folder to the sidebar and shows its first flow. Given more than
    /// once, every folder is added and the first one's flow is shown.
    static func takeFolders() -> [String] {
        guard !used else { return [] }
        used = true
        let args = CommandLine.arguments
        return args.indices.filter { args[$0] == "--open" && $0 + 1 < args.count }.map { args[$0 + 1] }
    }
}
