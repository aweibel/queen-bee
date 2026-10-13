# Changelog

All notable changes to Queen Bee are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- An agent card can have a web browser in it. Turn on **Browser** in the card's settings and the card doubles in width: the terminal on the left, a live page on the right. The agent gets tools to open an address, read the page, take a screenshot, scroll, go back, wait, click, type and press a key. You can click, scroll and type in the page yourself, for instance to sign in. The orchestrator can turn the switch on when it builds a flow.
- The browser is a Chromium-based browser already on the Mac (Chrome, Chromium, Edge or Brave), run hidden. With none installed, the card offers to download Chrome for Testing, about 150 MB, for Queen Bee's own use.
- Every agent with a browser in a project shares one set of sign-ins, kept apart from your own browser. **Clear browser data** in a flow's settings forgets them.
- `./scripts/e2e.py browser nobrowser` checks the browser against a small site served on the Mac, with a real agent.

### Fixed

- A link a message is travelling shows its orange dashes again. The line had gone missing while the agent it led to was working, leaving only the arrowhead and the count, and came back green when the run moved on.
- The orchestrator no longer writes steps for things the app can't do, such as opening a second browser tab. What every card, setting and agent can do is now declared in one place in the code. The orchestrator is given it each time its session starts, its tools take their settings from it, and the build writes it out as `CAPABILITIES.md`. A new card or setting that isn't described there doesn't build or fails the tests.

### Changed

- The README's screenshots are retaken at twice the size, on a fuller flow with a sub-flow, a script check and an approval, and there is a new one of a run waiting at an Approval card.
- `--open` can be given more than once, to open several project folders at launch.

## [0.3.4] - 2026-10-12

These come from an outside security review of 0.3.3.

### Security

- A run can no longer get past an Approval card that hasn't been answered. An agent further along that finished a turn of its own, or a late reply from a run that was stopped, used to be passed on as if the run had reached it. Now only a reply to a message the run handed that agent goes on, once for each message. Anything else is left where it is and the log says so.
- A flow file can't name a card into the orchestrator's place. A file with a card called `orchestrator`, or a slash in an id, is not loaded and is listed as a file the app can't read. Such a card's session used to be given the flow-editing tools.
- A message the app types into an agent's terminal has its escape sequences and control characters removed first. Text written by one agent could otherwise end the paste early and press keys in another agent's session.
- The terminal installer checks that the app is signed with the project's Developer ID certificate, up to Apple's root. It used to compare the team name the signature printed, which a signature made with another kind of certificate could also carry.

### Added

- `THIRD-PARTY-NOTICES.md` holds the licenses of SwiftTerm, Sparkle and swift-subprocess, and ships inside the app.

### Changed

- `SECURITY.md` says which orchestrator edits leave a schedule on, that the linked-agents rule lets a message through when the app can't be reached, and that two open copies of one project cross-wire.
- The plugin and the orchestrator's tool server report the app's version again. They had stayed at 0.3.2.

## [0.3.3] - 2026-10-11

### Added

- Rejecting at an Approval card can carry a note saying why. The note goes out by Rejected ahead of the message, so an agent it loops back to knows what to change.

### Fixed

- An agent that stops to ask the orchestrator or a linked agent a question no longer has its parting words passed on as its reply. The card stays owed until the turn after the answer, and shows "awaiting answer". If nothing else is under way the log says the run is waiting on it, and after 90 seconds you are told, and the orchestrator too unless it is busy.
- Agents are told to find files with `ls`, `find` and `grep` in the shell, which Claude Code runs without asking, and the orchestrator is told to name files in a card's instructions and not to forbid the shell.
- Zoom to fit shows a wide flow whole. It may go below 20%; pinch, the wheel and the zoom buttons still stop there.
- Two runs of `scripts/e2e.py` at once no longer delete each other's support folder.
- The log says when acting on your answer at an Approval or Script card took more than two seconds.

## [0.3.2] - 2026-10-10

### Security

- An End card can no longer save its answer inside `.git`, `.claude` or `.queenbee`. The orchestrator is refused when it sets such a path, and a flow file that arrives with one shows a warning and saves nothing.
- The orchestrator's secret is no longer on its session's command line, where any process could list it.

### Changed

- A build from source is its own app, Queen Bee Dev, with its own settings and support folder, so it runs beside an installed copy.
- `scripts/build.sh` fails when the build fails.

## [0.3.1] - 2026-10-10

### Fixed

- The 0.3.0 download contained the 0.2.0 app under a 0.3.0 label, so none of 0.3.0's features were in it and it could not read flows that use the new cards. This release is the real one. Everything listed under 0.3.0 arrives with it.
- The release script now stops when the build fails, and checks that the app it packages is the one it just built.

## [0.3.0] - 2026-10-10

### Added

