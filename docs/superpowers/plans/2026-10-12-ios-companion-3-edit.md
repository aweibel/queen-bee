# iOS Companion, Stage 3: Edit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a paired iPad or iPhone that has been allowed to control the Mac, build and change a flow by touch: add, move, resize, link and delete cards, group them, change their settings, make, rename and delete flows, with undo shared with the Mac.

**Architecture:** As stage 2: the device sends small edit commands, the Mac checks the device may control it, makes the edit through the same gate every Mac edit goes through (so validation, undo and saving are unchanged), and the result comes back as the flow update the device already receives. The device moves things under the finger at once and lets the Mac's copy win.

**Tech Stack:** As stages 1 and 2.

**Spec:** `docs/superpowers/specs/2026-10-11-ios-companion-design.md` ("Device to Mac", "Drags", "Undo", "Canvas gestures").

---

## Rules for every commit

- Public repository: run `./scripts/check-clean.sh` and read the staged diff before every commit. Nothing private. Commit locally, never push.
- The Mac app keeps working: `./scripts/build.sh` succeeds; the scenarios named in each task pass.
- Plain wording for non-technical people in everything a person reads.
- **The machine is weak.** One simulator booted at a time, ever (iPad first; iPhone only in the last task, alone). Wait for the 1-minute load average to drop under 25 before booting, building or testing. One heavy command at a time. Drive simulators only with `xcrun simctl`. Never launch, quit or relaunch the owner's real (non `--testing`) apps. Quit test copies and shut simulators down at the end of every task.

## Safety rules of this stage

1. **Still off until turned on, still checked on the Mac for every command.** Editing is part of "Can control". Nothing here works for a watch-only device.
2. **An edit from a device is not an edit by the person at the Mac.** The app already has rules for edits it did not see the person make: the ones it applies to the orchestrator's tools (`Core/Sources/QueenBeeCore/Tools.swift`, `Mutations.swift`, and how `FlowController` handles them). A device's edits follow those same rules:
   - A Script card's command written or changed from a device is not "typed on this Mac": the run stops and asks before running it, as for one the orchestrator wrote.
   - A change from a device to a Start card's command, or to an agent's instructions, folder or permissions, turns the flow's schedules off until they are turned on again on the Mac, as an orchestrator's change does. A schedule cannot be turned on from a device.
   - A permission mode that skips permission checks cannot be set, as nowhere else.
3. **An agent's folder cannot be changed from a device.** On the Mac it is picked with the system's folder panel; a typed path from a device could point an agent anywhere. It is shown, with a line saying it is changed on the Mac.
4. **Deleting is undoable where the Mac's is, and confirmed on the device where more than one thing goes.** Deleting cards and links can be undone, from the device or on the Mac. The device asks first when a delete takes several cards or links, or a card that has links; one link, or one card with no links, is deleted without asking, because Undo brings it back and a question for every one would be friction with nothing behind it. Deleting a flow cannot be undone, so the device always asks, with the flow's name. The flow's file goes to the Trash on the Mac. A flow with a run going or starting, and the flow the Mac's own window is showing, cannot be deleted from a device.
5. **No reach beyond the flow.** No command adds or removes a project, opens a folder, changes roles, app settings or Remote settings. Flows are made only in projects already in the Mac's sidebar. An End card's save path stays inside the project, by the Mac's existing check.
6. **Sizes.** Text fields are capped (name 200 characters, instructions and other long text 16,000) on the Mac. A flow cannot be grown without limit from a device: at most 200 cards and 400 links per flow by device edits.
7. **The Mac shows it.** Each kind of edit from a device adds one log line naming the device, at most one line per kind per 30 seconds for moves and resizes.

## What is added to the link

`Remote.version` becomes 3. New `RemoteCommand` cases, each naming its flow (project for a new flow):

