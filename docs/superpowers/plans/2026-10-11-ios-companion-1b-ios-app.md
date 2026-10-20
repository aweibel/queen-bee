# iOS Companion, Stage 1B: The iPad and iPhone App — Implementation Plan

**Status: done, shipped in 0.5.0.** The boxes below were the working list and were left unticked. The Result section at the end says what was built and how it was checked.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An iPad app (that also runs on iPhone) that pairs with the Mac app over local Wi-Fi and shows every flow, its live canvas, its terminals and its runs. Watch-only.

**Architecture:** A new iOS target, `QueenBeeMobile`, in `Mobile/`. It links the same `QueenBeeCore` (messages, model, geometry) and `QueenBeeLink` (encrypted connection) the Mac uses. What the Mac sends is applied to a pure mirror model in Core; SwiftUI draws the shell and panels, UIKit draws the canvas, and SwiftTerm's iOS view draws terminals from the Mac's stream.

**Tech Stack:** Swift 6, SwiftUI + UIKit, iOS 26, Network framework (`NWBrowser`), VisionKit or AVFoundation for the QR scan, SwiftTerm 1.99.0, XcodeGen, the iOS Simulator.

**Spec:** `docs/superpowers/specs/2026-10-11-ios-companion-design.md`. **Mac side:** `docs/superpowers/plans/2026-10-11-ios-companion-1a-mac-link.md`.

---

## How this plan differs from 1A

1A gave every line of code and the subagents still had to adapt it to what compiled. This plan gives the structure, the interfaces between parts, and what each task must prove. Each task's implementer reads the Mac code it mirrors and writes code that compiles against the real thing.

## Rules for every commit

- The repository is public. Run `./scripts/check-clean.sh` and read the staged diff before every commit. No team id, key, provisioning profile, home folder path, real device name or network address.
- Signing details live only in `Mobile/Local.xcconfig`, which is git-ignored. `project.yml` and every committed file stay free of a team id.
- Commit locally. Never push.
- The Mac app must keep working: `./scripts/build.sh` succeeds and `./scripts/e2e.py guard settings remote` passes at the end.
- Plain wording in everything a person reads, for non-technical people.

## What is already there (read before writing)

| Thing | Where |
|---|---|
| Messages (`HostMessage`, `DeviceMessage`, `PairRequest`, `PairReply`, `PairGrant` with `deviceID`, `RemoteFlowSnapshot`, `RemoteRunState`, `TerminalChunk`) | `Core/Sources/QueenBeeCore/Remote.swift` |
| What the Mac sends on change | `Core/Sources/QueenBeeCore/RemoteSnapshot.swift` |
| Flow model, ports, warnings, link routing, snapping, tidy | `Core/Sources/QueenBeeCore/Model.swift`, `Warnings.swift`, `LinkRouter.swift`, `Snapping.swift`, `Tidy.swift` |
| Run types (`RunMark`, `PendingHold`, `LogLine`, `LinkMessage`, `RunRecord`, `Usage`, `SessionState`, `FlowActivity`) | `Core/Sources/QueenBeeCore/RunState.swift` |
| Encrypted connection, pairing code | `Core/Sources/QueenBeeLink/LinkConnection.swift`, `LinkSecurity.swift` |
| How the Mac serves a device | `App/Remote/RemoteHost.swift`, `RemoteSession.swift`, `TerminalFeed.swift` |
| A working client, in 120 lines | `Tools/RemoteCheck/main.swift` |
| How the Mac draws the canvas | `App/Canvas/*.swift`, `App/Design/Tokens.swift`, `App/Views/*.swift` |
| How a second terminal follows the stream | `MirrorWindow` in `App/Testing/TestHarness.swift`, and "Result of Task 2" in the 1A plan |

Facts the client depends on:

