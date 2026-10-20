# iOS Companion, Stage 2: Respond — Implementation Plan

**Status: done, shipped in 0.5.0.** The boxes below were the working list and were left unticked. The Result section at the end says what was built and how it was checked.

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

## Result

**What was built.** A device the owner has switched to "Can control" in the Mac's Settings can run a flow and stop
it, start a run at a card, approve a held message as it is or edited, reject it with a note, let a Script card's
command run or choose not to, start a flow's agents or one agent, send a message to the orchestrator or any agent,
and press keys in a session's terminal. The buttons are on the cards, in the list of what needs you and in a
card's details. Typing is a message box and a keys mode under the full-screen terminal, and a message box in the
orchestrator's page. A device that may only watch sees none of it, and one line saying how to turn it on. The Mac
checks the switch for every command, answers each one done or refused in its own words, and writes what a device
did in the flow's log with the device's name. Where this differs from the design is listed at the top of the spec.

**What Task 4 changed.** A review of the stage found these, and each is fixed:

- Starting or stopping a run held up everything else the device sent until it was done, because the Mac read one
  message at a time. Those three commands are now done apart from the reading, in the order they came for each
  flow, with "Can control" asked again when each one's turn comes. A device now gives up waiting for an answer
  after 30 seconds and says "Your Mac didn't answer. Check the run on your Mac.", without saying the command failed.
- Only runs, stops and messages were logged. Approving, rejecting, allowing a command, not running it, starting
  agents and typing now each add a line. Typing adds one line for each session at most every 30 seconds, and
  never what was typed. A rejection's note is not in the line.
- A device could give Run a command of its own, which skipped the check that there is anything to run. The Mac
  refuses that now. The device's app never sent one.
- Text from a device is entered into a terminal as one paste. An Esc in it could have ended the paste and turned
  the rest into key presses. The Mac now takes Esc and every other control character but new line and tab out of
  a device's text before using it. Keys are left as they are.
- "Stop the run?" and the other questions now belong to the flow that was open when they were asked, and go away
  if another flow is opened.
- Ctrl pressed in one terminal is let go when that terminal is closed or another opened, and a letter taken with
  Ctrl on a real keyboard is not typed a second time if iOS hands it on as text.
- On an iPhone, a question asked while the details sheet was up could not be shown. It now comes up over the
  sheet. The questions' own sheets were the whole screen with the question adrift in the middle, and are now as
  tall as what they ask. A refusal was hidden under the details sheet, and is now said in it too.

**How it was checked.**

| What | How | Result |
|---|---|---|
| Core, including the commands, their limits, cleaning a device's text, and the bytes for each key | `cd Core && swift test` | 254 tests pass, and the link's own 23 |
| Both apps build | `./scripts/build.sh`, `./scripts/build-mobile.sh`, each also with `Release` | all four succeed |
| No test hooks in a release | `nm` and `strings` on every binary in both Release apps for the test types and launch arguments, with the Debug builds as the control | none in Release; 156 and 757 symbols in the two Debug builds |
| What a device may ask, on the Mac's side | `./scripts/e2e.py remote`, with a stand-in for the device and no simulator: everything refused with control off and nothing changed on the Mac; each command done with it on; the log's lines; a run that is slow to start not holding up what follows; limits; control turned off mid-connection | 93 checks pass |
| Every control and both ways of typing, with a made-up Mac | `./scripts/e2e.py terminals panels controls typing` on an iPad Pro 11-inch and on an iPhone 17 simulator | 133 of 133 on the iPad. On the iPhone 129 of 133 at first: the four, all in `typing`, measured an iPad's layout, which is where the panel is and how much of the foot of the screen an iPhone keeps. The checks now say which is which, and `typing` then passed 45 of 45 on the iPhone |
| Against the Mac's test copy, with real sessions on Haiku | `./scripts/e2e.py guard settings remote mirror mobile` on the iPad simulator. `mobile` runs one flow wholly from the device: starts it, allows the script, rejects with a note, approves the next, stops another, sends the orchestrator a message and reads its reply | 201 of 202. The one was in `mirror`: a second terminal opened after the oldest output had been dropped showed its top rows blank. `mirror` alone then passed 10 of 10, and `remote mirror` 103 of 103, so it comes and goes and its cause is not known. Nothing in this stage touches that code |
| Every control at phone width | Screenshots on the iPhone 17 simulator, light and dark, of a made-up run: the line for a device that can only watch, the run bar idle and running, buttons on a card, in the list and in the details, each question from the canvas and over the details sheet, the rejection's note with the keyboard up, a refusal, "Start its agents", the terminal with an empty box, a five-line draft, the keys, a session that isn't running, a device that can't control, and the orchestrator's box in the sheet | looked at one by one |
| A held card of the usual height | The made-up Script and Approval cards are now 120 points tall, as new cards are, and were looked at zoomed in on the iPad | the line that says what it waits for, the buttons and the ports each have their own row |

**What has not been tested.** A simulator driven from the command line can't press anything, so:

- A real keyboard attached to an iPad: plain typing, the arrows and Esc, and Ctrl held with a letter. The code that
  stops Ctrl-C being typed twice has never met a real key press.
- Real touches. Every press in the checks was made by a launch argument, which calls what the button calls. That
  each button is under the finger where it is drawn, on a card zoomed in and out, is worked out and not felt.
- The keyboard on screen in the message box: writing, the box growing, Send. The box with text in it was checked,
  and the keyboard with the keys row and with the rejection's note was looked at, but nothing was typed on it.
- Putting a question away by dragging its sheet down, or tapping outside it.
- A run whose start is slow because of an If card's judging, from a real device. The check uses a Switch card.

**What is left for the owner, on a real iPad or iPhone.** The app on the device must be built again from Xcode after this update to the Mac app: the two only talk when
they are on the same version.

1. On the Mac, in Settings under Remote, turn on "Can control" for the iPad. See the sidebar say it can control.
2. Run a flow from the iPad, and stop one. Read the flow's log on the Mac for the iPad's name.
3. Answer an approval from the card, from the list at the top, and from the details. Reject one and write a note
   on the keyboard. Allow a script's command after reading it.
4. Open the orchestrator's terminal, write it a message and send it. Do the same from the orchestrator's page.
5. When an agent asks permission in its terminal, tap "Open its terminal" and answer with the keys. Press Esc to
   interrupt one that is working. With a keyboard attached, type, use the arrows, and press Ctrl-C.
6. Turn "Can control" off on the Mac while the iPad is connected, and see the buttons go at once.
7. Do 2 to 4 on an iPhone, with the details sheet up and with it down.
