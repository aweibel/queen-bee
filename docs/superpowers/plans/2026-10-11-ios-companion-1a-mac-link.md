# iOS Companion, Stage 1A: The Mac Side of the Link — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Mac app can be paired with a device over local Wi-Fi and streams it every flow, its run state and its terminals, proven by a command-line test client.

**Architecture:** Plain data types and every wire message live in `QueenBeeCore`, which gains iOS as a platform. A new package target, `QueenBeeLink`, holds the encrypted connection. The Mac app gets `App/Remote/`: one listener per paired device, a publisher that diffs each flow's state and sends what changed, and a terminal feed. No iOS code is written in this plan.

**Tech Stack:** Swift 6, Swift Testing, Network framework (`NWListener`/`NWConnection` with a TLS pre-shared key), Security (Keychain), SwiftTerm 1.99.0, XcodeGen, the existing `scripts/e2e.py`.

**Spec:** `docs/superpowers/specs/2026-10-11-ios-companion-design.md`

---

## Scope

Stage 1 of the spec ("Link and mirror") is split in two, because each half works and is testable alone:

- **1A (this plan):** everything on the Mac, plus a test client. Done when `./scripts/e2e.py remote` passes.
- **1B (next plan):** the iOS app. Written after 1A, because Task 2 here decides what the terminal stream is.

Decisions made while planning that go beyond the spec:

- **One listener per paired device.** Each device has its own key, and the Mac runs one listener per device, each locked to that device's key. Removing a device stops its listener and deletes its key. A shared key would let a removed device still read other devices' traffic.
- **Pairing uses its own short-lived listener**, advertised as `_queenbee-pair._tcp` and locked to the one-time secret.
- **Roles are not synced yet.** They are only needed for editing, which is stage 3.
- **Looking at an earlier run on the Mac changes what a device shows too.** The device gets the full run history, so 1B can add its own run picker.
- **A flow the Mac has never opened shows its sessions as "Not started" on a device.** Opening it from a device does not start sessions in stage 1, which is watch-only.

## Rules for every commit

The repository is public. Before every commit, run `./scripts/check-clean.sh` (made in Task 1) and read the staged diff. Never commit a team id, key, token, provisioning profile, home folder path, real device name or network address. Tests generate their own secrets when they run.

## File map

| File | Responsibility |
|---|---|
| `scripts/check-clean.sh` (new) | Fails if a tracked file holds something that must stay local |
| `.gitignore`, `.github/workflows/tests.yml` (modify) | Ignore signing files; scan every push |
| `Core/Package.swift` (modify) | iOS platform; `QueenBeeLink` target |
| `Core/Sources/QueenBeeCore/RunState.swift` (new) | Run data types moved out of the app |
| `Core/Sources/QueenBeeCore/Remote.swift` (new) | Every message the two apps exchange |
| `Core/Sources/QueenBeeCore/RemoteSnapshot.swift` (new) | A flow's whole remote state, and what to send when it changes |
| `Core/Sources/QueenBeeLink/LinkSecurity.swift` (new) | Keys, the pairing code, TLS settings |
| `Core/Sources/QueenBeeLink/LinkConnection.swift` (new) | An encrypted connection and listener carrying frames |
| `App/Remote/TerminalFeed.swift` (new) | A session's terminal as bytes a remote terminal can be fed |
| `App/Remote/RemoteDevices.swift` (new) | Paired devices and their keys |
| `App/Remote/RemoteHost.swift` (new) | Listeners, pairing, the flow list |
| `App/Remote/RemoteSession.swift` (new) | One connected device: the flow it has open and what it is sent |
| `App/Views/RemoteSettingsView.swift` (new) | The Remote section of Settings and the pairing sheet |
| `App/FlowController.swift`, `App/Sessions/TerminalSession.swift`, `App/Sessions/UsageReader.swift` (modify) | Lose the moved types |
| `App/AppServices.swift`, `App/Views/SettingsView.swift`, `App/Views/SidebarView.swift`, `App/Info.plist`, `App/Testing/TestHarness.swift`, `project.yml` (modify) | Wiring |
| `Tools/RemoteCheck/main.swift` (new) | The test client |
| `scripts/e2e.py` (modify) | The `remote` scenario |
| `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md` (modify) | Docs |

## Commands used throughout

- Core tests: `cd Core && swift test 2>&1 | tail -5`
- Build the app: `./scripts/build.sh` (prints `** BUILD SUCCEEDED **` on success)
- End-to-end: `./scripts/e2e.py <scenario>`

---

### Task 1: Guard rails for a public repository

**Files:**
- Create: `scripts/check-clean.sh`
- Modify: `.gitignore`, `.github/workflows/tests.yml`, `CONTRIBUTING.md`

- [ ] **Step 1: Write the check**

Create `scripts/check-clean.sh`:

```sh
#!/bin/sh
# Fails if a tracked file holds something that must stay on one machine: signing files,
# an Apple team id, a private key, or a home folder path. Run it before every push.
set -e
cd "$(dirname "$0")/.."
bad=0
if git ls-files | grep -E '\.(mobileprovision|p12|cer|xcarchive)$|(^|/)Local\.xcconfig$'; then
  echo "^ signing files must not be committed"; bad=1
fi
if git grep -nE 'DEVELOPMENT_TEAM *[:=] *"?[A-Z0-9]{10}' -- . ':!scripts/check-clean.sh'; then
  echo "^ an Apple team id must not be committed"; bad=1
fi
if git grep -nE 'BEGIN [A-Z ]*PRIVATE KEY' -- . ':!scripts/check-clean.sh'; then
  echo "^ a private key must not be committed"; bad=1
fi
if git grep -nE '/Users/[A-Za-z][A-Za-z0-9_-]+/' -- . ':!scripts/check-clean.sh'; then
  echo "^ a home folder path must not be committed"; bad=1
fi
[ "$bad" = 0 ] && echo "clean"
exit "$bad"
```

- [ ] **Step 2: Run it**

Run: `chmod +x scripts/check-clean.sh && ./scripts/check-clean.sh`
Expected: `clean`

- [ ] **Step 3: Prove it catches a leak**

Run: `printf 'DEVELOPMENT_%s = ABCDE12345\n' TEAM > Leak.xcconfig && git add Leak.xcconfig && ./scripts/check-clean.sh; echo "exit $?"; git rm -q --cached Leak.xcconfig && rm Leak.xcconfig`
Expected: a line naming `Leak.xcconfig`, then `exit 1`

- [ ] **Step 4: Ignore signing files**

Append to `.gitignore`:

```
# Signing details stay on the machine that made them.
Local.xcconfig
*.mobileprovision
*.p12
*.cer
*.xcarchive
```

- [ ] **Step 5: Scan every push**

In `.github/workflows/tests.yml`, add this job under `jobs:`, beside `core`:

```yaml
  clean:
    name: Nothing private in the repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Signing details, keys and home paths
        run: ./scripts/check-clean.sh
      - name: Secrets
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 6: Tell contributors**

In `CONTRIBUTING.md`, add a line to the list of things to do before opening a pull request: `- Run ./scripts/check-clean.sh. It fails if a signing file, team id, key or home folder path is about to be committed.`

- [ ] **Step 7: Commit**

```bash
git add scripts/check-clean.sh .gitignore .github/workflows/tests.yml CONTRIBUTING.md
git commit -m "Check that nothing private is committed"
```

---

### Task 2: Proof — a session's terminal as a stream (decision gate)

This task is an experiment. It is the one task in the plan whose code is not given in full, because its job is to find out which of three ways works. It must end with the interface in Step 1 implemented and Step 5's test passed.

**What planning found:** SwiftTerm 1.99.0 sends a session's output from the process straight into its renderer on a background thread (`LocalProcessTerminalViewProcessAdapter` in `Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`). `LocalProcessTerminalView.dataReceived(slice:)` is still declared `open` but is no longer called, so overriding it gives nothing. The only hook is `setProcessOutputHandler`, which says output arrived but carries no bytes.

**Files:**
- Create: `App/Remote/TerminalFeed.swift`
- Modify: `App/Sessions/TerminalSession.swift`, `App/Testing/TestHarness.swift`

- [ ] **Step 1: Fix the interface the rest of the plan builds on**

Create `App/Remote/TerminalFeed.swift` with the protocol. The implementing class is added in Step 3.

```swift
import Foundation
import QueenBeeCore

