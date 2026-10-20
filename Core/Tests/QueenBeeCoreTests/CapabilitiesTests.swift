import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct CapabilitiesTests {
    /// The settings a card can be given that aren't about what it does.
    private static let geometry: Set<String> = ["name", "x", "y", "width", "height"]

    /// "permissionMode" as the orchestrator's tools spell it: "permission_mode".
    private func key(for field: String) -> String {
        if field == "flowRef" { return "flow" }
        return field.reduce(into: "") { $0 += $1.isUppercase ? "_" + $1.lowercased() : String($1) }
    }

    @Test func everySettingACardCanTakeIsDescribed() {
        let described = Set(Capabilities.settingKinds.map(\.key))
        for child in Mirror(reflecting: CardPatch()).children {
            guard let field = child.label, !Self.geometry.contains(field) else { continue }
            #expect(described.contains(key(for: field)), "CardPatch.\(field) is a setting the orchestrator is never told about. Add it to Capabilities.card(_:).")
        }
    }

    @Test func everyDescribedSettingCanReallyBeSet() async throws {
        // A value of the right type for each setting, so the tools take it.
        let samples: [String: JSONValue] = [
            "instructions": "Be brief", "model": "opus", "effort": "high", "permission_mode": "plan", "cwd": "/tmp/x", "browser": true,
            "command": "echo hi", "check": "contains", "value": "DONE", "max_tries": 4, "branches": ["x", "y"],
            "template": "{{message}}", "save_to": "out.md", "text": "Check this", "flow": "",
        ]
        for card in Capabilities.cards {
            for setting in card.settings {
                let sample = try #require(samples[setting.key], "No sample value for \(setting.key): add one to this test.")
                let host = FakeHost()
                _ = await Tools.call(name: "add_card", arguments: ["kind": .string(card.kind.rawValue), "name": "C"], host: host)
                let before = try #require(await host.flow.resolveCard("C"))
                let result = await Tools.call(name: "update_card", arguments: ["card": "C", .init(setting.key): sample], host: host)
                #expect(!result.isError, "\(card.kind.rawValue).\(setting.key): \(result.text)")
                // "flow" names another flow, which a lone test flow doesn't have, so it is only checked for being taken.
                if setting.key != "flow" {
                    #expect(await host.flow.resolveCard("C") != before, "\(card.kind.rawValue).\(setting.key) is described but setting it changes nothing.")
                }
            }
        }
    }

    @Test func aSettingOnTheWrongKindOfCardIsRefused() async {
        let host = FakeHost()
        let result = await Tools.call(name: "add_card", arguments: ["kind": "note", "command": "ls"], host: host)
        #expect(result.isError && result.text.contains("command"))
    }

    @Test func theToolsTakeTheirSettingsFromTheSameList() throws {
        let properties = try #require(Tools.definitions.first { $0.name == "update_card" }?.inputSchema["properties"]?.objectValue)
        for (key, kinds) in Capabilities.settingKinds {
            let about = try #require(properties[key]?["description"]?.stringValue)
            for kind in kinds { #expect(about.contains("\(kind.rawValue): ")) }
        }
        #expect(properties["max_tries"]?["maximum"] == 50)
        #expect(properties["browser"]?["type"] == "boolean")
    }

    @Test func theReferenceCoversEveryCardEveryBrowserToolAndEveryOrchestratorTool() {
        let reference = Capabilities.reference
        for kind in CardKind.allCases { #expect(reference.contains("### \(kind.label) (`\(kind.rawValue)`)")) }
        for tool in BrowserTools.definitions { #expect(reference.contains("- `\(tool.name)` (")) }
        for tool in Tools.definitions { #expect(reference.contains("`\(tool.name)`")) }
        for limit in BrowserTools.limits { #expect(reference.contains(limit)) }
        #expect(reference.contains("- Outputs: yes, no"))
        #expect(reference.contains("- Outputs: one per branch name, plus other"))
        #expect(reference.contains("- Size when added: 560 by 380 points"))
        // The browser tools that act are the ones that ask.
        #expect(reference.contains("- `click` (asks the person first"))
        #expect(reference.contains("- `read` (never asks the person)"))
    }

    @Test func theReferenceStatesTheLimitsTheEngineAndScriptCardsKeep() {
        let reference = Capabilities.reference
        #expect(reference.contains("at most \(Engine.maxDeliveries) messages"))
        #expect(reference.contains(Capabilities.runLimit))
        #expect(reference.contains("hasn't finished after \(Int(Capabilities.scriptTimeout.components.seconds / 60)) minutes"))
        #expect(Capabilities.scriptOutputLimit == 20_000 && reference.contains("the last 20,000 characters"))
        #expect(reference.contains("takes longer than \(Int(Engine.judgeTimeout.components.seconds)) seconds counts as no"))
        #expect(reference.contains("A flow has one run at a time"))
        #expect(reference.contains("Inside a loop, it passes on one per round"))
    }

    @Test func theSavedFileIsWhatTheCodeSaysNow() throws {
        let saved = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("CAPABILITIES.md")
        let text = try String(contentsOf: saved, encoding: .utf8)
        #expect(text == Capabilities.file, "CAPABILITIES.md is out of date. Run ./scripts/build.sh, which rewrites it, and commit the result.")
    }
}
