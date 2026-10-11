# iOS Companion, Stage 2: Respond — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a paired iPad or iPhone that has been allowed to control the Mac, start and stop runs, answer approvals, allow a script's command, start an agent, and type into any session, including chatting with the orchestrator.

**Architecture:** The device sends small commands over the link it already has. The Mac checks, for every command, that this device is allowed to control it, then makes the same `FlowController` call the Mac's own buttons make, and answers done or refused with the Mac's own reason. State still only flows one way: what a command changed comes back through the updates the device already receives.

**Tech Stack:** As stages 1A and 1B.

**Spec:** `docs/superpowers/specs/2026-10-11-ios-companion-design.md` ("Device to Mac", "Pairing and security", "Terminals", "When something needs you").

---

## Rules for every commit

- Public repository: run `./scripts/check-clean.sh` and read the staged diff before every commit. Nothing private. Commit locally, never push.
- The Mac app keeps working: `./scripts/build.sh` succeeds; the scenarios named in each task pass.
- Plain wording for non-technical people in everything a person reads.
- **The machine is weak.** One simulator booted at a time, ever (iPad first; iPhone only in the last task, alone). Wait for the 1-minute load average to drop under 25 before booting, building or testing. One heavy command at a time. Drive simulators only with `xcrun simctl`. Never launch the real (non `--testing`) Mac app. Quit test copies and shut simulators down at the end of every task.

## Safety rules of this stage

1. **Off until turned on.** A device is watch-only until "Can control" is turned on for it in the Mac's Settings. Pairing never turns it on. Turning it off takes effect at once, for a connected device too.
2. **Checked on the Mac, every time.** Each command is refused unless the device's "Can control" is on at that moment. The device hiding its buttons is a courtesy, never the check.
3. **Only what the Mac's own buttons do.** A command maps to an existing `FlowController` or `TerminalSession` call with the same validation. No command can add a project, answer the "trust this folder" prompt, change Remote settings, pair or remove a device, change a card's settings, or edit the flow (that is stage 3).
4. **Scripts keep their gate.** "Allow" from a device is the same act as clicking Allow on the Mac, and is remembered the same way. Nothing else about a Script card can be changed from a device.
5. **Small messages.** The Mac's 64 KB limit on what a device may send stays. Typed text and prompts are capped well below it.
6. **The Mac shows it.** While a controlling device is connected the sidebar row says so, and each run or prompt started from a device is logged in the flow's log with the device's name.

## What is added to the link

In `Core/Sources/QueenBeeCore/Remote.swift`, with `Remote.version` raised to 2 (an older app on either side is told to update):

- `DeviceMessage.command(id: Int, RemoteCommand)`
- `HostMessage.answer(id: Int, refusal: String?)` — nil means done.
- `HostMessage.control(Bool)` — sent when "Can control" changes for this device. `RemoteWelcome.canControl` already carries it at connect.
- `RemoteCommand`, each naming its flow:
  - `openOnMac(flowID)` — what selecting the flow on the Mac does to its sessions: starts the ones that are missing.
  - `run(flowID, command: String?)`, `runFrom(flowID, cardID, text: String)`, `stop(flowID)`
  - `approve(flowID, holdID, text: String)`, `reject(flowID, holdID, note: String)`
  - `allowScript(flowID, holdID)`, `refuseScript(flowID, holdID)`
  - `startSession(flowID, cardID)` — the card's "Start agent" / "Restart agent".
  - `prompt(flowID, key, text: String)` — a message typed for a session, sent the way the Mac sends one (queued until idle, as one paste, then Enter).
  - `keys(flowID, key, data: Data)` — raw key presses for a session's terminal.
- Caps as constants: prompt text 16,000 characters, keys 4,096 bytes a message.

`RemoteMirror` gains `canControl` (from welcome and `.control`) and a small record of commands waiting for an answer.

---

### Task 1: The Mac obeys a device it trusts

- [ ] Core: the messages above, test-first (encoding round-trips; caps; the mirror's `canControl` and pending commands). Raise `Remote.version` and update every test and the test client that names it.
- [ ] `RemoteDevices`: `setCanControl(_:for:)`, saved in the devices file. `RemoteHost`: tells a connected device with `.control`, and updates what the session holds.
- [ ] `RemoteSession`: handles `.command`. Looks the device's "Can control" up fresh each time. If off: answers with "This device can only watch. To let it control this Mac, turn on “Can control” for it in Settings on your Mac." Otherwise maps each command to the existing call (find them: the Mac's buttons and `App/Testing/TestHarness.swift` both call them) and answers nil or the Mac's own refusal text. A flow or card or hold that is not there is refused plainly. Caps are enforced on the Mac whatever the device sent.
- [ ] `keys`: written to the session's terminal the way typing on the Mac is. `prompt`: through `TerminalSession.send`. Both refused for a session that is not running.
- [ ] Logging: a run, run-from, stop or prompt from a device adds a line to that flow's log naming the device.
- [ ] Mac Settings (`App/Views/RemoteSettingsView.swift`): a "Can control" switch per device, with one sentence under the list saying what it allows. The sidebar's connected row says "can control" for a device that can.
- [ ] `Tools/RemoteCheck`: can send commands given on standard input and prints each answer.
- [ ] e2e `remote` (no simulator): with control off every kind of command is refused and nothing happens on the Mac; turned on, the device is told, and: `openOnMac` starts sessions; `run` starts a run and `stop` ends it; a held approval can be approved, and rejected with a note; a script's command can be allowed; `prompt` reaches an agent, which replies; `keys` reach a terminal; turned off mid-connection, the next command is refused; an over-long prompt is refused; a command for a flow the Mac does not have is refused. Use flows with as few agents as will prove each point.
- [ ] Verify: `cd Core && swift test`; `./scripts/build.sh`; `./scripts/build.sh Release` and no test hooks in it; `./scripts/e2e.py guard settings remote`.
- [ ] Commit.