- **Pairing:** browse `_queenbee-pair._tcp`, connect with the scanned code's secret as the key, send `PairRequest`, get `PairReply`. Keep `PairGrant.key`, `macID`, `macName`, and use `PairGrant.deviceID` as the device's id from then on.
- **Connecting:** browse `_queenbee._tcp` and pick the service whose TXT record has `device` equal to this device's id and `mac` equal to the paired Mac's id. Connect with the device key. Send `.hello`. Expect `.welcome` then `.library`, or `.refused(text)`.
- **A wrong key fails at once with a TLS error.** `.refused` with the "no longer paired" text, or a TLS error on a listener that exists, means the device must pair again. No listener found means "Mac not found".
- **Opening a flow:** send `.open(flowID:)`. Get `.opened(snapshot)`, then `.flow`, `.run`, `.log`, `.messages`, `.history` and `.terminal` updates.
- **Terminal chunks:** with `reset` set, clear the terminal entirely (screen, history, modes), size it to `cols` × `rows`, then feed `data`. Without it, feed `data`. The stream contains the program's own terminal queries, so anything the iOS terminal view tries to send back must be dropped, never sent to the Mac.
- **The first connection on a device sits waiting** while iOS asks to use the local network. `LinkConnection.start` rides that out until its timeout.

## File map

| Path | Responsibility |
|---|---|
| `project.yml` (modify) | The `QueenBeeMobile` target and scheme |
| `Mobile/Config.xcconfig` (new) | Default bundle id; optionally includes `Local.xcconfig` |
| `Mobile/Local.example.xcconfig` (new) | The two lines a person fills in to install on their own device |
| `Mobile/Info.plist` (new) | Local network, Bonjour types, camera reason, orientations |
| `scripts/build-mobile.sh` (new) | Builds the app for the Simulator |
| `scripts/check-clean.sh`, `.github/workflows/tests.yml` (modify) | Cover the new target |
| `Core/Sources/QueenBeeCore/RemoteMirror.swift` (new) | What a device knows, and how each message changes it. Pure, unit-tested |
| `Mobile/App/` | App entry, root state |
| `Mobile/Link/` | Device identity and key storage, finding the Mac, pairing, the connection and reconnecting |
| `Mobile/Model/` | The observable store wrapping `RemoteMirror`; terminal registry |
| `Mobile/Design/` | Colours, type and spacing matching the Mac's Flight plan look |
| `Mobile/Canvas/` | UIKit canvas: scroll and zoom, cards, links, groups |
| `Mobile/Terminals/` | SwiftTerm views fed by chunks; the full-screen viewer |
| `Mobile/Views/` | SwiftUI: pairing, sidebar, inspector, run log, history, cost, connection pill |
| `README.md`, `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md` (modify) | How to build and install it; what it can do |

## Testing approach

- **Core:** `RemoteMirror` is tested with `swift test`.
- **The app, automatically:** it runs in the iOS Simulator on this Mac against a test copy of the Mac app (`--testing`, keys in memory, loopback only, no system prompts). A DEBUG-only path lets the app be told where to connect and what code to pair with by launch arguments, because the test copy does not advertise itself. The Mac's test harness reports whether a device is connected.
- **The app, by eye:** screenshots from the Simulator (`xcrun simctl io <device> screenshot`), compared with the Mac window for the same flow. Each UI task ends with screenshots in light and dark that the implementer has looked at.
- **By hand, by the owner, at the end:** the camera scan, the local-network prompt and real Wi-Fi, on a real iPad.

---

### Task 1: The target, and Core's mirror model