- **Approval** cards, which hold a message until you approve, edit or reject it.
- **Script** cards, which run a shell command and route on whether it succeeded. A command you didn't type yourself waits for you to allow it.
- **Flow** cards, which run another of the project's flows as one step. Double-click one to open its flow, or to make a new sub-flow with an Input and an Output; the title bar shows the way back, and sub-flows are listed under the flow that uses them.
- A sub-flow's canvas opens with all of it in view, shows the map and the note pointing at the orchestrator, and its Input no longer warns that it has no command. Its orchestrator is told it is building a sub-flow.
- Sub-flows only nest as deep as the flow at the top allows: three levels unless you change it in that flow's settings. Edits, the orchestrator's tools and runs are all held to it, and a flow can't be made to run itself.
- Flow settings, from the sliders button in the toolbar: the flow's name, its sub-flow limit, and whether its orchestrator is told when a run ends.
- A schedule is tied to the command it was set with: if the orchestrator changes that command, or an agent's instructions, folder or permissions, the flow's schedules switch off until turned on again. A Start card whose schedule is off says so.
- Copying or duplicating grouped cards keeps the group.
- The orchestrator can make sub-flows below its own flow and build inside them, however far down the limit allows. It can't reach the flows above or beside it, and when the limit is reached it is told to say so.
- Dragging a card or a group no longer selects it, so its settings only open on a click.
- The hand closes as soon as you press on a card's title bar or a group's name, before you move.
- Mouse navigation: Command or Control with the scroll wheel zooms about the pointer, and holding Space or the middle button drags the canvas.
- With several Start cards, Run starts from the selected one, the Run button offers a choice, and each Start card has its own Run.
- A flow file that appears in a project while it is open is picked up without reopening it.
- Resting the pointer on a card type in the palette explains it in a sentence, with an example.
- A link's settings list the messages it carried in the run on show.
- Every run is kept, with its path, answers and messages. The Log tab can put an earlier run back on the canvas.
- **Run from here** starts a run at any card with a message you give it, and a card a run stopped at can be retried.
- Cost: each agent's card shows what it used in the run, a figure beside the zoom control shows the flow's total, and clicking it breaks the total down by agent, sub-flow and run.
- Agent roles: an agent's instructions, model, effort and permissions saved under a name and reused from the palette in any flow.
- A Start card can run on a schedule (every so often, daily, or on chosen days) or when a file or folder in the project changes.
- Groups: cards framed together under a name, which fold into one card.
- **Tidy Up** (⇧⌘L) lays a flow out left to right in the order its links run.
- **Find** (⌘F) goes to a card or flow by name, and a map in the corner shows the whole flow and where the window is looking.
- Dragging to the edge of the canvas pans it, so a link, a card, a selection box, a resize or a new card from the palette can reach what is out of view.

### Changed

- Run and Stop are filled, named buttons, and a button that can't be pressed is drawn as a faint outline.
- A card only shows as live or waiting from run marks while a run is under way.
- Wording across the app is plainer: settings, tips, warnings and log lines say what happens without the technical terms. The app's own labels, such as an agent's state and Claude Code's option names, are unchanged.

## [0.2.0] - 2026-10-09

### Added

- A terminal installer, `scripts/install.sh`, that fetches the latest release, checks its signature and installs it without the Gatekeeper prompt.
- A first-run walk-through of agents, logic cards and the orchestrator, which also checks that Claude Code is installed and new enough. **Help → Welcome to Queen Bee** shows it again.
- Undo and redo for every change to a flow, including the orchestrator's, from the Edit menu.
- Selecting several cards with Shift-click or a dragged box. Selected cards move, nudge with the arrow keys, duplicate, copy, paste and delete together.
- Dragged cards line up with nearby cards, with a guide line, or settle on the grid. Option places a card freely.
- Right-click menus on cards, links and the canvas.
- Escape deselects, ⌃⌘S shows or hides the projects list, and ⌥⌘0 the side panel.
- The run log, End-card output and the last run's marks are kept between launches, with a Clear button on the log.
- Notifications when a card needs you or a run ends while the app is in the background, with a setting to turn them off.
- Below 40% zoom, cards show their name and state in large type.

### Fixed

- The app's own message, such as Claude Code not being found, can be dismissed with a click.

### Changed

- Zooming from the zoom control, the menu, fit and a double-click on a card's title is animated. Hover, selection and panel changes ease instead of snapping.
- A link being dragged previews the route it will take, and lands on the input of a card that would accept it.
- The card settings panel is rebuilt: the name is edited in its header, settings sit in ruled rows, and Delete and the session's Start or Restart share a footer.
- Clicking into a terminal no longer opens that card's settings. Click the card's title for those.
- An empty flow shows a small note pointing at the orchestrator in place of the box in the middle of the canvas. Closing it is remembered.
- Floating panels no longer cast a shadow.

## [0.1.1] - 2026-10-09

### Fixed

- **Queen Bee → Check for Updates…** was always greyed out. It now turns on once the updater is ready.

## [0.1.0] - 2026-10-09

First public release.

### Added

- A canvas of cards joined by links. Agent cards are live Claude Code sessions in terminals you can type into.
- Logic cards that route each agent's finished reply: Start, If / Else, Switch, And, Or, Prompt, Loop until, End and Note.
- An orchestrator session beside the canvas that can build, edit, run and steer the flow.
- Runs with a log, per-card pass counts, live link marking and saved End-card output.
- Project folders in a sidebar, with flows saved in `<project>/.queenbee/flows/`.
- Light and dark appearance, and an app icon that follows it.
- Updates: the app checks for new versions and installs them, and **Queen Bee → Check for Updates…** checks on demand.

### Security

- A folder that already contains flows is only opened after you confirm you trust it.
- Cards can only use the permission modes the app offers. A mode that skips permission checks is refused from flow files and from the orchestrator's tools.
- Each session gets its own secret for talking to the app, and only the orchestrator's session can use the flow-editing tools.
- An End card's save path can't leave the project folder through a symlink.
- The test harness is compiled out of release builds.
- Releases are signed with a Developer ID and use the hardened runtime. They are not yet notarized by Apple.

[Unreleased]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.4...HEAD
[0.3.4]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/bamboozledkitty/queen-bee/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bamboozledkitty/queen-bee/releases/tag/v0.1.0
