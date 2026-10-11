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
4. **Deleting is confirmed on the device and undoable where the Mac's is.** Deleting cards and links can be undone. Deleting a flow cannot (as on the Mac), so the device asks with the flow's name, and a flow with a run going cannot be deleted from a device.
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
