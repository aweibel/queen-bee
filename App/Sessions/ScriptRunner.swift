import Foundation
import QueenBeeCore
import Subprocess
import System

/// Runs a Script card's command, and remembers which commands the person has allowed.
enum ScriptRunner {
    /// A command that hasn't finished by now is stopped and counts as failed. Declared with the card's capabilities.
    nonisolated static let timeout = Capabilities.scriptTimeout
    /// As much of what a command printed as is passed on: the end of it, where a failure usually is.
    nonisolated static let outputLimit = Capabilities.scriptOutputLimit
    /// As much as is read at all. A command that prints more than this is counted as failed.
    nonisolated static let readLimit = 8_000_000
    /// The message is on standard input in full. The copy in the environment is cut short,
    /// since a huge environment stops a command from starting at all.
    nonisolated static let environmentLimit = 60_000

    /// Runs `command` in a login shell in `folder`, with the message on standard input and in
    /// QB_MESSAGE. Returns whether it exited with 0, and what it printed.
    nonisolated static func run(_ command: String, message: String, from: String, in folder: URL,
                                environment: ResolvedEnvironment) async -> (passed: Bool, output: String) {
        var variables: [Environment.Key: String] = [:]
        for (key, value) in environment.variables(adding: ["QB_MESSAGE": String(message.prefix(environmentLimit)), "QB_FROM": from]) {
            if let key = Environment.Key(rawValue: key) { variables[key] = value }
        }
        let work = Task { () -> (Bool, String) in
            let result = try await Subprocess.run(
                .path("/bin/zsh"), arguments: ["-lc", command], environment: .custom(variables),
                workingDirectory: FilePath(folder.path), input: .string(message),
                output: .string(limit: readLimit), error: .string(limit: readLimit))
            let printed = [result.standardOutput, result.standardError].compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
            return (result.terminationStatus.isSuccess, String(printed.suffix(outputLimit)))
        }
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        defer { watchdog.cancel() }
        do {
            let (passed, printed) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            return (passed, printed)
        } catch is CancellationError {
            return (false, "The command was stopped before it finished.")
        } catch let error as SubprocessError where error.code == .outputLimitExceeded {
            return (false, "The command printed more than \(readLimit / 1_000_000) MB, which is more than Queen Bee reads, so it counts as failed.")
        } catch {
            return (false, "The command couldn't be started: \(error.localizedDescription)")
        }
    }

    // MARK: Allowed commands

    // A Script card runs with no permission prompt, so only a command the person has typed or
    // allowed themselves may run. One command is remembered per card: the latest they approved.
    static func isAllowed(_ command: String, scope: String, cardID: String) -> Bool {
        ConsentStore.scripts.isGranted(command, scope: scope, cardID: cardID)
    }

    static func allow(_ command: String, scope: String, cardID: String) {
        ConsentStore.scripts.grant(command, scope: scope, cardID: cardID)
    }
}