### Task 2: Run, stop, approve and start agents from the device

Read the Mac's controls first: `App/Views/CanvasOverlays.swift` (the run bar), `App/Canvas/CardView.swift` and `LogicCardView.swift` (Approve, Reject, Allow on cards), `App/Canvas/AgentCardView.swift` (Start agent), `App/Views/InspectorView.swift` (run from here).

- [ ] `RemoteClient`: `send(_ command:) async -> String?` (nil is done, text is the refusal; a dropped link answers with a plain "not connected" sentence), `canControl` for the UI, and DEBUG launch arguments to send each command for tests.
- [ ] While the device cannot control: everything looks as in stage 1, with one quiet line where the controls would be saying how to turn control on. No dead buttons.
- [ ] When it can:
  - A run bar over the canvas matching the Mac's: Run (with the Mac's way of giving a command, if it has one), Stop while running. It is part of the canvas's clear area.
  - Opening a flow whose sessions have not been started offers "Start its agents" (`openOnMac`).
  - Approval cards and the needs-you banner offer Approve and Reject; Reject asks for an optional note; Approve can edit the message if the Mac allows that.
  - Script cards waiting to be allowed offer Allow and Don't allow, showing the command in full first.
  - Agent cards with no session offer Start agent / Restart agent.
  - Details for a card: "Run from here" with the last message that reached it, as the Mac does.
  - A refusal shows as a short message with the Mac's words; buttons are disabled while their command is waiting for an answer.
- [ ] Buttons on cards must work although card views ignore touches: route them through the canvas's tap handling with 44 pt hit areas, as the expand mark does.
- [ ] VoiceOver labels and actions for each new control.
- [ ] Tests: canned scenarios (no Mac) for both states of every control; `mobile` extended with one real Gates run driven wholly from the device: start it, allow the script, reject the approval with a note once and approve the next, stop a second run. Check the Mac's log names the device.
- [ ] Verify on iPad; screenshots looked at, light and dark.
- [ ] Commit.

### Task 3: Typing — chat with the orchestrator and any agent

- [ ] The full-screen terminal gains two ways to type, shown only when the device can control and the session is running:
  - **A message box** at the bottom: a multi-line field and Send. It sends `prompt`, which the Mac queues until the session is idle and enters as one message. This is the main way to talk to the orchestrator or an agent from a touch screen.
  - **Keys**: a button brings up the keyboard and a row of extra keys (Esc, Tab, Ctrl, arrows, Enter, and the keys Claude Code's prompts ask for, such as 1, 2, 3, y, n). Each press sends `keys` at once. This is for answering a permission prompt or interrupting.
- [ ] The keys must come from the app's own input view, not from SwiftTerm's: SwiftTerm's `send` also carries the terminal's automatic replies to the program's queries, and those must go on being dropped. Build the bytes for each key here (text as UTF-8, Enter as carriage return, Backspace as delete, arrows and Esc as their escape sequences, Ctrl with a letter as its control code), unit-tested in Core.
- [ ] The orchestrator's panel and each agent card's full-screen view both use it. The keyboard never appears on the canvas.
- [ ] The layout keeps the latest output in view above the keyboard; a hardware keyboard works with no on-screen keyboard; the message box keeps its text if the link drops.
- [ ] Tests: Core tests for key bytes; canned scenarios for the composer's states; `mobile` extended: a prompt typed on the device makes the orchestrator (or one agent) reply, seen in the device's terminal; a key press reaches the terminal; the dropped-replies counter still rises and nothing but commands is sent to the Mac.
- [ ] Verify on iPad; screenshots looked at, light and dark, with the keyboard up.
- [ ] Commit.

### Task 4: Finish

- [ ] iPhone pass, alone: every new control and the typing views at phone width.
- [ ] A read-only review of everything this stage changed, with most attention on the safety rules above (can any command act with control off, reach a call outside the list, or be used to change settings, files or the flow?), then fixes.
- [ ] `SECURITY.md`: what "Can control" allows and does not, that it is off until turned on, that it is checked on the Mac for every command, and that a device with control can type into sessions that run commands. `README.md`, `CHANGELOG.md`, the spec's "Where it stands", and a "## Result" at the end of this plan.
- [ ] Full check: `cd Core && swift test`; both apps' Debug and Release builds; no test hooks in Release; `./scripts/e2e.py terminals panels` and `./scripts/e2e.py guard settings remote mirror mobile` once on the iPad; `./scripts/check-clean.sh`; the diff scanned for anything private.
- [ ] Commit.

## Left for the owner on a real device

Turn on "Can control" for the iPad on the Mac, then: start a run, answer an approval, type a message to the orchestrator, press keys at a permission prompt, and turn "Can control" off while connected.