- Graph: `addCard(flowID, kind, x, y)`, `moveCards(flowID, moves: [id: point], final: Bool)`, `resizeCard(flowID, cardID, frame, final: Bool)`, `deleteItems(flowID, cardIDs, linkIDs)`, `addLink(flowID, from, port, to)`, `setLinkLimit(flowID, linkID, maxPasses)`, `duplicate(flowID, cardIDs)`, `tidy(flowID)`.
- Groups: `group(flowID, cardIDs, name)`, `ungroup(flowID, groupID)`, `renameGroup(flowID, groupID, name)`, `foldGroup(flowID, groupID, folded)`.
- Settings: `patchCard(flowID, cardID, RemoteCardPatch)` — a Codable patch of the fields a device may change (never the folder, never the schedule being on), `setFlowOption(flowID, …)` for the flow's own settings the Mac's flow settings sheet offers.
- Flows: `newFlow(projectID, name)`, `renameFlow(flowID, name)`, `deleteFlow(flowID)`.
- Undo: `undo(flowID)`, `redo(flowID)`.

`moveCards` and `resizeCard` with `final: false` are the steps of a drag: the Mac applies them inside one undo step (its existing begin/end gesture) and needs no answer shown; the `final: true` one ends the gesture. A drag left open when a device disconnects is closed by the Mac.

The snapshot gains what editing needs to show: whether undo and redo are available and their titles; the roles' names if a role can be picked; which schedules are on and their next time (already missing from stage 1's panels).

---

### Task 1: The Mac makes a trusted device's edits