/// A session's terminal as bytes a remote terminal can be fed.
protocol TerminalFeed: AnyObject {
    /// Bytes that take a blank terminal to what this one shows now. Always has `reset` set.
    func snapshot() -> TerminalChunk
    /// `handler` is called on the main actor with each further chunk, until the token is removed.
    func addListener(_ handler: @escaping (TerminalChunk) -> Void) -> UUID
    func removeListener(_ token: UUID)
}
```

`TerminalChunk` is defined in Task 4 (`reset: Bool`, `cols: Int`, `rows: Int`, `data: Data`). For this task, declare it temporarily at the bottom of this file as `struct TerminalChunk { var reset: Bool; var cols: Int; var rows: Int; var data: Data }` and delete that line in Task 4.

- [ ] **Step 2: Try the three ways in this order, and stop at the first that passes Step 5**

**Way A — send the screen, not the output.** No SwiftTerm changes, and joining late needs no replay.
1. In `TerminalSession.init`, call `view.setProcessOutputHandler { ... }`. It runs off the main thread, so hop to the main actor and coalesce to one update every 66 ms.
2. On each update, read the visible screen from `view.getTerminal()` and write it out as escape sequences: clear (`ESC[2J ESC[H`), then for each row `ESC[<row>;1H`, the colour and style changes, and the text, then the cursor position and whether it is shown.
3. Read `Sources/SwiftTerm/Terminal.swift` and `Sources/SwiftTerm/Buffer.swift` in `build/SourcePackages/checkouts/SwiftTerm` for the public way to read a cell and its attribute (`getLine(row:)`, `getCharData(col:row:)`, `Attribute`, `getCursorLocation()`), and for whether reading from the main actor is safe while the background thread parses. If there is no safe public read, Way A fails.
4. Every chunk has `reset` set. Send only when the bytes differ from the last chunk.
5. Cost of this way: the device sees the screen but not the scrollback.

**Way B — own the process link.** Replace `LocalProcessTerminalView` in `TerminalSession` with a subclass of `TerminalView` that owns a `LocalProcess` (public `init(delegate:dispatchQueue:directDelivery:)`) and is its `LocalProcessDelegate`. `dataReceived(slice:)` then feeds the view with `feed(byteArray:)` and hands the same bytes to the feed. Keep the last 256 KB per session; `snapshot()` returns that with `reset` set, then the session is made to repaint by setting its window size one row smaller and back (`process.updateWindowSize`). `TerminalViewDelegate` has more requirements than `LocalProcessTerminalView` shows; copy what `LocalProcessTerminalView` does for each.

**Way C — add a hook to SwiftTerm.** Fork SwiftTerm, add a byte callback to `LocalProcessTerminalViewProcessAdapter.dataReceived`, and point `project.yml` at the fork's commit. Then as Way B from "Keep the last 256 KB".

- [ ] **Step 3: Implement the chosen way**

Add the implementing class to `App/Remote/TerminalFeed.swift`, and to `TerminalSession`:

```swift
    /// What the terminal shows, for a paired device.
    @ObservationIgnored private(set) lazy var feed: TerminalFeed = makeFeed()
```

`makeFeed()` returns the class from this step. Nothing may run for a session until `feed` is first read, so the Mac app is unchanged while Remote is off.

- [ ] **Step 4: Add a mirror window for the test**

In `App/Testing/TestHarness.swift`, inside `#if DEBUG`, add a case to `handle` and the helper it calls:

```swift
        case "mirror":
            guard let cardID else { return ["error": "mirror needs card"] }
            MirrorWindow.show(controller.session(forCard: cardID))
            return [:]
```

```swift
#if DEBUG
/// A second terminal fed only by a session's feed, to compare with the real one by eye.
enum MirrorWindow {
    private static var window: NSWindow?
    private static var held: (feed: TerminalFeed, token: UUID)?

    static func show(_ session: TerminalSession) {
        if let held { held.feed.removeListener(held.token) }
        let first = session.feed.snapshot()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
        view.font = Theme.mono(12)
        view.getTerminal().resize(cols: first.cols, rows: first.rows)
        view.feed(byteArray: ArraySlice(first.data))
        let token = session.feed.addListener { chunk in
            if chunk.reset { view.getTerminal().resize(cols: chunk.cols, rows: chunk.rows) }
            view.feed(byteArray: ArraySlice(chunk.data))
        }
        held = (session.feed, token)
        let made = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        made.title = "Mirror of \(session.key)"
        made.contentView = view
        made.isReleasedWhenClosed = false
        made.makeKeyAndOrderFront(nil)
        window = made
    }
}
#endif
```

Add `import SwiftTerm` to the file if it is not there.

- [ ] **Step 5: The test that decides it**

Build (`./scripts/build.sh`), then start a test copy with a flow that has one agent card, and open the mirror once the agent has already replied to one prompt, so the mirror joins part-way through:

```bash
./scripts/e2e.py guard   # leaves nothing running; use it only to confirm the build still passes
```

Then by hand, in a Debug build opened with `--testing --open <a scratch project>`: send the agent a prompt that makes it list a long folder and ask to run a command, then call the `mirror` op for that card (the `call` function in `scripts/e2e.py` shows how). Pass means all of these hold:

1. The mirror matches the real terminal on joining, with no stray characters.
2. It stays matched through a long reply, a permission prompt, and a card resize.
3. The app uses no more than about 10% extra CPU while the agent is printing.
4. With no mirror open and `feed` never read, the app behaves as before: `./scripts/e2e.py guard settings scroll` passes.

- [ ] **Step 6: Record the result**

Add a section "Result of Task 2" at the bottom of this plan: which way passed, what failed for the ways before it, and the measured chunk size and CPU. If Way A was chosen, change the spec's "Joining a terminal part-way through" section to say the device shows the screen without scrollback, and **stop and tell Keith** before going on, because that changes what was agreed. If none passed, stop and report.

- [ ] **Step 7: Commit**

```bash
./scripts/check-clean.sh
git add App/Remote/TerminalFeed.swift App/Sessions/TerminalSession.swift App/Testing/TestHarness.swift docs/superpowers
git commit -m "A session's terminal as a stream a second terminal can follow"
```

---

### Task 3: Move the run types into Core, and build Core for iOS

**Files:**
- Create: `Core/Sources/QueenBeeCore/RunState.swift`
- Modify: `Core/Package.swift`, `App/FlowController.swift:27-94`, `App/Sessions/TerminalSession.swift:6-37`, `App/Sessions/UsageReader.swift:3-40`
- Test: `Core/Tests/QueenBeeCoreTests/RunStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/QueenBeeCoreTests/RunStateTests.swift`:

```swift
import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RunStateTests {
    @Test func aRunRecordSurvivesEncoding() throws {
        var mark = RunMark()
        mark.arrivals = 2
        mark.ports = ["yes": 1]
        mark.lastPort = "yes"
        let record = RunRecord(id: "r1", started: Date(timeIntervalSince1970: 10), ended: Date(timeIntervalSince1970: 20),
                               outcome: .finished, command: "go", log: [LogLine(date: Date(timeIntervalSince1970: 11), text: "started")],
                               results: ["end": "done"], marks: ["a": mark], linkPasses: ["l0": 1],
                               messages: ["l0": [LinkMessage(date: Date(timeIntervalSince1970: 12), from: "Alice", text: "hi")]],
                               handOffs: 1, usage: ["a": Usage(cost: 0.5, input: 10, output: 20)])
        let back = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(back == record)
        #expect(back.cost.cost == 0.5)
    }

    @Test func usageAddsAndFormats() {
        let total = Usage(cost: 0.004, input: 600) + Usage(cost: 0.004, output: 600)
        #expect(total.tokens == 1200)
        #expect(total.price == "<$0.01")
        #expect(total.tokenCount == "1k tokens")
        #expect(Usage(cost: 2, input: 5).since(Usage(cost: 3, input: 1)) == Usage(cost: 0, input: 4))
    }

    @Test func aHoldSurvivesEncoding() throws {
        let hold = PendingHold(id: "h", cardID: "c", kind: .script, text: "msg", from: "Alice", command: "ls", needsAllow: true)
        #expect(try JSONDecoder().decode(PendingHold.self, from: JSONEncoder().encode(hold)) == hold)
    }

    @Test func sessionStatesKeepTheirNames() {
        #expect(SessionState(rawValue: "needsYou") == .needsYou)
        #expect(SessionState.needsYou.label == "Needs you")
        #expect("\(FlowActivity.needsYou)" == "needsYou")
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: FAIL, `cannot find 'RunMark' in scope`

- [ ] **Step 3: Write the types in Core**

Create `Core/Sources/QueenBeeCore/RunState.swift`:

```swift
import Foundation

/// What a session is doing, as Claude Code's hooks report it.
public enum SessionState: String, Codable, Sendable, CaseIterable {
    case notStarted, starting, idle, working, needsYou, failed, exited

    public var label: String {
        switch self {
        case .notStarted: "Not started"
        case .starting: "Starting"
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .failed: "Failed"
        case .exited: "Exited"
        }
    }
}

/// Where the run on show has been, for one card.
public struct RunMark: Equatable, Sendable, Codable {
    /// Messages that reached the card along a link.
    public var arrivals = 0
    /// Times a message left the card.
    public var passes = 0
    /// How many times it left by each output, and the output it left by last.
    public var ports: [String: Int] = [:]
    public var lastPort: String?
    /// Arrivals since it last passed anything on: what an And is holding, what an Or dropped.
    public var holding = 0
    /// The run stopped at this card.
    public var failed = false

    public init() {}
}

/// A message waiting at an Approval or Script card in the run that is going.
public struct PendingHold: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let cardID: String
    public let kind: CardKind
    /// The message that is waiting.
    public let text: String
    public let from: String
    /// What the card is running: a Script card's command, or the name of the flow a Flow card runs.
    public var command: String
    /// A script whose command the person hasn't allowed yet.
    public var needsAllow: Bool

    public init(id: String, cardID: String, kind: CardKind, text: String, from: String, command: String = "", needsAllow: Bool = false) {
        self.id = id; self.cardID = cardID; self.kind = kind; self.text = text; self.from = from
        self.command = command; self.needsAllow = needsAllow
    }
}

/// What a flow needs from you right now, for its row in the sidebar.
public enum FlowActivity: String, Codable, Sendable {
    case quiet, running, needsYou, failed
}

public struct LogLine: Identifiable, Equatable, Sendable, Codable {
    public var id = UUID()
    public let date: Date
    public let text: String

    public init(date: Date, text: String) { self.date = date; self.text = text }
}

/// One message a link carried in a run.
public struct LinkMessage: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public let date: Date
    public let from: String
    public let text: String

    public init(date: Date, from: String, text: String) { self.date = date; self.from = from; self.text = text }
}

/// What a Claude Code session has used: tokens, and what they would cost at API prices.
public struct Usage: Codable, Equatable, Sendable {
    public var cost = 0.0
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(cost: Double = 0, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.cost = cost; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    public var tokens: Int { input + output + cacheRead + cacheWrite }
    public var isZero: Bool { cost == 0 && tokens == 0 }

    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(cost: a.cost + b.cost, input: a.input + b.input, output: a.output + b.output,
              cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    /// What was used since `earlier`, never less than nothing.
    public func since(_ earlier: Usage) -> Usage {
        Usage(cost: max(0, cost - earlier.cost), input: max(0, input - earlier.input), output: max(0, output - earlier.output),
              cacheRead: max(0, cacheRead - earlier.cacheRead), cacheWrite: max(0, cacheWrite - earlier.cacheWrite))
    }

    /// "$0.37", "<$0.01", "$124".
    public var price: String {
        if cost <= 0 { return "$0.00" }
        if cost < 0.01 { return "<$0.01" }
        return cost >= 100 ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)
    }

    /// "182k tokens", "1.2M tokens".
    public var tokenCount: String {
        let n = Double(tokens)
        if n >= 1_000_000 { return String(format: "%.1fM tokens", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk tokens", n / 1_000) }
        return "\(tokens) tokens"
    }
}

/// One run, kept so it can be looked at again: where it went, what each link carried and how it ended.
public struct RunRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case finished, stopped, failed }

    public let id: String
    public let started: Date
    public var ended: Date
    public var outcome: Outcome
    /// What the run began with, in a few words.
    public var command: String
    public var log: [LogLine]
    public var results: [String: String]
    public var marks: [String: RunMark]
    public var linkPasses: [String: Int]
    public var messages: [String: [LinkMessage]]
    public var handOffs: Int
    /// What each agent's session used during the run, by card id. Filled in a moment after the run ends.
    public var usage: [String: Usage]?

    public init(id: String, started: Date, ended: Date, outcome: Outcome, command: String, log: [LogLine],
                results: [String: String], marks: [String: RunMark], linkPasses: [String: Int],
                messages: [String: [LinkMessage]], handOffs: Int, usage: [String: Usage]? = nil) {
        self.id = id; self.started = started; self.ended = ended; self.outcome = outcome; self.command = command
        self.log = log; self.results = results; self.marks = marks; self.linkPasses = linkPasses
        self.messages = messages; self.handOffs = handOffs; self.usage = usage
    }

    public var cost: Usage { (usage ?? [:]).values.reduce(Usage(), +) }
}
```

- [ ] **Step 4: Run the Core tests**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: PASS, all tests

- [ ] **Step 5: Delete the app's copies**

- `App/FlowController.swift`: delete the declarations of `RunMark`, `PendingHold`, `FlowActivity`, `LogLine`, `LinkMessage` and `RunRecord` (lines 27-94). Keep `Selection` above them and `RunHistory` below them.
- `App/Sessions/UsageReader.swift`: delete the `Usage` struct (lines 3-40), keep `ModelPrice`, and add `import QueenBeeCore` under `import Foundation`.
- `App/Sessions/TerminalSession.swift`: replace the `SessionState` enum (lines 6-37) with:

```swift
extension SessionState {
    var color: NSColor {
        switch self {
        case .notStarted, .starting, .idle: Theme.inkSecondary
        case .working, .needsYou: Theme.live
        case .failed, .exited: Theme.failInk
        }
    }

    var tone: Badge.Tone {
        switch self {
        case .notStarted, .starting, .idle: .plain
        case .working, .needsYou: .live
        case .failed, .exited: .fail
        }
    }
}
```

- [ ] **Step 6: Build the app**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`. If a file reports `cannot find type` for one of the moved types, add `import QueenBeeCore` to that file and build again.

- [ ] **Step 7: Add iOS and the link target to the package**

Replace `Core/Package.swift` with:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QueenBeeCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "QueenBeeCore", targets: ["QueenBeeCore"]),
        .library(name: "QueenBeeLink", targets: ["QueenBeeLink"]),
    ],
    targets: [
        .target(name: "QueenBeeCore"),
        .target(name: "QueenBeeLink", dependencies: ["QueenBeeCore"]),
        .testTarget(name: "QueenBeeCoreTests", dependencies: ["QueenBeeCore"]),
        .testTarget(name: "QueenBeeLinkTests", dependencies: ["QueenBeeLink"]),
    ],
    swiftLanguageModes: [.v6]
)
```

Create a placeholder so both new targets have a source file until Task 6 fills them:

```bash
mkdir -p Core/Sources/QueenBeeLink Core/Tests/QueenBeeLinkTests
printf 'import Foundation\n' > Core/Sources/QueenBeeLink/LinkSecurity.swift
printf 'import Testing\n' > Core/Tests/QueenBeeLinkTests/LinkSecurityTests.swift
```

- [ ] **Step 8: Build Core for iOS**

Run: `cd Core && xcodebuild -scheme QueenBeeCore-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath ../build/core-ios build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`. If the scheme name is not found, run `xcodebuild -list` in `Core` and use the package scheme it prints.

- [ ] **Step 9: Build Core for iOS on every push**

In `.github/workflows/tests.yml`, add to the `core` job's steps, after `swift test`:

```yaml
      - name: Build for iOS
        working-directory: Core
        run: xcodebuild -scheme QueenBeeCore-Package -destination 'generic/platform=iOS Simulator' build
