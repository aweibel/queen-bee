# iOS Companion, Stage 4: Everything the Mac Can Do — Implementation Plan

**Status: done, shipped in 0.5.0.** The boxes below were the working list and were left unticked. The Result section at the end says what was built and how it was checked.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every interaction a person can make in the Mac app can be made from a paired iPad or iPhone that has "Can control", including the 0.4.0 browser in agent cards, apart from a short list the owner chose to keep on the Mac.

**Architecture:** As stages 2 and 3: new commands checked on the Mac for every call and mapped to the Mac's own entry points; new data in the snapshot or library where the device cannot draw something without it; one new stream (the browser page) with its own rate and size limits.

**Spec:** `docs/superpowers/specs/2026-10-11-ios-companion-design.md`. **Browser:** `docs/superpowers/specs/2026-10-12-agent-browser-design.md`.

**Gap inventory this plan works from:** taken on 2026-10-17 by reading the code; summarised in each task.

---

## The owner's decisions

- **Everything the Mac can do, the device can do**, except what stays on the Mac:
  - allowing a Script command that a device wrote (it must be allowed on the Mac),
  - changing an agent's working folder,
  - adding or removing project folders and answering "trust this folder",
  - Remote settings (pairing, removing devices, "Can control"),
  - the app's own settings (appearance, default model, notifications, where Claude Code is), Check for Updates, and things that only mean something on a Mac (Show in Finder, the Mac's first-run walk-through).
- **A schedule can now be turned on from a device.** This replaces stage 3's rule that it could not. A device edit to what a flow does still turns its schedules off; turning one on is a separate, deliberate act, noted in the log with the device's name. A Script command a device wrote is still held for Allow on the Mac when a scheduled run reaches it.

## Rules for every commit

As stages 2 and 3: public repository, `./scripts/check-clean.sh` and read the staged diff, commit locally and never push; the Mac app keeps working; plain wording; one simulator at a time, wait for load under 25, `xcrun simctl` only, never touch the owner's real apps, clean up after every task.

## Safety rules of this stage

Stage 2 and 3 rules all stay, except the one the owner lifted (turning a schedule on). In addition:

1. **Roles a device saves are roles.** Picking a role copies its settings into a card, as on the Mac; changing a role never changes a card that already uses it. A role saved or updated from a device cannot carry a permission mode that skips checks, and the log notes who changed it.
2. **The browser is typing.** A device driving a card's browser can do what the person can do in it on the Mac, signed-in sites included. It is part of "Can control", counted by the stage 3 rate limit, and noted in the log once per 30 seconds per card. Frames are sent only while the card is on the device's screen, at most 10 a second, each capped in size, and dropped rather than queued when the device falls behind.
3. **Pasting is editing.** Cards pasted from a device go through the same path as other device edits: a pasted Script command counts as written by a device, a pasted agent does not start by itself, and the stage 3 caps apply.
4. **Downloading a browser is the Mac's offer.** A device can accept the Mac's own "Download" offer for a Chromium browser; it cannot pick what is downloaded or from where.

---

### Task 1: The Mac side of everything except the browser page

New commands (Core `RemoteCommand`, `Remote.version` 4), each mapped to the Mac's own entry point:

- [ ] Runs: `run` gains an optional `startCardID` (Run from this Start, toolbar "Run from X"); `retry(flowID, cardID)` (the inspector's Retry); `clearLog(flowID)`; `dismissBanner(flowID)`; `stopAgents(flowID)` (sidebar "Stop Its Agents").
- [ ] Sessions: the orchestrator can be started, restarted and "Restart to apply"-ed from a device (`startSession` with the orchestrator's key, or a new command); `revertSettings(flowID, cardID)` (the "Not in use yet… Undo").
- [ ] Schedules: `armSchedule(flowID, cardID, on: Bool)` calling the Mac's own Turn on / Turn off. Remove "arrives switched off" for a trigger set together with arming; keep it for a plain patch.
- [ ] Cards: `RemoteCardPatch.browser`; `paste(flowID, fragment, at)` with a Core-validated, capped `FlowFragment`; `selectAll` stays device-side; `addCard` gains an optional `roleID`.
- [ ] Flows: `newSubflow(flowID, cardID, name)` (a Flow card's "New sub-flow"); `pin(flowID, on:)`.
- [ ] Roles: `saveRole(flowID, cardID, name)`, `updateRole(roleID, fromCardID)`, `deleteRole(roleID)`.
- [ ] Browser housekeeping: `clearBrowserData(projectID)`, `installBrowser`, `restartBrowser`.
- [ ] New data: per card `awaitingRestart` (the settings names the Mac lists) and the orchestrator's needs-restart; the run's retry point; role contents (instructions, model, effort, permission mode) so the device can show "Changed since the role was saved"; the library gains, per flow, its parent flow, pinned, card names (for Find), and the project's browser state (installed, has data, downloading with progress); sub-flow costs and the running run's cost if cheap.
- [ ] All through the stage 2/3 checks, caps, rate limit and log lines.
- [ ] e2e `remote`: every new command refused while watch-only and obeyed with control on, checked against the Mac's state and saved files; pasting a Script card leaves it needing Allow on the Mac; arming from a device then a device edit disarms; a role saved from a device with a skip-permissions mode is refused.
- [ ] Commit.

### Task 2: The iPad and iPhone UI for Task 1

- [ ] Canvas: Copy, Cut, Paste (a device clipboard of fragments, across flows), Select All, the minimap, turning snapping off, the empty-flow callout ("Build it by hand", "Start the orchestrator"), the failure banner with dismiss.
- [ ] Inspector: Retry, Run from this Start, the Browser switch, "Restart to apply" and Undo with the Mac's wording, role Save as / Update / Reset / Delete with the drift line, Turn on / Turn off for a schedule, New sub-flow.
- [ ] Panels: Clear log; orchestrator Start / Restart / Restart to apply; sub-flow costs.
- [ ] Sidebar: pinned flows, Stop Its Agents, sub-flows nested under their parent with a way back, Find across flows and cards.
- [ ] Tests: canned scenarios for each; `mobile` extended with one real check per command family.
- [ ] Commit.

### Task 3: The browser on the device

Read the browser design and `App/Browser/*`, `App/Canvas/AgentCardView.swift`, `BrowserPaneView.swift` first.

- [ ] Mac: a browser frame stream per card a device has on screen (start and stop by the device saying which cards are visible), forwarding the card's screencast frames re-encoded or passed through within the size and rate limits, with the tab's address, title, loading and back/forward state.
- [ ] Device: the card's browser half as on the Mac (terminal left, page right), the address bar, Back, Forward, Reload, and the Mac's notices (Download, Try again, Restart).
- [ ] Input: taps, scrolls and typing in the page mapped to page coordinates at the Mac card's size, sent as the Mac's own input calls; the keyboard for typing; Copy from the page's selection.
- [ ] Tests: unit tests for coordinate mapping and frame pacing; e2e with the existing small local test site (`scripts/e2e.py browser`) driven from the stand-in device and from the iPad simulator; the frame stream stops when the card leaves the screen.
- [ ] Commit.

### Task 4: Finish

- [ ] iPhone pass, alone.
- [ ] A read-only review against all stages' safety rules, with most attention on the browser stream, pasting and roles, then fixes.
- [ ] Docs: `SECURITY.md`, `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, the spec's "Where it stands", and a "## Result" here.
- [ ] Full check as stage 3's, plus `./scripts/e2e.py browser nobrowser` once.
- [ ] Commit.

## Result

Built in four tasks, each committed locally: the Mac side of every new command (Task 1), the iPad and iPhone UI for
them (Task 2), a card's browser on the device (Task 3), and the finish (Task 4): a review of the browser stream,
pasting and roles against every stage's safety rules, its fixes, the iPhone pass and the docs.

What the review found and Task 4 changed:

- **Copy could hold up a device's commands for 30 seconds.** It now runs on its own, asks the page in an isolated
  world of the Mac's own (a page that replaces `getSelection` isn't asked), gives up after three seconds, is cut to
  100,000 characters, and is sent only if the device still has control and the card on screen.
- **A page could flood a device with its address and title.** They are cut to 2,048 and 300 characters and told at
  most four times a second, always the newest; the tab's history is asked at most as often.
- **Saying which cards are on screen had no pace.** It is held to 8 at once and 4 a second; a card let go of keeps
  its pace for five seconds; a page goes on being drawn two seconds after the last viewer lets go.
- **A watch-only device saw signed-in pages.** Pictures, addresses and titles now go only to a device with
  "Can control", stop at once when it is turned off, and come back when it is turned on. A watch-only card says
  "Turn on “Can control” for this device to see the page."
- **A device could clear the record of what it did.** A device's Clear keeps every line marked as a device's or a
  schedule change, and says who cleared it. Closing the message at the top of a flow is noted with its first 80
  characters; turning a schedule on or off is a line each time.
- **Roles changed from a device were invisible on the Mac.** They are marked "Changed from <device>" with the time
  in the inspector's role menu and line and on the palette; the Mac asks once before using one; the earlier version
  can be put back; a role a device deleted can be restored for 30 days. Instructions from a device are capped.
- **The flow list was rebuilt on every card move and usage tick.** It is worked out at most once a second, costs are
  looked at every five seconds, roles carry the first 2,000 characters of their instructions and a SHA-256 of the
  whole for the drift line, and the browser and profile checks no longer go to the disk each time.
- Smaller: a browser command must be for the device's open flow; turning a schedule on waits behind the device's
  edits; a paste is all or nothing and every pasted card lands on the canvas.
- On the iPhone, the run bar's "Nothing to run yet" line had squeezed itself into a column beside the buttons, and
  the flow settings' browser section likewise: both now put the words above or beside as the width allows.

How it was checked: see the final report of Task 4 for the commands and their output (unit tests, Debug and Release
builds of both apps, the canned scenarios on the iPad and the iPhone, `remote`, `browser-remote`, `browser-mobile`,
`guard settings remote mirror mobile`, and the check for test hooks in Release).

Left for the owner on a real device:

- Pair a real iPad and iPhone, turn "Can control" on and off while a card's browser is on screen, and see the page
  go and come back.
- Sign in to a site in a card's browser from the device, and use Copy and Paste with the device's own clipboard.
- On the Mac, pick a role a device saved, and answer the "Use it?" question; try Put back the earlier version and
  Restore a role deleted from a device.
- Turn a schedule on from a device and let it fire with the Mac unattended; then edit the flow from the device and
  see it go off.
- A device's Clear on a busy flow's log, and that the Mac keeps what devices did.