- [ ] Add `QueenBeeMobile` to `project.yml`: iOS application, deployment target 26.0, iPhone and iPad, sources `Mobile/`, dependencies `QueenBeeCore`, `QueenBeeLink`, `SwiftTerm`. Settings come from `Mobile/Config.xcconfig`, which sets `PRODUCT_BUNDLE_IDENTIFIER = dev.queenbee.mobile` and ends with `#include? "Local.xcconfig"`. No `DEVELOPMENT_TEAM` anywhere committed. Give it its own scheme. The `QueenBee` scheme and `./scripts/build.sh` must be unaffected.
- [ ] `Mobile/Local.example.xcconfig` with commented `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` lines and one sentence on each.
- [ ] `Mobile/Info.plist`: `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_queenbee._tcp`, `_queenbee-pair._tcp`), `NSCameraUsageDescription`, all orientations on iPad.
- [ ] A minimal SwiftUI app that launches and shows the app name.
- [ ] `scripts/build-mobile.sh`: generates the project and builds for an iOS Simulator destination into `./build`, in the style of `scripts/build.sh`, and says plainly whether it worked.
- [ ] CI: a step that builds the iOS app for the Simulator, unsigned.
- [ ] `RemoteMirror` in Core, test-first:
  - Holds `library: RemoteLibrary?`, `welcome: RemoteWelcome?`, `refusal: String?`, `openFlowID: String?`, `snapshot: RemoteFlowSnapshot?`, `revision: Int`.
  - `mutating func apply(_ message: HostMessage) -> [TerminalEvent]`: applies every case; a message for a flow that is not the open one is ignored; `.log` appends or replaces by `reset`; `.messages` replaces one link's list, removing the key when empty; `.terminal` is returned as an event (`key`, `chunk`) and not stored.
  - `mutating func willOpen(_ flowID: String?)`: clears the snapshot until `.opened` arrives.
  - A property test in spirit: for a sequence of snapshots, applying `RemoteSnapshot.updates(from:to:revision:)` to a mirror that holds the first must leave it holding the last. Cover flow, run, log append, log reset, messages added and removed, and history.
- [ ] Verify: `cd Core && swift test`; `./scripts/build-mobile.sh`; `./scripts/build.sh`; the app launches in a Simulator (boot one, install, launch, screenshot).
- [ ] Commit.

### Task 2: Finding the Mac, pairing, and staying connected

- [ ] `DeviceIdentity`: the device's id and the paired Mac (`macID`, `macName`), saved in the app's defaults; the device key in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), never in a file. "Forget this Mac" deletes both.
- [ ] `MacBrowser`: `NWBrowser` for pairing services (name shown to the person) and for this device's own listener (matched by the TXT record's `device` and `mac`).
- [ ] `RemoteClient` (`@Observable`, main actor), with one state the UI reads: `unpaired`, `pairing`, `lookingForMac`, `connecting`, `connected`, `needsUpdate(text)`, `mustPairAgain(text)`. It owns the `RemoteMirror` and hands terminal events to the terminal registry (Task 5 fills that in; a stub is fine here).
  - Pairing: given a `PairingCode` and a chosen Mac, runs the exchange and saves the grant.
  - Connecting: finds the listener, connects, says hello, then reads messages into the mirror until the connection ends.
  - Reconnecting: after any drop, tries again with a short backoff (1, 2, 4, up to 8 seconds), and takes a fresh snapshot by re-sending `.open` for the flow that was open. Stops while the app is in the background and resumes when it returns (`scenePhase`).
  - Telling the cases apart as the "Facts" section says: no listener is "Mac not found"; a wrong key or the "no longer paired" refusal is `mustPairAgain`; a version refusal is `needsUpdate`.
- [ ] Pairing screens (SwiftUI), in plain words: a first screen that explains the two steps; the list of Macs found; the scanner (VisionKit `DataScannerViewController` if available, else AVFoundation), which accepts only a `queenbee-pair:` code; and "Paste the code" for a device with no camera. Camera permission denied gets a sentence and a button to Settings.
- [ ] A DEBUG-only direct path for tests: launch arguments give a host, a pairing port, a pairing code and a device port, and the app pairs and connects without Bonjour. For this the Mac's test copy needs known ports: let the test harness ask for fixed ports (for example through `LinkListener` taking an optional port, used only when `TestHarness.isEnabled`). Nothing of this exists in a Release build of either app; check with `strings` as 1A did.
- [ ] A new e2e scenario, `mobile` (not in the default list), in `scripts/e2e.py`: starts the test copy, turns Remote on, begins pairing, boots a Simulator, installs and launches the iOS app with the launch arguments, and checks through the Mac's harness that one device is paired and connected. Then removes the device on the Mac and checks the app is no longer connected. Saves a screenshot to the scratch folder.
- [ ] Verify: the scenario passes; `./scripts/e2e.py remote` still passes; screenshot shows the app past pairing.
- [ ] Commit.