```

- [ ] **Step 10: Run what already existed**

Run: `cd Core && swift test 2>&1 | tail -3 && cd .. && ./scripts/build.sh && ./scripts/e2e.py guard settings`
Expected: Core tests pass, build succeeds, e2e prints `0 failed`

- [ ] **Step 11: Commit**

```bash
./scripts/check-clean.sh
git add Core App .github
git commit -m "Move the run types into Core and build Core for iOS"
```

---

### Task 4: The messages

**Files:**
- Create: `Core/Sources/QueenBeeCore/Remote.swift`
- Modify: `App/Remote/TerminalFeed.swift` (delete the temporary `TerminalChunk`)
- Test: `Core/Tests/QueenBeeCoreTests/RemoteTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/QueenBeeCoreTests/RemoteTests.swift`:

```swift
import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try Remote.decode(T.self, from: Remote.encode(value))
    }

    @Test func hostMessagesSurviveEncoding() throws {
        var flow = Flow(name: "Demo")
        _ = try flow.addCard(kind: .start, x: 10, y: 20)
        let run = RemoteRunState(isRunning: true, marks: ["a": RunMark()], linkPasses: ["l": 2], liveLinkIDs: ["l"], handOffs: 3,
                                 holds: [PendingHold(id: "h", cardID: "a", kind: .approval, text: "ok?", from: "Alice")],
                                 results: ["e": "done"], usage: ["a": Usage(cost: 1)], sessions: ["a": .working],
                                 awaitingAnswer: ["a"], banner: "careful")
        let snapshot = RemoteFlowSnapshot(flow: flow, run: run, log: [LogLine(date: Date(timeIntervalSince1970: 1), text: "x")],
                                          messages: [:], runs: [])
        let messages: [HostMessage] = [
            .welcome(RemoteWelcome(version: 1, macName: "Mac", canControl: false)),
            .refused("no"),
            .library(RemoteLibrary(projects: [RemoteProject(id: "p", name: "proj", flows: [
                RemoteFlowSummary(id: flow.id, name: "Demo", isSubflow: false, activity: .running)])])),
            .opened(snapshot),
            .flow(id: flow.id, revision: 4, flow: flow),
            .run(id: flow.id, state: run),
            .log(id: flow.id, lines: snapshot.log, reset: false),
            .messages(id: flow.id, link: "l", all: [LinkMessage(date: Date(timeIntervalSince1970: 2), from: "Alice", text: "hi")]),
            .history(id: flow.id, runs: []),
            .terminal(id: flow.id, key: "a", chunk: TerminalChunk(reset: true, cols: 80, rows: 24, data: Data([27, 91, 72]))),
        ]
        for message in messages { #expect(try roundTrip(message) == message) }
    }

    @Test func deviceAndPairingMessagesSurviveEncoding() throws {
        let hello = DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: "d", deviceName: "iPad"))
        #expect(try roundTrip(hello) == hello)
        #expect(try roundTrip(DeviceMessage.open(flowID: nil)) == .open(flowID: nil))
        let request = PairRequest(version: 1, deviceID: "d", deviceName: "iPad")
        #expect(try roundTrip(request) == request)
        let reply = PairReply.granted(PairGrant(key: Data([1, 2, 3]), macID: "m", macName: "Mac"))
        #expect(try roundTrip(reply) == reply)
        #expect(try roundTrip(PairReply.refused("old")) == .refused("old"))
    }

    @Test func junkDoesNotDecode() {
        #expect(throws: (any Error).self) { try Remote.decode(HostMessage.self, from: Data("{}".utf8)) }
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: FAIL, `cannot find 'Remote' in scope`

- [ ] **Step 3: Write the messages**

Create `Core/Sources/QueenBeeCore/Remote.swift`:

```swift
import Foundation

/// What the Mac app and a paired device say to each other. Each message is one frame of JSON.
public enum Remote {
    /// Both sides must be on the same version, or the device is told to update.
    public static let version = 1
    /// The Bonjour type of a paired device's listener, and of the listener that exists only while pairing.
    public static let service = "_queenbee._tcp"
    public static let pairingService = "_queenbee-pair._tcp"

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
}

/// The first thing a device sends on a new connection.
public struct RemoteHello: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String

    public init(version: Int, deviceID: String, deviceName: String) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName
    }
}

public struct RemoteWelcome: Codable, Equatable, Sendable {
    public var version: Int
    public var macName: String
    /// False means the device may watch and nothing else.
    public var canControl: Bool

    public init(version: Int, macName: String, canControl: Bool) {
        self.version = version; self.macName = macName; self.canControl = canControl
    }
}

public struct RemoteFlowSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isSubflow: Bool
    public var activity: FlowActivity

    public init(id: String, name: String, isSubflow: Bool, activity: FlowActivity) {
        self.id = id; self.name = name; self.isSubflow = isSubflow; self.activity = activity
    }
}

public struct RemoteProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var flows: [RemoteFlowSummary]

    public init(id: String, name: String, flows: [RemoteFlowSummary]) { self.id = id; self.name = name; self.flows = flows }
}

/// Every project in the Mac's sidebar and the flows in each.
public struct RemoteLibrary: Codable, Equatable, Sendable {
    public var projects: [RemoteProject]

    public init(projects: [RemoteProject]) { self.projects = projects }
}

/// The parts of a flow's state that change while it runs. Sent whole whenever any of it changes.
public struct RemoteRunState: Codable, Equatable, Sendable {
    public var isRunning: Bool
    public var marks: [String: RunMark]
    public var linkPasses: [String: Int]
    public var liveLinkIDs: [String]
    public var handOffs: Int
    public var holds: [PendingHold]
    public var results: [String: String]
    public var usage: [String: Usage]
    /// Each session's state, by card id, with the orchestrator under "orchestrator".
    public var sessions: [String: SessionState]
    public var awaitingAnswer: [String]
    public var banner: String?

    public init(isRunning: Bool, marks: [String: RunMark], linkPasses: [String: Int], liveLinkIDs: [String], handOffs: Int,
                holds: [PendingHold], results: [String: String], usage: [String: Usage], sessions: [String: SessionState],
                awaitingAnswer: [String], banner: String?) {
        self.isRunning = isRunning; self.marks = marks; self.linkPasses = linkPasses; self.liveLinkIDs = liveLinkIDs
        self.handOffs = handOffs; self.holds = holds; self.results = results; self.usage = usage; self.sessions = sessions
        self.awaitingAnswer = awaitingAnswer; self.banner = banner
    }
}

/// Everything a device needs to draw one flow.
public struct RemoteFlowSnapshot: Codable, Equatable, Sendable {
    public var flow: Flow
    public var run: RemoteRunState
    public var log: [LogLine]
    /// What each link carried in the run on show, by link id.
    public var messages: [String: [LinkMessage]]
    /// Earlier runs, oldest first.
    public var runs: [RunRecord]

    public init(flow: Flow, run: RemoteRunState, log: [LogLine], messages: [String: [LinkMessage]], runs: [RunRecord]) {
        self.flow = flow; self.run = run; self.log = log; self.messages = messages; self.runs = runs
    }
}

/// Bytes for a remote terminal. With `reset` set they take a blank terminal of that size to the screen;
/// without it they follow on from the last chunk.
public struct TerminalChunk: Codable, Equatable, Sendable {
    public var reset: Bool
    public var cols: Int
    public var rows: Int
    public var data: Data

    public init(reset: Bool, cols: Int, rows: Int, data: Data) { self.reset = reset; self.cols = cols; self.rows = rows; self.data = data }
}

/// Mac to device.
public enum HostMessage: Codable, Equatable, Sendable {
    case welcome(RemoteWelcome)
    /// The connection is about to close. The text is shown to the person as it is.
    case refused(String)
    case library(RemoteLibrary)
    /// The whole of the flow the device just opened.
    case opened(RemoteFlowSnapshot)
    case flow(id: String, revision: Int, flow: Flow)
    case run(id: String, state: RemoteRunState)
    /// Lines to add to the log, or with `reset` the whole log.
    case log(id: String, lines: [LogLine], reset: Bool)
    /// Everything one link has carried.
    case messages(id: String, link: String, all: [LinkMessage])
    case history(id: String, runs: [RunRecord])
    case terminal(id: String, key: String, chunk: TerminalChunk)
}

/// Device to Mac.
public enum DeviceMessage: Codable, Equatable, Sendable {
    case hello(RemoteHello)
    /// The flow the device is looking at, or nil for none.
    case open(flowID: String?)
}

/// What a device sends to the pairing listener.
public struct PairRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var deviceID: String
    public var deviceName: String

    public init(version: Int, deviceID: String, deviceName: String) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName
    }
}

public struct PairGrant: Codable, Equatable, Sendable {
    /// The device's own key, for every later connection.
    public var key: Data
    public var macID: String
    public var macName: String

    public init(key: Data, macID: String, macName: String) { self.key = key; self.macID = macID; self.macName = macName }
}

public enum PairReply: Codable, Equatable, Sendable {
    case granted(PairGrant)
    case refused(String)
}
```

- [ ] **Step 4: Delete the temporary type**

In `App/Remote/TerminalFeed.swift`, delete the temporary `struct TerminalChunk` line from Task 2.

- [ ] **Step 5: Run the tests and build**

Run: `cd Core && swift test 2>&1 | tail -3 && cd .. && ./scripts/build.sh`
Expected: tests pass, `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
./scripts/check-clean.sh
git add Core App/Remote/TerminalFeed.swift
git commit -m "The messages a Mac and a paired device exchange"
```

---

### Task 5: What to send when a flow changes

**Files:**
- Create: `Core/Sources/QueenBeeCore/RemoteSnapshot.swift`
- Test: `Core/Tests/QueenBeeCoreTests/RemoteSnapshotTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/QueenBeeCoreTests/RemoteSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct RemoteSnapshotTests {
    private func base() throws -> RemoteFlowSnapshot {
        var flow = Flow(name: "Demo")
        _ = try flow.addCard(kind: .start, x: 10, y: 20)
        let run = RemoteRunState(isRunning: false, marks: [:], linkPasses: [:], liveLinkIDs: [], handOffs: 0, holds: [],
                                 results: [:], usage: [:], sessions: [:], awaitingAnswer: [], banner: nil)
        return RemoteFlowSnapshot(flow: flow, run: run, log: [LogLine(date: Date(timeIntervalSince1970: 1), text: "one")],
                                  messages: ["l": [LinkMessage(date: Date(timeIntervalSince1970: 2), from: "A", text: "hi")]], runs: [])
    }

    @Test func nothingChangedSendsNothing() throws {
        let old = try base()
        #expect(RemoteSnapshot.updates(from: old, to: old, revision: 1).isEmpty)
    }

    @Test func aMovedCardSendsOnlyTheFlow() throws {
        let old = try base()
        var new = old
        new.flow.cards[0].x = 99
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 7) == [.flow(id: old.flow.id, revision: 7, flow: new.flow)])
    }

    @Test func aRunChangeSendsOnlyTheRunState() throws {
        let old = try base()
        var new = old
        new.run.isRunning = true
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.run(id: old.flow.id, state: new.run)])
    }

    @Test func newLogLinesAreSentAlone() throws {
        let old = try base()
        var new = old
        let added = LogLine(date: Date(timeIntervalSince1970: 3), text: "two")
        new.log.append(added)
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: [added], reset: false)])
    }

    @Test func aClearedLogIsSentWhole() throws {
        let old = try base()
        var new = old
        new.log = [LogLine(date: Date(timeIntervalSince1970: 9), text: "fresh")]
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.log(id: old.flow.id, lines: new.log, reset: true)])
    }

    @Test func onlyChangedLinksAreSent() throws {
        let old = try base()
        var new = old
        new.messages["m"] = [LinkMessage(date: Date(timeIntervalSince1970: 4), from: "B", text: "yo")]
        new.messages["l"] = nil
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [
            .messages(id: old.flow.id, link: "l", all: []),
            .messages(id: old.flow.id, link: "m", all: new.messages["m"]!),
        ])
    }

    @Test func aFinishedRunSendsTheHistory() throws {
        let old = try base()
        var new = old
        new.runs = [RunRecord(id: "r", started: Date(timeIntervalSince1970: 1), ended: Date(timeIntervalSince1970: 2), outcome: .finished,
                              command: "go", log: [], results: [:], marks: [:], linkPasses: [:], messages: [:], handOffs: 0)]
        #expect(RemoteSnapshot.updates(from: old, to: new, revision: 1) == [.history(id: old.flow.id, runs: new.runs)])
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: FAIL, `cannot find 'RemoteSnapshot' in scope`

- [ ] **Step 3: Write it**

Create `Core/Sources/QueenBeeCore/RemoteSnapshot.swift`:

```swift
import Foundation

public enum RemoteSnapshot {
    /// The messages that take a device holding `old` to `new`, in a fixed order. Nothing when they are equal.
    public static func updates(from old: RemoteFlowSnapshot, to new: RemoteFlowSnapshot, revision: Int) -> [HostMessage] {
        let id = new.flow.id
        var out: [HostMessage] = []
        if new.flow != old.flow { out.append(.flow(id: id, revision: revision, flow: new.flow)) }
        if new.run != old.run { out.append(.run(id: id, state: new.run)) }
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
```

- [ ] **Step 4: Run the tests**

Run: `cd Core && swift test 2>&1 | tail -3`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
./scripts/check-clean.sh
git add Core
git commit -m "Work out what to send a device when a flow changes"
```

---

### Task 6: The encrypted connection

This task is also the proof that a TLS pre-shared key works between two ends on this macOS. The loopback tests are that proof.

**Files:**
- Create: `Core/Sources/QueenBeeLink/LinkSecurity.swift` (replace the placeholder), `Core/Sources/QueenBeeLink/LinkConnection.swift`
- Test: `Core/Tests/QueenBeeLinkTests/LinkSecurityTests.swift` (replace the placeholder), `Core/Tests/QueenBeeLinkTests/LinkConnectionTests.swift`

- [ ] **Step 1: Write the failing tests**

Replace `Core/Tests/QueenBeeLinkTests/LinkSecurityTests.swift`:

```swift
import Foundation
import Testing
@testable import QueenBeeLink

@Suite struct LinkSecurityTests {
    @Test func keysAreLongAndDiffer() {
        let a = LinkSecurity.randomKey(), b = LinkSecurity.randomKey()
        #expect(a.count == 32)
        #expect(a != b)
    }

    @Test func aPairingCodeSurvivesBeingTyped() {
        let code = PairingCode()
        #expect(code.text.hasPrefix("queenbee-pair:1:"))
        #expect(PairingCode(text: code.text) == code)
        #expect(PairingCode(text: "  " + code.text + "\n") == code)
    }

    @Test func junkIsNotAPairingCode() {
        #expect(PairingCode(text: "") == nil)
        #expect(PairingCode(text: "queenbee-pair:2:AAAA") == nil)
        #expect(PairingCode(text: "queenbee-pair:1:short") == nil)
        #expect(PairingCode(text: "https://example.com") == nil)
    }
}
```

Create `Core/Tests/QueenBeeLinkTests/LinkConnectionTests.swift`:

```swift
import Foundation
import Network
import Testing
@testable import QueenBeeLink

@Suite struct LinkConnectionTests {
    private func endpoint(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    /// A listener that sends back whatever it gets with "!" on the end.
    private func echo(key: Data) async throws -> (listener: LinkListener, port: UInt16) {
        let listener = try LinkListener(key: key, service: nil, localOnly: true)
        let port = try await listener.start { server in
            Task {
                do {
                    try await server.start()
                    while true { try await server.send(try await server.receive() + Data("!".utf8)) }
                } catch { server.close() }
            }
        }
        return (listener, port)
    }

    @Test func framesCrossAnEncryptedLoopback() async throws {
        let key = LinkSecurity.randomKey()
        let (listener, port) = try await echo(key: key)
        defer { listener.stop() }
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        try await client.start()
        try await client.send(Data("hello".utf8))
        #expect(try await client.receive() == Data("hello!".utf8))
        let big = Data(repeating: 7, count: 300_000)
        try await client.send(big)
        #expect(try await client.receive() == big + Data("!".utf8))
        try await client.send(Data())
        #expect(try await client.receive() == Data("!".utf8))
    }

    @Test func aWrongKeyGetsNothing() async throws {
        let (listener, port) = try await echo(key: LinkSecurity.randomKey())
        defer { listener.stop() }
        let client = LinkConnection(to: endpoint(port), key: LinkSecurity.randomKey())
        defer { client.close() }
        await #expect(throws: (any Error).self) {
            try await client.start(timeout: 4)
            try await client.send(Data("hello".utf8))
            _ = try await client.receive()
        }
    }

    @Test func aStoppedListenerRefusesNewConnections() async throws {
        let key = LinkSecurity.randomKey()
        let (listener, port) = try await echo(key: key)
        listener.stop()
        try await Task.sleep(for: .milliseconds(200))
        let client = LinkConnection(to: endpoint(port), key: key)
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.start(timeout: 3) }
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: FAIL, `cannot find 'LinkSecurity' in scope`

- [ ] **Step 3: Write the security pieces**

Replace `Core/Sources/QueenBeeLink/LinkSecurity.swift`:

```swift
import Foundation
import Network
import Security

public struct LinkError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum LinkSecurity {
    /// 32 random bytes: a device's key, or a pairing code's secret.
    public static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// TLS over TCP where both ends must hold `key`. Nothing is exchanged with an end that doesn't.
    public static func parameters(key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("queenbee".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384))!)
        let tcp = NWProtocolTCP.Options()
        // A device that walks out of range is noticed in seconds, not minutes.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// What the Mac shows as a QR code while pairing, and a device scans or has pasted in.
public struct PairingCode: Equatable, Sendable {
    public let secret: Data

    public init(secret: Data = LinkSecurity.randomKey()) { self.secret = secret }

    public var text: String {
        "queenbee-pair:1:" + secret.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "queenbee-pair", parts[1] == "1" else { return nil }
        var base64 = parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let secret = Data(base64Encoded: base64), secret.count == 32 else { return nil }
        self.secret = secret
    }
}
```

- [ ] **Step 4: Write the connection and the listener**

Create `Core/Sources/QueenBeeLink/LinkConnection.swift`:

```swift
import Foundation
import Network
import QueenBeeCore

/// Runs its body for the first caller only. A connection's state can report an end more than once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// One encrypted connection carrying frames: a four-byte big-endian length, then that many bytes.
public final class LinkConnection: @unchecked Sendable {
    /// Far above any real message, and low enough that a garbled length fails fast.
    public static let largestFrame = 64 * 1024 * 1024

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.queenbee.link.connection")

    public init(_ connection: NWConnection) { self.connection = connection }

    public convenience init(to endpoint: NWEndpoint, key: Data) {
        self.init(NWConnection(to: endpoint, using: LinkSecurity.parameters(key: key)))
    }

    /// Returns once both ends have proved they hold the key. Throws if they haven't within `timeout`.
    public func start(timeout: TimeInterval = 8) async throws {
        let once = Once()
        let connection = connection
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: LinkError("\(error)")) }
                    case .cancelled: once.run { continuation.resume(throwing: LinkError("closed")) }
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) { once.run { continuation.resume(throwing: LinkError("timed out")) } }
                connection.start(queue: queue)
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    public func send(_ body: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Wire.frame(body), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: LinkError("\(error)")) } else { continuation.resume() }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await read(4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length <= Self.largestFrame else { throw LinkError("frame too large") }
        return length == 0 ? Data() : try await read(length)
    }

    private func read(_ count: Int) async throws -> Data {
        let connection = connection
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LinkError(error.map { "\($0)" } ?? "closed"))
                }
            }
        }
    }

    public func send<T: Encodable>(_ message: T) async throws { try await send(try Remote.encode(message)) }

    public func receive<T: Decodable>(_ type: T.Type) async throws -> T { try Remote.decode(type, from: try await receive()) }

    public func close() { connection.cancel() }
}

