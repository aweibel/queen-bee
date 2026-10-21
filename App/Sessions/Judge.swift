import Foundation
import QueenBeeCore
import Subprocess
import System

/// Judges plain-English conditions with a one-shot Haiku call. `--restricted` keeps the
/// person's own plugins and hooks out of it; `--json-schema` pins the answer's shape.
nonisolated struct ClaudeJudge: Judge {
    let claude: String
    let environment: [String: String]

    func holds(statement: String, message: String) async -> Bool? {
        let schema: JSONValue = ["type": "object", "properties": ["verdict": ["type": "string", "enum": ["yes", "no"]]], "required": ["verdict"]]
        guard let verdict = await ask(Checks.judgePrompt(statement: statement, message: message), schema: schema, field: "verdict") else { return nil }
        return verdict == "yes" ? true : verdict == "no" ? false : nil
    }

    func pick(branches: [String], message: String) async -> String? {
        let options: [JSONValue] = (branches + ["other"]).map { .string($0) }
        let schema: JSONValue = ["type": "object", "properties": ["branch": ["type": "string", "enum": .array(options)]], "required": ["branch"]]
        guard let branch = await ask(Checks.pickPrompt(branches: branches, message: message), schema: schema, field: "branch") else { return nil }
        return Checks.parseBranch(branch, branches: branches)
    }

    /// The prompt goes on standard input: it holds the whole message being judged, which on the command line could be
    /// more than a process may be started with. The engine gives up on a call that takes too long, and cancelling it
    /// stops the process.
    private func ask(_ prompt: String, schema: JSONValue, field: String) async -> String? {
        let args = ["-p", "--model", "haiku", "--restricted", "--no-session-persistence",
                    "--output-format", "json", "--json-schema", schema.text()]
        var env: [Environment.Key: String] = [:]
        for (k, v) in environment { if let key = Environment.Key(rawValue: k) { env[key] = v } }
        guard let result = try? await run(.path(FilePath(claude)), arguments: Arguments(args), environment: .custom(env),
                                          input: .string(prompt), output: .string(limit: 2_000_000), error: .discarded),
              let start = result.standardOutput.firstIndex(of: "{"),
              let json = try? JSONValue.parse(Data(result.standardOutput[start...].utf8)) else { return nil }
        return json["structured_output"]?[field]?.stringValue
    }
}