### Task 3: The shell — flows, connection, the app's look

- [ ] `Mobile/Design/`: the Mac's Flight plan palette, type sizes, radii and spacing as UIKit and SwiftUI values, light and dark, read from `App/Design/Tokens.swift` so the two apps match. Mono and sans fonts as the Mac uses them.
- [ ] Root layout: `NavigationSplitView` on iPad (sidebar, canvas, a right-hand inspector column that can be hidden); on iPhone a stack (flow list, then canvas, with the inspector as a sheet).
- [ ] Sidebar: projects and their flows from `mirror.library`, sub-flows indented under the flow that uses them if that can be worked out from what the device has, each with the same activity badge wording as the Mac ("needs you", "running", "stopped"). Tapping a flow opens it.
- [ ] Connection pill: Connected to `<Mac name>`, Reconnecting, Mac not found. While not connected, the last state stays on screen, dimmed.
- [ ] The update and pair-again states as full-screen messages with one clear action each.
- [ ] A settings sheet: which Mac it is paired with, "Forget this Mac", the app version.
- [ ] Verify with screenshots, iPad and iPhone, light and dark, with at least three flows in the list (the e2e project has many). Extend the `mobile` scenario to open a named flow by launch argument and check the Mac saw the `.open` (add what is needed to `remote-state`).
- [ ] Commit.

### Task 4: The canvas

Read `App/Canvas/CanvasView.swift`, `CardView.swift`, `AgentCardView.swift`, `LogicCardView.swift`, `LinkLayerView.swift`, `GroupFrameView.swift` and `CanvasGeometry.swift` first. The aim is a one-to-one copy of what the Mac shows for the same flow, drawn with UIKit.