/// Accepts connections from ends that hold `key`.
public final class LinkListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.queenbee.link.listener")

    /// `service` advertises the listener on the local network. `localOnly` keeps it to this machine, for tests.
    public init(key: Data, service: NWListener.Service?, localOnly: Bool) throws {
        let parameters = LinkSecurity.parameters(key: key)
        if localOnly { parameters.requiredInterfaceType = .loopback }
        listener = try NWListener(using: parameters)
        listener.service = service
    }

    /// Starts listening and returns the port. Each connection is handed over not yet started.
    public func start(onConnection: @escaping @Sendable (LinkConnection) -> Void) async throws -> UInt16 {
        let once = Once()
        let listener = listener
        listener.newConnectionHandler = { onConnection(LinkConnection($0)) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: LinkError("\(error)")) }
                case .cancelled: once.run { continuation.resume(throwing: LinkError("closed")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }
}
```

- [ ] **Step 5: Run the tests**

Run: `cd Core && swift test 2>&1 | tail -5`
Expected: PASS, including the three `LinkConnectionTests`.

If `framesCrossAnEncryptedLoopback` fails at `start`, the pre-shared key set-up is wrong for this macOS. Compare `LinkSecurity.parameters` with Apple's "Building a custom peer-to-peer protocol" sample, which uses `TLS_PSK_WITH_AES_128_GCM_SHA256`, and try that suite. If no suite connects, stop and report: the link's security design has to change.

- [ ] **Step 6: Build the link for iOS**

Run: `cd Core && xcodebuild -scheme QueenBeeCore-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath ../build/core-ios build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
./scripts/check-clean.sh
git add Core
git commit -m "An encrypted connection only the two ends holding a key can use"
```

---

### Task 7: Paired devices and their keys

**Files:**
- Create: `App/Remote/RemoteDevices.swift`
- Modify: `project.yml`

- [ ] **Step 1: Link the app against the new target**

In `project.yml`, under `targets: QueenBee: dependencies:`, add after `- package: QueenBeeCore`:

```yaml
      - package: QueenBeeCore
        product: QueenBeeLink