- [ ] Core: the messages above, `RemoteCardPatch`, the caps, test-first. `Remote.version` 3.
- [ ] Mac: each command mapped to the existing edit entry point in `FlowController` / `ProjectModel` (the canvas, the inspector and the orchestrator's tools already call them; find them there). Every one through the same "Can control" check as stage 2, then the stage's safety rules. Refusals are the Mac's own sentences (nesting limits, a link that cannot be made, a name already used).
- [ ] Drag steps: begin the Mac's gesture on the first step, end it on the final one or when the device goes; one undo step per drag. Moves are clamped as the Mac clamps them.
- [ ] The orchestrator-style consent for device edits (rule 2): find how the app marks a Script command as written by the orchestrator and how it turns schedules off after an orchestrator's change, and route device edits the same way. Tests prove a device-written Script command is held for Allow and a schedule goes off.
- [ ] The snapshot additions (undo state, schedules, roles), kept small, with the mirror and its tests updated.
- [ ] Log lines per rule 7.
- [ ] `Tools/RemoteCheck` can send the new commands; e2e `remote` (no simulator, flows without agents): with control off every edit is refused and the flow file is byte-for-byte unchanged; with it on: add a card, move it in steps then finish (one undo undoes the whole drag), resize, link two cards, set a link's limit, delete, undo and redo, group and fold, tidy, patch a Prompt card's template and a Script card's command (then a run stops for Allow), try to set an agent's folder (refused), try to turn a schedule on (refused), make a flow, rename it, delete it (and a running flow's deletion is refused); the caps hold; the Mac's saved flow file matches what the device asked for.
- [ ] Verify: `cd Core && swift test`; `./scripts/build.sh`; Release build with no test hooks; `./scripts/build-mobile.sh` still succeeds; `./scripts/e2e.py guard settings remote`.
- [ ] Commit.

### Task 2: Editing the canvas by touch

Read the Mac's gestures first: `App/Canvas/CanvasView.swift`, `CardView.swift`, `LinkLayerView.swift`, `GroupFrameView.swift`, `App/Views/CanvasOverlays.swift` (the add-card palette), and Core's `Snapping.swift`.

- [ ] An explicit way in: an Edit button in the canvas bar turns editing on for this device (when it can control and is on the latest run). With editing off the canvas behaves exactly as now, so a stray finger never moves a card while watching.
- [ ] With editing on:
  - Drag a card by its title bar to move it, with the Mac's snapping and guides; a selected set moves together. The card follows the finger at once; steps go to the Mac at most 20 a second; the Mac's copy wins on release.
  - Drag the corner grip to resize, within the Mac's minimum sizes.
  - Drag from a port dot to another card to link them, with the Mac's rules for what accepts a link and its outline on the card under the finger; dragging to the canvas edge pans.
  - Long-press a card, link or group for its menu (duplicate, delete, group, ungroup, fold, rename, run from here); long-press empty canvas to add a card there, from the Mac's list of kinds; an add button in the bar opens the same list.
  - A Select button, then drag, draws a box round several cards.
  - Undo and Redo buttons with the Mac's titles; Tidy.
  - One-finger pan on empty canvas, pinch and double-tap still work.
- [ ] Touch targets of at least 44 pt for grips, ports and title bars at any zoom; when a card is too small on screen to grab reliably, dragging it moves it as a whole and the grip and ports are offered only above a zoom where they can be hit.
- [ ] A refusal puts things back and shows the Mac's words. A dropped link ends the drag and puts things back.
- [ ] VoiceOver: custom actions on cards for move by steps, delete, duplicate and link to another card by name.
- [ ] Tests: DEBUG launch arguments that perform each gesture through the same functions the recognisers call (begin, steps, end); canned scenario for each; `mobile` extended: on a no-agent flow, driven from the device, add a card, move it, link it, undo twice, redo once, delete, and check the Mac's flow file each time.
- [ ] Verify on iPad; screenshots looked at, light and dark.
- [ ] Commit.

### Task 3: Changing settings, and flows

Read `App/Views/InspectorView.swift` and `FlowSettingsView.swift` first.

- [ ] The Details page becomes editable when editing is on: the same fields as the Mac's inspector with the same names and choices (name; instructions; model; effort; permissions; role if roles are sent; check and its value; branches; loop limit; template; command; save-to; note text; a link's limit). The folder is shown with "Change the folder on your Mac." The schedule is shown, can be edited, and says it must be turned on on the Mac.
- [ ] Edits are sent when a field is left or after a pause in typing, never on every key; the field keeps what was typed if the Mac refuses, with the Mac's words beside it; a change arriving from the Mac while a field is being edited does not overwrite it.
- [ ] A Script card's command edited here shows that the run will ask before running it.
- [ ] Flows: new flow in a project from the flow list, rename, delete with a confirmation naming the flow; the flow's own settings as the Mac's sheet offers them.
- [ ] Tests: canned scenarios for each field kind, the refusal path and the concurrent-change path; `mobile` extended: rename a card, change a Prompt card's template and a link's limit from the device and check the Mac; make, rename and delete a flow.
- [ ] Verify on iPad; screenshots looked at, light and dark.
- [ ] Commit.

### Task 4: Finish

- [ ] iPhone pass, alone: every editing gesture and field at phone width.
- [ ] A read-only review against this stage's safety rules, then fixes.
- [ ] `SECURITY.md`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, the spec's "Where it stands", and a "## Result" at the end of this plan.
- [ ] Full check: `cd Core && swift test`; both apps' Debug and Release builds; no test hooks in Release; the canned scenarios; `./scripts/e2e.py guard settings remote mirror mobile` once on the iPad; `./scripts/check-clean.sh`; the diff scanned for anything private.
- [ ] Commit.

## Left for the owner on a real device

Build a small flow from scratch on the iPad and run it: add cards, link them, write an agent's instructions, group two cards, undo and redo, then run it and answer its approval.

## Result

Built as planned, in four tasks, with the differences from the design listed in the spec's "Where it stands".

**What was built.** With "Can control" on for a device, Edit on the canvas's bar, or at the foot of a card's
details, turns editing on. Cards are moved, resized, linked, added, copied, grouped and deleted by touch; every
setting the Mac's panel has is changed in the details; flows are made, renamed and deleted from the list; Undo
and Redo are the Mac's own. Every edit is a small command that the Mac checks, makes through the gate its own
edits go through, and sends back as the flow.

**What the review in Task 4 found, and what was done.** A read-only review against the safety rules found one
way round them and several places they were thinner than they read. All were fixed, each with a check that
fails without the fix where one could be written.

| Found | Done | Checked by |
| --- | --- | --- |
| A device could write a Script card's command, run the flow and allow the command itself | The Mac remembers, with what else the person has agreed to, that a card's command as it is came from a device. No device's Allow is taken for it; the device shows the Mac's words where Allow was. Typing or allowing the command at the Mac clears it | `remote`: the device's Allow is refused, a file the command would make is not there, allowing on the Mac makes it; a command the person put there can still be allowed from a device. `controls`: no Allow on the card, in the list or in the details |
| A device's edits turned schedules off only where the orchestrator's do | Any change from a device to what a flow does turns its schedules off, and those of the flows that run it as a sub-flow, and of the flows that ran a flow it deletes. Moving, resizing, grouping and notes do not | Core: `changesWhatItDoes`. `remote`: a link added and deleted, a Prompt's template, an agent's instructions in a sub-flow, a sub-flow deleted |
| Undoing a device's drag put back a whole old copy of the flow, and a drag never timed out | A drag's Undo puts back where the cards it touched were, and their size, and nothing else. A drag the Mac hears no more of ends after two seconds, and a last step that is refused still ends it | `remote`: a card changed on the Mac during a drag keeps its change when the drag is undone; both ways a drag ends |
| Agents a device added to an open flow started at once | They wait to be started: Start agent, Start its agents, or the Mac. Twelve agents a flow at most from a device | `remote`: an agent added to an open flow, and its copy, have no session until asked; the thirteenth is refused |
| Caps counted characters, and a flow had no size | Bytes as well: 800 for a name, 48,000 for other text. 2 MB for a flow added to from a device. Names are cut to 60 characters in the log | Core, with letters under piles of marks. `remote`: a one-character name of 1,001 bytes, and a flow filled to 2 MB |
| No limit on pace, and the log could be flooded | 60 commands in a burst and 20 a second, key presses apart. Each kind of edit is logged once, and half a minute later one line says how many more there were | Core: the bucket and the count. `remote`: 150 commands at once, and the log of a flow given 400 links |
| A flow deleted from a device was destroyed | It goes to the Trash. The flow the Mac's window shows, and one whose run is still starting, can't be deleted. A flow can't be given a name another has | `remote`, with the test copy's stand-in for the Trash |
| The device opened whichever flow turned up after it asked for one | Only one that turns up within five seconds, under the name asked for, or the only new one when the Mac named it | Core: `NewFlowAwaited` |
| Rule 4 said every delete is confirmed | Left as built, and the rule and the documents corrected: several things, or a card with links, are asked about; one link or one unlinked card is not, since Undo brings it back | `editing` |
| `SECURITY.md` said no device can change a flow, and that nothing is kept to send later | Rewritten | read through |

One thing was looked at and left. While a card is dragged, on the Mac or from a device, the Mac sends every
watching device the whole flow, at most once every 50 milliseconds: up to twenty times a second. Sending it less
often during a drag would also hold back the Mac's copy from the device that is dragging, which waits for it to
settle the card, so it was not changed.

**How it was checked.**

| What | How | Result |
| --- | --- | --- |
| Core, including the edit commands, their limits in characters and bytes, what changes what a flow does, the pace, the count for the log, and which new flow is opened | `cd Core && swift test` | 347 of 347 |
| Both apps build | `./scripts/build.sh` and `./scripts/build-mobile.sh`, Debug and Release | all four build |
| No test hooks in a release | `nm` and `strings` on every binary in both Release apps for the test types, launch arguments and the test copy's stand-in for the Trash, with the Debug builds as the control | none in Release; 84 and 5,344 in the two Debug builds |
| What a device may ask, on the Mac's side | `./scripts/e2e.py remote`, with a stand-in for the device and no simulator. Every edit is checked against the flow file the Mac saves, and each row of the table above has its checks here | 237 of 237 |
| Editing by touch, every setting, and flows, with a made-up Mac | `./scripts/e2e.py terminals panels controls typing editing settings-edit` on an iPad Pro 11-inch simulator | 248 of 248 |
| The same at phone width | `./scripts/e2e.py editing settings-edit controls typing` on an iPhone 17 simulator | 195 of 196 at first. The one, in `settings-edit`, wrote in a setting with the details not on show, which on an iPhone can't be done: the details are a sheet. The scenario now brings the sheet up there and says why. `settings-edit` again: 51 of 51 |
| Every editing screen at phone width | Screenshots on the iPhone 17 simulator, light and dark, of a made-up run: the editing bar over the run bar, a move with its guides, a resize, a link being dragged, the list of kinds, a card's, a link's and a group's menu, a box drawn round cards, the details of an agent, a Start card and its schedule, a Switch card's branches, a Script card, a link and several cards, a refusal beside a setting, the keyboard up over a setting, the list of flows with its + and a flow's menu, the question before a flow is deleted, and the flow's own settings | Two things were wrong and were fixed. The questions before a delete and for a group's new name came up under the details' sheet, where they could not be seen or answered; they now come up over it. And the sheet's own button said Done beside the Done that stops editing; it now says Close |
| Against the Mac's test copy, with real sessions on Haiku | `./scripts/e2e.py guard settings remote mirror mobile` once on the iPad simulator, then the scenarios that failed again | See below |

The last row, in full. The one run gave 356 of 367. `guard`, `settings` and `mirror` passed whole. One check failed
in `remote` and ten in `mobile`, and none was a fault in either app:

- `remote`, one check: that no flow file changes while a watch-only device sends every command. Run after
  `settings` it read the files less than half a second after a change of its own, with the Mac's save of that
  change still on its way, and so saw that save land. Watching the file and the flow in memory through those
  steps showed it. The scenario now waits for the save before it looks. `remote` by itself had passed, 237 of
  237, because without `settings` before it there was no older copy on disk to differ from.
- `mobile`, eight checks: `remote` edits the flow called Edits and leaves it changed, and `mobile` then expected
  it untouched. The two had not been run together since both began using it. `mobile` now writes a flow of its
  own into the project.
- `mobile`, one check: it expected the device to allow a command the device had written. That is what this
  task stopped. It now checks that the device has Don't run and no Allow, and allows the command on the Mac.
- `mobile`, one check: that a selected card is drawn selected, read a moment before the canvas had drawn it.
  It passed the next time and the time after.

`mobile` again, by itself: 112 of 113. The one expected a line in the log for each edit, which is what the log no
longer has; it now expects the first of each kind and then the count. `mobile` a third time: 113 of 113.
The one check in `remote` was run again with `guard` and `settings` before it, as far as that check, and passed;
`remote` was not run whole again after that one-line wait was added.

**What has not been tested.**

- Real touches. Every gesture in the checks was made by a launch argument that calls what the recogniser calls.
  That a title bar, a grip and a port dot are under the finger where they are drawn, at any zoom, is worked out
  and not felt.
- The keyboard on screen. It was looked at over a setting on the iPhone, put there by a launch argument, and
  nothing was typed on it.
- The real Trash. A test copy of the Mac app moves a deleted flow into a folder of its own instead, so the tests
  leave the Trash of whoever runs them alone. The one line that calls the system's Trash was not run.
- Quitting and reopening the Mac app between a device writing a command and trying to allow it. The check reads
  that the Mac kept it in its settings, where the rest of what is agreed to is kept, and does not relaunch.
- A device's edits arriving faster than 20 a second over real Wi-Fi, and two devices editing one flow at once.

**What these rules do not stop,** and `SECURITY.md` says so: a device with control can type into the
orchestrator or an agent and ask it to change a Script card's command, and then allow that command, because it
is the orchestrator's and not the device's. Typing into sessions was already as much as a device can be given.
And a card with a command a device wrote, copied on the Mac itself, is a new card: its command waits to be
allowed, and a device may allow it.

**What is left for the owner, on a real iPad or iPhone.** Build the app on the device again from Xcode first:
the two only talk when they are on the same version.

1. Build a small flow from scratch on the iPad and run it: press Edit, add cards, link them, write an agent's
   instructions, group two cards, undo and redo, then run it and answer its approval.
2. Feel the gestures: move a card by its title bar and watch the guides, resize by the corner, drag a link from a
   port dot, hold a finger on a card, a link, a group and empty canvas. Zoom far out and try again.
3. Add an agent card to a flow that is open on the Mac. It should sit there with Start agent on it and no
   session until you press that, there or on the Mac.
4. Change a Script card's command from the iPad and run the flow. The iPad should say "This command was changed
   from a device. Allow it on your Mac." and have no Allow. Allow it on the Mac. Quit and reopen Queen Bee on the
   Mac before allowing, once, and see that it still asks.
5. Turn a schedule on, on the Mac. From the iPad add a link, or change any setting. The Mac should say the
   schedule is off and which device changed the flow. Do the same to a flow that the scheduled flow runs.
6. Delete a flow from the iPad and find it in the Mac's Trash. Try to delete the flow the Mac is showing.
7. On an iPhone: open a card's details, press Edit at their foot, write in a setting with the keyboard up, and
   delete a card with links from the details, answering the question that comes up over the sheet.
8. Read the flow's log on the Mac afterwards for the device's name, and for the lines that count.