- [ ] A `UIScrollView`-based canvas: the dot-grid paper, content sized to the flow with the Mac's margins, pinch to zoom within the Mac's limits, one-finger pan, double-tap empty canvas to fit the whole flow clear of the panels. Zoom and position are per device and kept per flow while the app runs.
- [ ] Cards at the flow's `x`, `y`, `width`, `height`: title bar, kind, name, run badge and session state badge for agents, port rows for logic cards with their labels, note text, approval and script cards showing a waiting message when held, warnings from `QueenBeeCore.warnings(for:)`. Folded groups and group frames.
- [ ] Links routed with Core's `LinkRouter`, with pass counts, the live-link highlight, and the marks a run leaves (`RunMark`, `linkPasses`, `liveLinkIDs`), matching the Mac's colours and line weights.
- [ ] Tap a card or link to select it (the inspector shows it, Task 6); tap empty canvas to clear.
- [ ] Updates apply without rebuilding everything: a `.flow` or `.run` message changes only the views it affects, so a card being dragged on the Mac moves smoothly here.
- [ ] Agent cards leave a placeholder where the terminal goes (Task 5).
- [ ] Verify with screenshots against the Mac window for the same flows (the e2e project's Guard, Pan, Gates and a sub-flow one), light and dark; and by moving a card on the Mac through the harness and screenshotting before and after. Say in the report exactly what still differs from the Mac.
- [ ] Commit.

### Task 5: Terminals

Read "Result of Task 2" in the 1A plan and `MirrorWindow` in `App/Testing/TestHarness.swift` first.

- [ ] A terminal registry keyed by session key: one SwiftTerm `TerminalView` per session of the open flow, created on the first chunk, thrown away when the flow is closed. Applies chunks exactly as the "Facts" section says. Anything the view tries to send (replies to queries, key presses, mouse reports) is dropped. No keyboard comes up in stage 1.
- [ ] The terminal shows the Mac card's columns and rows exactly. Inside a card it is scaled to fit the card's terminal area and scales with canvas zoom; text stays sharp where it can.
- [ ] Each agent card hosts its terminal; the orchestrator's terminal has a place in the right-hand column, as on the Mac's side panel.
- [ ] An expand button on a card opens that terminal full screen, readable at its real size, where a finger scrolls back through earlier output. Scrolling a terminal inside the canvas must not fight canvas panning: in the canvas, drags pan the canvas; history is read in the full-screen view.
- [ ] After a reconnect or a reset chunk, the terminal ends up right with no leftovers.
- [ ] Verify: extend the `mobile` scenario so an agent prints a long reply before and after the app connects, then compare the Mac terminal's visible text (the harness `mirror-compare` op shows how to read it) with what the iOS terminal shows. For the iOS side add a DEBUG-only way to read a terminal's visible text out of the app (for example writing it to a file in the app's container that the script reads with `xcrun simctl get_app_container`). Screenshots of a card and of the full-screen view.
- [ ] Commit.

### Task 6: Panels — inspector, run log, history, cost, needs-you

Read `App/Views/InspectorView.swift`, `SidePanel.swift` and `CanvasOverlays.swift` first. Everything here is read-only.

- [ ] Inspector for the selected card: its settings as the Mac shows them (instructions, model, effort, permissions, folder, check, branches, command, schedule), shown as text, with a line saying changes are made on the Mac for now. For a selected link: the messages it carried.
- [ ] Run log for the open flow, following new lines; results of End cards.
- [ ] History: the list of earlier runs with outcome, time and cost. Picking one shows that run's marks, messages and log on the canvas on this device only, with "Back to latest". This works from `snapshot.runs` and never changes what the Mac shows.
- [ ] Cost: per card and total, using `Usage.price` and `tokenCount`.
- [ ] Needs-you banner: lists cards waiting on the person (held approvals, scripts needing allow, sessions in `needsYou`); tapping one centres that card. It says the answer is given on the Mac for now.
- [ ] Verify with a run that produces history (the e2e Gates or Loop flow) and screenshots of each panel on iPad and iPhone.
- [ ] Commit.

### Task 7: Finish

- [ ] iPhone pass: every screen usable at phone width; nothing clipped.
- [ ] Accessibility basics: Dynamic Type in the panels, VoiceOver labels on controls and cards, contrast in both themes.
- [ ] `README.md`: a section on building the companion and installing it on your own device with a free Apple ID (sign in to Xcode, copy `Mobile/Local.example.xcconfig` to `Mobile/Local.xcconfig` and fill it in, Developer Mode on the device, Run, trust the profile, repeat every 7 days), and on the Simulator.
- [ ] `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md` updated to match.
- [ ] `scripts/check-clean.sh` also fails on a `DEVELOPMENT_TEAM` value inside `project.yml` or `Mobile/Config.xcconfig`, and CI runs it.
- [ ] Full check: `cd Core && swift test`; `./scripts/build.sh`; `./scripts/build.sh Release`; `./scripts/build-mobile.sh`; `./scripts/e2e.py guard settings remote mirror mobile`; Release builds of both apps contain no test hooks.
- [ ] Read the whole diff for anything private.
- [ ] Commit.

## Left for the owner, on a real iPad

1. Fill in `Mobile/Local.xcconfig`, plug in the iPad, Run from Xcode.
2. Allow the local network when asked.
3. On the Mac: Settings → Remote → turn it on → "Pair a device…". On the iPad: choose the Mac and scan.
4. Open a flow and run it on the Mac while watching the iPad.

## Not in this plan

Running, stopping, approving and typing from the device (stage 2). Editing the canvas (stage 3). Connecting from outside the local network.

## Result

**What was built.** The `QueenBeeMobile` target in `Mobile/`, for iPad and iPhone on iOS 26, and `RemoteMirror` in
Core. The app pairs with the Mac by a scanned or pasted code, finds its own listener, and reconnects by itself. It
shows the Mac's projects and flows with their states; the open flow's canvas drawn with UIKit as the Mac draws it,
updated card by card; each agent's terminal in its card, the orchestrator's beside the canvas, and any of them
full screen with scroll-back; and the panels: a card's or link's details, the run log, End cards' answers, earlier
runs, cost, and a banner of what is waiting on you. An iPad gets three columns. An iPhone gets a list, then the
canvas, with the details in a sheet at half height. Everything is watch-only. What the build settled on that the
design did not have is listed at the top of the spec.

**What Task 7 changed.** On an iPhone the details panel never came up: it was the system's inspector, and it is now
a sheet of the app's own, with the flow fitted into what shows above it. A card zoomed out to its overview no
longer draws what is under the overview, which showed through when the canvas was faded with the Mac away.
VoiceOver is told each card's kind, name, state, whether it is waiting and where the run went; links and groups
can be found and selected; tabs say they are tabs. Text written straight on the paper uses ink, because the
lighter ink is below 4.5 to 1 there. In a Debug build the file the tests read is written only in the Simulator.
`scripts/check-clean.sh` refuses any team named in `project.yml` or `Mobile/Config.xcconfig`.

**How it was checked.**

| What | How | Result |
|---|---|---|
| Core, including `RemoteMirror` | `cd Core && swift test` | 245 tests pass |
| Both apps build | `./scripts/build.sh`, `./scripts/build-mobile.sh`, each also with `Release` | all four succeed |
| No test hooks in a release | `nm` and `strings` on both Release binaries for the test types and launch arguments, with the Debug builds as the control | none in Release; hundreds in Debug |
| Terminals and panels, with no Mac | `./scripts/e2e.py terminals panels` on an iPad Pro 11-inch and on an iPhone 17 simulator | 47 checks passed on each. Five more were added since, for how finely a terminal is drawn, and 52 pass on the iPad |
| Against the Mac's test copy, with real sessions | `./scripts/e2e.py guard settings remote mirror mobile` on the iPad simulator | 106 of 110 at first. The four were the script's: `mirror` left a card narrower than the flow was written with, and `mobile` checked it against the file. `mirror` now puts the card back, and `mirror mobile` then passed 69 of 69 |
| Every screen at phone width | Screenshots on the iPhone 17 simulator in light and dark, and again at a large text size, of a made-up run | looked at one by one |
| iPad on its side | A copy of the built app with its `Info.plist` changed to allow only landscape, in the simulator | the three columns, the banner, a zoomed card, the panels and a full-screen terminal were looked at in light and dark |
| Contrast | Worked out for every pair of tokens the app uses | see below |

Contrast: ink on every background is 8.7 to 1 or better, and every tinted badge is 5.8 to 1 or better. The lighter
ink is 5.0 on the white surface and 4.6 on a bar, but in light mode it is 4.1 on the paper and on the orange and red
tints, 4.2 on a bar under a finger and 4.3 on the green tint, where 4.5 is wanted. The app's own screens no longer
put it on the paper. The canvas still does, in a group's second line and in the second line of a zoomed-out card,
because it copies the Mac, whose tokens these are. The orange outline is 2.8
against white, under the 3 wanted for a line that carries meaning. Both are the Mac's to change first.

**What is left for the owner, on a real iPad or iPhone.** None of this can be done in a simulator.

1. Install it by the README's steps with a free Apple ID, and say whether each step reads right. Xcode's own menu
   names were written from memory of Xcode, not checked on screen.
2. Allow the local network when asked, and pair by scanning the code with the camera. Then turn Local Network off
   in Settings and see the message that asks for it back.
3. Open a flow and run it on the Mac while watching the device, on real Wi-Fi: how quickly the canvas and the
   terminals keep up, and what happens when the Mac sleeps or the device leaves the network and comes back.
4. Turn the device on its side and back, with a flow open, a sheet up and a terminal full screen. In the landscape
   copy the full-screen terminal's heading sat close under the status bar; see whether it does on a real iPad.
5. Listen to it with VoiceOver: the flow list, a card, a link, the banner and the panel's tabs.
6. Pinch, pan and tap with fingers. Every tap in the checks above was made by a launch argument.
7. Split View and Slide Over on an iPad, where the app gets the iPhone's layout.
8. Leave it installed for 7 days and see that Run in Xcode brings it back still paired.