```

- [ ] **Step 2: Write the store**

Create `App/Remote/RemoteDevices.swift`:

```swift
import Foundation
import Observation
import QueenBeeLink
import Security

/// One iPad or iPhone that has been paired with this Mac.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var added: Date
    /// False means it may watch and nothing else.
    var canControl: Bool
}

/// Where keys are kept: the Keychain, or memory only in a test copy, so a test never touches the real Keychain.
enum KeyVault {
    private static var memory: [String: Data] = [:]
    private static var service: String { (Bundle.main.bundleIdentifier ?? "dev.queenbee.app") + ".remote" }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> Data? {
        if TestHarness.isEnabled { return memory[account] }
        var found: CFTypeRef?
        let wanted = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        return SecItemCopyMatching(wanted as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    static func write(_ data: Data, _ account: String) {
        if TestHarness.isEnabled { memory[account] = data; return }
        SecItemDelete(query(account) as CFDictionary)
        let item = query(account).merging([kSecValueData as String: data,
                                           kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        if TestHarness.isEnabled { memory[account] = nil; return }
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// The devices paired with this Mac. Their names are in a file; their keys are only ever in the Keychain.
@Observable
final class RemoteDevices {
    private struct Saved: Codable {
        var macID: String
        var devices: [PairedDevice]
    }

    private(set) var devices: [PairedDevice] = []
    /// A random name for this Mac, so a device finds it again whatever the Mac is called.
    private(set) var macID = UUID().uuidString.lowercased()
    private var url: URL { AppServices.shared.supportDirectory.appendingPathComponent("remote-devices.json") }

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            macID = saved.macID
            // A device whose key has gone from the Keychain can't connect, so it isn't listed.
            devices = saved.devices.filter { KeyVault.read(Self.account($0.id)) != nil }
        }
    }

    private static func account(_ id: String) -> String { "device-" + id }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(macID: macID, devices: devices)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func key(for id: String) -> Data? { KeyVault.read(Self.account(id)) }

    /// Pairs a device, or pairs it again with a new key, and returns that key.
    func add(id: String, name: String) -> Data {
        let key = LinkSecurity.randomKey()
        KeyVault.write(key, Self.account(id))
        devices.removeAll { $0.id == id }
        devices.append(PairedDevice(id: id, name: name, added: Date(), canControl: false))
        save()
        return key
    }

    func remove(_ id: String) {
        KeyVault.delete(Self.account(id))
        devices.removeAll { $0.id == id }
        save()
    }
}
```

- [ ] **Step 3: Build**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
./scripts/check-clean.sh
git add project.yml App/Remote/RemoteDevices.swift
git commit -m "Keep paired devices in a file and their keys in the Keychain"
```

---

### Task 8: The host — listeners, pairing, the flow list

**Files:**
- Create: `App/Remote/RemoteHost.swift`, `App/Remote/RemoteSession.swift` (a first version; Task 9 completes it)
- Modify: `App/AppServices.swift` (`start()` and `shutDown()`), `App/Info.plist`

- [ ] **Step 1: Say why the app uses the local network**

In `App/Info.plist`, add inside the top-level `<dict>`:

```xml
	<!-- Remote: a paired iPad or iPhone finds this Mac on the local network. -->
	<key>NSLocalNetworkUsageDescription</key>
	<string>Queen Bee uses your local network so an iPad or iPhone you paired can show your flows.</string>
	<key>NSBonjourServices</key>
	<array>
		<string>_queenbee._tcp</string>
		<string>_queenbee-pair._tcp</string>
	</array>
```

- [ ] **Step 2: Write the first version of a connected device**

Create `App/Remote/RemoteSession.swift`:

```swift
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
```

- [ ] **Step 3: Write the host**

Create `App/Remote/RemoteHost.swift`:

```swift
import Foundation
import Network
import Observation
import QueenBeeCore
import QueenBeeLink

/// A pairing in progress: the code on screen and when it stops working.
struct PairingOffer: Equatable {
    let code: PairingCode
    let expires: Date
}

/// Lets paired devices connect: one listener per device, each locked to that device's key.
@Observable
final class RemoteHost {
    static let shared = RemoteHost()
    static let enabledKey = "remoteEnabled"
    /// How long a pairing code works.
    static let pairingWindow: TimeInterval = 120

    let devices = RemoteDevices()
    private(set) var isOn = false
    private(set) var sessions: [RemoteSession] = []
    private(set) var pairing: PairingOffer?
    private(set) var problem: String?

    @ObservationIgnored private var listeners: [String: LinkListener] = [:]
    @ObservationIgnored private(set) var ports: [String: UInt16] = [:]
    @ObservationIgnored private var pairingListener: LinkListener?
    @ObservationIgnored private(set) var pairingPort: UInt16?
    @ObservationIgnored private var lastLibrary: RemoteLibrary?

    /// A test copy stays on this machine and is never advertised.
    private var localOnly: Bool { TestHarness.isEnabled }
    private var macName: String { Host.current().localizedName ?? "Mac" }

    /// Runs once at launch. A test copy turns Remote on itself.
    func start() {
        if !TestHarness.isEnabled, UserDefaults.standard.bool(forKey: Self.enabledKey) { setOn(true) }
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        problem = nil
        if on {
            devices.devices.forEach(listen(for:))
            watchLibrary()
        } else {
            shutDown()
        }
    }

    func shutDown() {
        isOn = false
        cancelPairing()
        listeners.values.forEach { $0.stop() }
        listeners.removeAll()
        ports.removeAll()
        sessions.forEach { $0.close() }
        sessions.removeAll()
    }

    // MARK: Paired devices

    private func listen(for device: PairedDevice) {
        guard isOn, listeners[device.id] == nil, let key = devices.key(for: device.id) else { return }
        let id = device.id
        do {
            // The record lets a device pick out its own listener on its own Mac without connecting to try.
            let service = localOnly ? nil : NWListener.Service(
                name: "\(macName) \(id.prefix(4))", type: Remote.service,
                txtRecord: NWTXTRecord(["mac": devices.macID, "device": id, "name": macName]))
            let listener = try LinkListener(key: key, service: service, localOnly: localOnly)
            listeners[id] = listener
            Task {
                do {
                    ports[id] = try await listener.start { connection in
                        Task { @MainActor in await RemoteHost.shared.serve(connection, deviceID: id) }
                    }
                } catch {
                    problem = "Queen Bee couldn't start listening for your devices: \(error)"
                }
            }
        } catch {
            problem = "Queen Bee couldn't start listening for your devices: \(error)"
        }
    }

    private func stopListening(_ id: String) {
        listeners[id]?.stop()
        listeners[id] = nil
        ports[id] = nil
        for session in sessions where session.device.id == id { session.close() }
        sessions.removeAll { $0.device.id == id }
    }

    /// Unpairs a device: its listener stops, its connection closes and its key is deleted.
    func remove(_ id: String) {
        stopListening(id)
        devices.remove(id)
    }

    private func serve(_ connection: LinkConnection, deviceID: String) async {
        do {
            try await connection.start()
            guard case .hello(let hello) = try await connection.receive(DeviceMessage.self) else { connection.close(); return }
            guard hello.version == Remote.version else {
                let stale = hello.version < Remote.version ? "this device" : "your Mac"
                try await connection.send(HostMessage.refused("Update Queen Bee on \(stale), so both are on the same version."))
                connection.close()
                return
            }
            guard isOn, hello.deviceID == deviceID, let device = devices.devices.first(where: { $0.id == deviceID }) else {
                connection.close()
                return
            }
            let session = RemoteSession(connection: connection, device: device)
            sessions.append(session)
            session.send(.welcome(RemoteWelcome(version: Remote.version, macName: macName, canControl: device.canControl)))
            session.send(.library(library()))
            await session.run()
            sessions.removeAll { $0 === session }
        } catch {
            connection.close()
        }
    }

    // MARK: The flow list

    private func library() -> RemoteLibrary {
        RemoteLibrary(projects: AppServices.shared.projects.map { project in
            RemoteProject(id: project.root.path, name: project.name, flows: project.controllers.map {
                RemoteFlowSummary(id: $0.flow.id, name: $0.flow.name, isSubflow: $0.flow.isSubflow == true, activity: $0.activity)
            })
        })
    }

    /// Sends the flow list to every device whenever a project, a flow's name or what a flow needs changes.
    private func watchLibrary() {
        guard isOn else { return }
        var current = RemoteLibrary(projects: [])
        withObservationTracking { current = library() } onChange: {
            Task { @MainActor in RemoteHost.shared.watchLibrary() }
        }
        guard current != lastLibrary else { return }
        lastLibrary = current
        sessions.forEach { $0.send(.library(current)) }
    }

    // MARK: Pairing

    /// Puts a new one-time code on offer and listens for the device that scans it.
    func beginPairing() {
        cancelPairing()
        let offer = PairingOffer(code: PairingCode(), expires: Date().addingTimeInterval(Self.pairingWindow))
        pairing = offer
        do {
            let service = localOnly ? nil : NWListener.Service(name: macName, type: Remote.pairingService)
            let listener = try LinkListener(key: offer.code.secret, service: service, localOnly: localOnly)
            pairingListener = listener
            Task {
                do {
                    let port = try await listener.start { connection in
                        Task { @MainActor in await RemoteHost.shared.pair(connection, offer: offer) }
                    }
                    if pairing == offer { pairingPort = port }
                } catch {
                    problem = "Queen Bee couldn't start pairing: \(error)"
                    if pairing == offer { cancelPairing() }
                }
            }
        } catch {
            problem = "Queen Bee couldn't start pairing: \(error)"
            cancelPairing()
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.pairingWindow))
            if pairing == offer { cancelPairing() }
        }
    }

    func cancelPairing() {
        pairingListener?.stop()
        pairingListener = nil
        pairingPort = nil
        pairing = nil
    }

    private func pair(_ connection: LinkConnection, offer: PairingOffer) async {
        defer { connection.close() }
        do {
            try await connection.start()
            let request = try await connection.receive(PairRequest.self)
            // The code works once: the first device to get this far takes it.
            guard pairing == offer, offer.expires > Date() else { return }
            guard request.version == Remote.version else {
                let stale = request.version < Remote.version ? "this device" : "your Mac"
                try await connection.send(PairReply.refused("Update Queen Bee on \(stale), so both are on the same version."))
                return
            }
            // The id ends up in a Keychain entry and a service record, so it has to be a real id.
            guard UUID(uuidString: request.deviceID) != nil else {
                try await connection.send(PairReply.refused("This device sent an id Queen Bee can't use."))
                return
            }
            cancelPairing()
            let id = request.deviceID.lowercased()
            let name = String(request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            stopListening(id)
            let key = devices.add(id: id, name: name.isEmpty ? "Device" : name)
            try await connection.send(PairReply.granted(PairGrant(key: key, macID: devices.macID, macName: macName)))
            if let device = devices.devices.first(where: { $0.id == id }) { listen(for: device) }
        } catch {}
    }
}
```

- [ ] **Step 4: Start and stop it with the app**

In `App/AppServices.swift`:
- In `start()`, add `RemoteHost.shared.start()` on the line after `restoreProjects()`.
- In `shutDown()`, add `RemoteHost.shared.shutDown()` as the first line.

- [ ] **Step 5: Build**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Check nothing changed with Remote off**

Run: `./scripts/e2e.py guard settings`
Expected: `0 failed`

- [ ] **Step 7: Commit**

```bash
./scripts/check-clean.sh
git add App
git commit -m "Listen for paired devices, pair new ones, and send them the flow list"
```

---

### Task 9: Sending a device the flow it has open

**Files:**
- Modify: `App/Remote/RemoteSession.swift`

- [ ] **Step 1: Replace the file with the full version**

Replace `App/Remote/RemoteSession.swift`:

```swift
import Foundation
import Observation
import QueenBeeCore
import QueenBeeLink

/// One connected device: what it is sent, and the flow it has open.
final class RemoteSession {
    let connection: LinkConnection
    let device: PairedDevice
    private let outbox: AsyncStream<HostMessage>.Continuation
    private var pump: Task<Void, Never>?

    /// The flow the device is looking at, what it was last told about it, and how many times the graph has changed.
    private var controller: FlowController?
    private var last: RemoteFlowSnapshot?
    private var revision = 0
    private var flushTask: Task<Void, Never>?
    /// At most this many updates a second, however fast a card is being dragged on the Mac.
    private static let flushEvery: Duration = .milliseconds(50)

    /// The terminals being followed, by session key, with the session each belongs to.
    private var feeds: [String: (session: TerminalSession, token: UUID)] = [:]
    /// Terminal bytes queued and not yet sent. Past the limit the backlog is dropped and each terminal starts afresh.
    private var queuedTerminalBytes = 0
    private var isFlooded = false
    private static let terminalBacklogLimit = 2_000_000

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

    private func sent(_ message: HostMessage) {
        guard case .terminal(_, _, let chunk) = message else { return }
        queuedTerminalBytes -= chunk.data.count
        if isFlooded, queuedTerminalBytes <= 0 {
            isFlooded = false
            queuedTerminalBytes = 0
            followTerminals()
        }
    }

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

    func close() {
        open(nil)
        outbox.finish()
        connection.close()
    }

    // MARK: The open flow

    private func open(_ new: FlowController?) {
        flushTask?.cancel()
        flushTask = nil
        unfollowTerminals()
        controller = new
        last = nil
        guard let new else { return }
        let snapshot = Self.snapshot(of: new)
        last = snapshot
        send(.opened(snapshot))
        followTerminals()
        watch()
    }

    private static func snapshot(of controller: FlowController) -> RemoteFlowSnapshot {
        // Read so that a session being replaced counts as a change.
        _ = controller.sessionGeneration
        let run = RemoteRunState(
            isRunning: controller.isRunning, marks: controller.marks, linkPasses: controller.linkPasses,
            liveLinkIDs: controller.liveLinkIDs.sorted(), handOffs: controller.handOffs, holds: controller.holds,
            results: controller.results, usage: controller.usage, sessions: controller.sessions.mapValues(\.state),
            awaitingAnswer: controller.awaitingAnswer.sorted(), banner: controller.banner)
        return RemoteFlowSnapshot(flow: controller.flow, run: run, log: controller.log, messages: controller.messages,
                                  runs: controller.runs)
    }

    /// Asks to be told the next time anything a snapshot reads changes. It tells once, so each flush asks again.
    private func watch() {
        guard let controller else { return }
        withObservationTracking { _ = Self.snapshot(of: controller) } onChange: { [weak self] in
            Task { @MainActor in self?.flushSoon() }
        }
    }

    private func flushSoon() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushEvery)
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    private func flush() {
        guard let controller, let old = last else { return }
        let new = Self.snapshot(of: controller)
        if new.flow != old.flow { revision += 1 }
        RemoteSnapshot.updates(from: old, to: new, revision: revision).forEach(send)
        last = new
        if Set(controller.sessions.keys) != Set(feeds.keys) || controller.sessions.contains(where: { feeds[$0.key]?.session !== $0.value }) {
            followTerminals()
        }
        watch()
    }

    // MARK: Terminals

    /// Sends each terminal's screen as it is now, then everything after.
    private func followTerminals() {
        unfollowTerminals()
        guard let controller else { return }
        let flowID = controller.flow.id
        for (key, session) in controller.sessions {
            queueTerminal(flowID, key, session.feed.snapshot())
            let token = session.feed.addListener { [weak self] chunk in self?.queueTerminal(flowID, key, chunk) }
            feeds[key] = (session, token)
        }
    }

    private func unfollowTerminals() {
        feeds.values.forEach { $0.session.feed.removeListener($0.token) }
        feeds.removeAll()
    }

    private func queueTerminal(_ flowID: String, _ key: String, _ chunk: TerminalChunk) {
        guard !isFlooded else { return }
        queuedTerminalBytes += chunk.data.count
        // A device that can't keep up gets each screen afresh once the queue drains, not an ever-longer backlog.
        if queuedTerminalBytes > Self.terminalBacklogLimit {
            isFlooded = true
            unfollowTerminals()
            return
        }
        send(.terminal(id: flowID, key: key, chunk: chunk))
    }
}
```

- [ ] **Step 2: Build**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
./scripts/check-clean.sh
git add App/Remote/RemoteSession.swift
git commit -m "Send a device the flow it has open, its changes and its terminals"
```

---

### Task 10: The test client and the end-to-end check

**Files:**
- Create: `Tools/RemoteCheck/main.swift`
- Modify: `project.yml`, `App/Testing/TestHarness.swift`, `App/AppServices.swift` (`handle`), `scripts/e2e.py`

- [ ] **Step 1: Add the tool target**

In `project.yml`, add under `targets:` after `qb`:

```yaml
  qb-remote-check:
    type: tool
    platform: macOS
    sources:
      - path: Tools/RemoteCheck
    dependencies:
      - package: QueenBeeCore
      - package: QueenBeeCore
        product: QueenBeeLink
    settings:
      base:
        PRODUCT_NAME: qb-remote-check
        SKIP_INSTALL: YES
```

and under `schemes: QueenBee: build: targets:` add `qb-remote-check: all` after `QueenBee: all`.

- [ ] **Step 2: Write the client**

Create `Tools/RemoteCheck/main.swift`:

```swift
// A stand-in for a paired device, for scripts/e2e.py. It pairs with a test copy of the app over this
// machine's loopback, connects, opens a flow, and prints one line of JSON for everything it is sent.
//
//   qb-remote-check --code <pairing code> --pair-port <n> --flow <id> [--seconds <n>]
//   qb-remote-check --port <n> --device <id> --wrong-key
//
// After pairing it prints the device id, then waits for the device's port on standard input.
import Foundation
import Network
import QueenBeeCore
import QueenBeeLink

func say(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func option(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func local(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

if CommandLine.arguments.contains("--wrong-key") {
    // A device that was never paired: it knows where to connect and has no key.
    let connection = LinkConnection(to: local(UInt16(option("--port") ?? "") ?? 0), key: LinkSecurity.randomKey())
    do {
        try await connection.start(timeout: 4)
        try await connection.send(DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: option("--device") ?? "", deviceName: "Stranger")))
        _ = try await connection.receive(HostMessage.self)
        say(["type": "let-in"])
    } catch {
        say(["type": "kept-out"])
    }
    exit(0)
}

guard let code = option("--code").flatMap(PairingCode.init(text:)), let pairPort = option("--pair-port").flatMap(UInt16.init),
      let flowID = option("--flow") else {
    say(["type": "usage"])
    exit(2)
}
let seconds = option("--seconds").flatMap(Double.init) ?? 20
let deviceID = UUID().uuidString.lowercased()

let grant: PairGrant
do {
    let pairing = LinkConnection(to: local(pairPort), key: code.secret)
    try await pairing.start(timeout: 5)
    try await pairing.send(PairRequest(version: Remote.version, deviceID: deviceID, deviceName: "Test device"))
    guard case .granted(let granted) = try await pairing.receive(PairReply.self) else {
        say(["type": "pair-refused"])
        exit(0)
    }
    grant = granted
    pairing.close()
} catch {
    say(["type": "pair-failed"])
    exit(0)
}
say(["type": "paired", "device": deviceID, "mac": grant.macName.isEmpty ? "" : "named"])

guard let port = readLine().flatMap({ UInt16($0.trimmingCharacters(in: .whitespaces)) }) else {
    say(["type": "no-port"])
    exit(2)
}
let connection = LinkConnection(to: local(port), key: grant.key)
do {
    try await connection.start(timeout: 5)
    try await connection.send(DeviceMessage.hello(RemoteHello(version: Remote.version, deviceID: deviceID, deviceName: "Test device")))
} catch {
    say(["type": "connect-failed", "error": "\(error)"])
    exit(0)
}

Task {
    try? await Task.sleep(for: .seconds(seconds))
    say(["type": "time-up"])
    exit(0)
}

while true {
    let message: HostMessage
    do { message = try await connection.receive(HostMessage.self) } catch {
        say(["type": "ended"])
        exit(0)
    }
    switch message {
    case .welcome(let welcome):
        say(["type": "welcome", "version": welcome.version, "canControl": welcome.canControl])
    case .refused(let reason):
        say(["type": "refused", "reason": reason])
    case .library(let library):
        say(["type": "library", "flows": library.projects.flatMap(\.flows).map(\.name)])
        try? await connection.send(DeviceMessage.open(flowID: flowID))
    case .opened(let snapshot):
        say(["type": "opened", "name": snapshot.flow.name, "cards": snapshot.flow.cards.count,
             "sessions": snapshot.run.sessions.mapValues(\.rawValue)])
    case .flow(_, let revision, let flow):
        say(["type": "flow", "revision": revision, "efforts": flow.cards.map { $0.effort ?? "" }])
    case .run(_, let state):
        say(["type": "run", "isRunning": state.isRunning])
    case .log(_, let lines, let reset):
        say(["type": "log", "lines": lines.count, "reset": reset])
    case .messages(_, let link, let all):
        say(["type": "messages", "link": link, "count": all.count])
    case .history(_, let runs):
        say(["type": "history", "runs": runs.count])
    case .terminal(_, let key, let chunk):
        say(["type": "terminal", "key": key, "reset": chunk.reset, "bytes": chunk.data.count, "cols": chunk.cols, "rows": chunk.rows])
    }
}
```

- [ ] **Step 3: Give the test harness a way to drive Remote**

In `App/Testing/TestHarness.swift`, add to `enum TestHarness`, after `handleApp`:

```swift
    /// Turns Remote on, pairs and unpairs, for a test copy only. Nil for anything else.
    static func handleRemote(_ payload: JSONValue) async -> JSONValue? {
        guard isEnabled else { return nil }
        let host = RemoteHost.shared
        /// A listener's port is known a moment after it starts.
        func soon(_ read: () -> UInt16?) async -> UInt16? {
            for _ in 0..<50 {
                if let port = read() { return port }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        switch payload["op"]?.stringValue {
        case "remote-on":
            host.setOn(true)
            return ["on": .bool(host.isOn)]
        case "remote-pair":
            host.beginPairing()
            guard let port = await soon({ host.pairingPort }), let code = host.pairing?.code.text else { return ["error": "pairing didn't start"] }
            return ["code": .string(code), "port": .number(Double(port))]
        case "remote-port":
            let id = payload["device"]?.stringValue ?? ""
            guard let port = await soon({ host.ports[id] }) else { return ["error": "not listening for that device"] }
            return ["port": .number(Double(port))]
        case "remote-state":
            return ["devices": .number(Double(host.devices.devices.count)), "connected": .number(Double(host.sessions.count)),
                    "pairing": .bool(host.pairing != nil)]
        case "remote-remove":
            host.remove(payload["device"]?.stringValue ?? "")
            return [:]
        default:
            return nil
        }
    }
```

In `App/AppServices.swift`, in `handle(_:)`, inside `if request.kind == "test" {`, add after the `guard TestHarness.isEnabled` line:

```swift
            if let reply = await TestHarness.handleRemote(request.payload) { return reply }
```

- [ ] **Step 4: Write the scenario**

In `scripts/e2e.py`:

Add `import queue` and `import threading` to the imports.

Add under the `APP = ...` line:

```python
CHECK = os.path.join(ROOT, "build/Build/Products/Debug/qb-remote-check")
```

Add after `scenario_settings`:

```python
class Device:
    """The stand-in for a paired device: runs qb-remote-check and reads what it prints."""

    def __init__(self, *args):
        self.proc = subprocess.Popen([CHECK, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        self.seen = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(json.loads(line))
        self.lines.put({"type": "exited"})

    def tell(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def until(self, wanted, timeout=20):
        """The next message that passes `wanted` (a type name or a test), or None. Earlier ones stay in `seen`."""
        test = wanted if callable(wanted) else (lambda m: m["type"] == wanted)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.lines.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                return None
            self.seen.append(message)
            if test(message):
                return message
            if message["type"] == "exited":
                return None
        return None

    def stop(self):
        self.proc.kill()


def scenario_remote(app):
    print("remote: a paired device gets the flow, its changes and its terminals, and nobody else gets anything", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    check("Remote turns on", app.op("app", "remote-on").get("on") is True)
    offer = app.op("app", "remote-pair")
    check("pairing puts a one-time code on offer", str(offer.get("code", "")).startswith("queenbee-pair:1:"), str(offer.keys()))

    device = Device("--code", offer["code"], "--pair-port", str(int(offer["port"])), "--flow", fid, "--seconds", "60")
    try:
        paired = device.until("paired")
        check("the device pairs", paired is not None, str(device.seen))
        check("the code is put away once it has been used", app.op("app", "remote-state")["pairing"] is False)
        port = int(app.op("app", "remote-port", device=paired["device"])["port"])
        device.tell(str(port))

        welcome = device.until("welcome")
        check("a paired device is let in, to watch only", welcome is not None and welcome["canControl"] is False, str(device.seen))
        library = device.until("library")
        check("it is sent the flow list", library is not None and "Guard" in library["flows"], str(library))
        opened = device.until("opened")
        check("it is sent the flow it opened", opened is not None and opened["name"] == "Guard" and opened["cards"] == 3, str(opened))
        check("with each session's state", opened is not None and "orchestrator" in opened["sessions"], str(opened))
        first = device.until(lambda m: m["type"] == "terminal" and m["reset"] and m["bytes"] > 0)
        check("and each terminal's screen as it is now", first is not None, str(device.seen[-4:]))

        app.op(fid, "edit", card="Alice", effort="high")
        changed = device.until(lambda m: m["type"] == "flow" and "high" in m["efforts"])
        check("a change on the Mac reaches the device", changed is not None and changed["revision"] >= 1, str(device.seen[-4:]))
        app.op(fid, "edit", card="Alice", effort="")
        check("and so does changing it back", device.until(lambda m: m["type"] == "flow" and "high" not in m["efforts"]) is not None)

        again = Device("--code", offer["code"], "--pair-port", str(int(offer["port"])), "--flow", fid)
        check("a used code pairs nothing", again.until(lambda m: m["type"] in ("pair-failed", "pair-refused"), 10) is not None, str(again.seen))
        again.stop()

        stranger = Device("--port", str(port), "--device", paired["device"], "--wrong-key")
        check("a device without the key is kept out", stranger.until("kept-out", 10) is not None, str(stranger.seen))
        stranger.stop()

        app.op("app", "remote-remove", device=paired["device"])
        check("removing a device ends its connection", device.until("ended", 10) is not None, str(device.seen[-3:]))
        check("and forgets it", app.op("app", "remote-state")["devices"] == 0)
        late = Device("--port", str(port), "--device", paired["device"], "--wrong-key")
        check("and nothing listens where it used to connect", late.until("kept-out", 10) is not None, str(late.seen))
        late.stop()
    finally:
        device.stop()
```

In `main()`:
- Add `"remote"` to the default list in `wanted`, after `"settings"`.
- Change `flow_id = (GUARD if name in ("scroll", "settings") else FLOWS[name])["id"]` to use `("scroll", "settings", "remote")`.
- Change `if not (name in ("guard", "settings") and ("settings" in later or "scroll" in later)):` to `if not (name in ("guard", "settings", "remote") and any(n in later for n in ("settings", "remote", "scroll"))):`.

Add `remote` to the list of scenarios in the docstring at the top of the file.

- [ ] **Step 5: Build and run it**

Run: `./scripts/build.sh && ./scripts/e2e.py remote`
Expected: every `remote` check prints `PASS`, then `0 failed`

- [ ] **Step 6: Run what already existed**

Run: `./scripts/e2e.py guard settings remote scroll`
Expected: `0 failed`

- [ ] **Step 7: Commit**

```bash
./scripts/check-clean.sh
git add Tools project.yml App scripts/e2e.py
git commit -m "Check the link end to end with a stand-in for a paired device"
```

---

### Task 11: Settings, the pairing sheet and the connected mark

**Files:**
- Create: `App/Views/RemoteSettingsView.swift`
- Modify: `App/Views/SettingsView.swift`, `App/Views/SidebarView.swift`

- [ ] **Step 1: Write the Remote section and the pairing sheet**

Create `App/Views/RemoteSettingsView.swift`:

```swift
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Remote part of Settings: whether paired devices may connect, which are paired, and pairing another.
struct RemoteSettingsSection: View {
    @AppStorage(RemoteHost.enabledKey) private var enabled = false
    @State private var showsPairing = false
    private var host: RemoteHost { RemoteHost.shared }

    var body: some View {
        Section {
            Toggle("Allow remote devices", isOn: $enabled)
                .onChange(of: enabled) { host.setOn(enabled) }
            if enabled {
                ForEach(host.devices.devices) { device in
                    LabeledContent(device.name) {
                        HStack(spacing: 8) {
                            if host.sessions.contains(where: { $0.device.id == device.id }) { Badge(text: "connected", tone: .live) }
                            Button("Remove") { host.remove(device.id) }
                        }
                    }
                }
                Button("Pair a device…") {
                    host.beginPairing()
                    showsPairing = true
                }
                if let problem = host.problem {
                    Text(problem).font(.dsSans(Theme.Size.caption)).foregroundStyle(Theme.failInk.ui)
                }
            }
        } header: {
            Text("Remote")
        } footer: {
            Text("A paired iPad or iPhone on your Wi-Fi can see your flows and their terminals. Nothing leaves your network.")
        }
        .sheet(isPresented: $showsPairing, onDismiss: { host.cancelPairing() }) {
            PairingSheet()
        }
    }
}

/// The one-time code a device scans, with how long it has left.
private struct PairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var host: RemoteHost { RemoteHost.shared }

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair a device").font(.dsSans(Theme.Size.title, .semibold))
            if let offer = host.pairing {
                if let image = Self.qr(offer.code.text) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Open Queen Bee on your iPad or iPhone, pick this Mac and scan the code.")
                    .multilineTextAlignment(.center)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Works once, for \(max(0, Int(offer.expires.timeIntervalSince(context.date)))) more seconds.")
                        .foregroundStyle(.secondary)
                }
                Button("Copy the Code as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(offer.code.text, forType: .string)
                }
                .help("For a device with no camera, such as the Simulator. Anyone who has the code can pair while it works.")
            } else {
                Text("Done, or the code ran out.").foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .font(.dsSans(Theme.Size.body))
        .padding(22)
        .frame(width: 320)
        // The code goes away when a device has used it or its time is up.
        .onChange(of: host.pairing == nil) { if host.pairing == nil { dismiss() } }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
```

If `Theme.Size.title` does not exist, use the largest size `App/Design/Tokens.swift` defines under `Theme.Size`.

- [ ] **Step 2: Put the section in Settings**

In `App/Views/SettingsView.swift`, add `RemoteSettingsSection()` as the last item inside the `Form`, after the `LabeledContent("Claude Code")` block.

- [ ] **Step 3: Show when a device is connected**

In `App/Views/SidebarView.swift`, in `body`, add directly after the first `Rectangle().fill(Theme.hairline.ui).frame(height: 1)`:

```swift
            if !RemoteHost.shared.sessions.isEmpty {
                let names = RemoteHost.shared.sessions.map(\.device.name).joined(separator: ", ")
                Label(names, systemImage: "ipad.and.iphone")
                    .font(.dsMono(Theme.Size.caption))
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Connected to this Mac. Manage devices in Settings.")
                Rectangle().fill(Theme.hairline.ui).frame(height: 1)
            }
```

- [ ] **Step 4: Build and look**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`

Then open the built app (`open build/Build/Products/Debug/QueenBee.app`), open Settings, and check by eye:
1. With "Allow remote devices" off, nothing else shows in the Remote section.
2. Turning it on shows "Pair a device…". macOS may ask to allow the local network.
3. "Pair a device…" shows a QR code and a countdown. "Copy the Code as Text" puts a string starting `queenbee-pair:1:` on the clipboard.
4. Closing the sheet and opening it again shows a different code.

- [ ] **Step 5: Pair with the test client against the real listener path**

With the sheet open, find the pairing port and run the client (it uses loopback, which reaches a listener on every interface):

```bash
PORT=$(lsof -nP -iTCP -sTCP:LISTEN -a -c QueenBee | awk 'NR>1 {split($9,a,":"); print a[2]}' | sort -un | tail -1)
build/Build/Products/Debug/qb-remote-check --code "$(pbpaste)" --pair-port "$PORT" --flow none --seconds 5 < /dev/null
```

Expected: a line with `"type":"paired"`, then `"type":"no-port"`. In Settings the sheet closes and "Test device" appears in the list. Click Remove and check it goes.

- [ ] **Step 6: Commit**

```bash
./scripts/check-clean.sh
git add App/Views
git commit -m "Remote in Settings: allow devices, pair one, remove one"
```

---

### Task 12: Docs and the full check

**Files:**
- Modify: `SECURITY.md`, `CHANGELOG.md`, `README.md`

- [ ] **Step 1: Say what Remote does to the Mac**

In `SECURITY.md`, add at the end of the list under "What Queen Bee does on your Mac":

```markdown
- **Remote is off until you turn it on.** With "Allow remote devices" on, an iPad or iPhone you paired can connect
  over your local network and see your flows, their runs and their terminals. Pairing takes a one-time code shown
  on this Mac, which works once and for two minutes. Each paired device has its own key, kept in the Keychain on
  both sides and never in a file, and every connection is encrypted with it; a device without a key is told
  nothing. Removing a device in Settings deletes its key and closes its connection at once. A paired device
  cannot add a project folder, answer the "trust this folder" prompt, or change the Remote settings. Queen Bee
  does not connect to any server for this, and nothing is reachable from outside your network unless your network
  makes it so.
```

- [ ] **Step 2: Note the change**

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown
### Added

- Remote, in Settings: pair an iPad or iPhone with this Mac over local Wi-Fi. This release has the Mac side only; the companion app is still being built.
```

In `README.md`, add one line where features in progress are listed, or at the end of the feature list if there is no such place: `- **Remote (in progress).** The Mac side of an iPad and iPhone companion that works over local Wi-Fi with no server.`

- [ ] **Step 3: Run everything**

Run: `cd Core && swift test 2>&1 | tail -3 && cd .. && ./scripts/build.sh && ./scripts/build.sh Release && ./scripts/e2e.py`
Expected: Core tests pass, both builds succeed, e2e prints `0 failed`

- [ ] **Step 4: Check a release build has no test door into Remote**

Run: `strings build/Build/Products/Release/QueenBee.app/Contents/MacOS/QueenBee | grep -c "remote-pair" || true`
Expected: `0`. If it is not, wrap the body of `TestHarness.handleRemote` in `#if DEBUG` with `return nil` in the `#else`, rebuild, and run this step again.

- [ ] **Step 5: Read the whole diff for anything private**

Run: `./scripts/check-clean.sh && git diff main --stat && git diff main | grep -nE "token|secret|key" | grep -vE "^\+.*//|KeyVault|kSec" | head -40`
Expected: `clean`, and every line the last command prints is code that handles a key, never a key's value.

- [ ] **Step 6: Commit**

```bash
git add SECURITY.md CHANGELOG.md README.md
git commit -m "Say what Remote does and how it is kept safe"
```

---

## What 1B picks up

- The iOS target in `project.yml`, with its team id read from a git-ignored `Mobile/Local.xcconfig`.
- A client built on `LinkConnection`: browse `_queenbee-pair._tcp` to pair, then `_queenbee._tcp` with the record's `device` equal to its own id.
- A mirror model fed by `HostMessage`, the touch canvas, terminals fed by `TerminalChunk`, and the panels.
