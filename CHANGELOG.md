# Changelog

All notable changes to Queen Bee are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- In "Where this flow works", This folder no longer switches your folder's branch: agents work on whatever branch it has checked out. Flows set before keep working until you apply the form again. A worktree can be made on a new branch, started from any local branch, or on an existing local branch. The branch lists are searchable, and two branches whose names differ only by a slash or a dash (feature/foo and feature-foo) no longer share a worktree folder.
- A new look, after Linear's apps, in Queen Bee's own colours, on the Mac and on the iPhone and iPad. On the Mac the sidebar sits on the window's colour and the flow in a rounded panel, with its header and Canvas and Settings tabs along the top; cards, panels, buttons and the ⌘K menu are redrawn to match. On the iPhone a floating bar at the foot of the first screen holds Needs you, Flows and a menu with your Mac, Settings and pinned flows. Light and dark both follow it. Agents and the orchestrator are still live Claude Code sessions.
- Both apps now share one design system, so a colour or a size is set in one place for both.

### Added

- Needs you, Runs, Schedules and Devices at the top of the Mac's sidebar: what waits on you, every flow's runs with each one's log, every schedule with Turn on and Turn off, and your paired devices.
- Runs are numbered (#12), and a run keeps its number after older runs are let go.

## [0.7.1] - 2026-10-26

### Fixed

- Turning on a schedule that came with the flow, in its file or from an undo, starts it at once. Before, the Start card kept saying "off" and nothing ran until Queen Bee was opened again.
- The question of where a flow works, and the title bar's branch chip, fit any project. Long branch names are cut short in the middle, the branch the folder is on is named in full below the menu, and branches open in other worktrees are counted rather than listed one by one. In a light window, the chip's popover no longer turns dark over a terminal behind it.

## [0.7.0] - 2026-10-26

### Added

- Each flow works on one branch, in the project folder or in a worktree of its own. The first time a flow opens in a git repository it asks where it should work, and its agents wait for the answer. After that the chip after the project's name in the title bar shows the branch, with "worktree" when it is one, and opens the setting to check or change it. A worktree is made from the branch you pick, main by default, in the project's `.queenbee/worktrees` folder, and used again from then on. Sub-flows work wherever the flow at the top does. Runs, schedules and `qb run` all go by the setting.

## [0.6.0] - 2026-10-21

### Added

- A spending limit for a flow's runs, in the flow's settings, on a paired device and for the orchestrator. A run whose agents have used more than it, at API prices, is stopped as Stop would stop it, and the log, the run's history and a notice say so. Their use is read every few seconds while the run goes on, so a long turn is stopped part-way through, before its reply is passed on.
- Loop until has a third output, Gave up, taken when its tries run out. A Loop with nothing linked to Gave up goes out Done as before.
- An Approval card can wait at most a set time, then approve or reject the message itself, and the log says so: "No answer after 8 hours, so it was rejected". A Script card can wait a set time for its command to be allowed, then skip it.
- A For each card: it splits a message into lines, or the items of a JSON list, sends each one in turn to the cards on Each, collects what comes back for each, and passes all of it on from Done. Every hand-off counts toward a run's limit of 50, and it sends 50 items at most. The canvas warns about one with nothing on Each or no way back.
- `qb run <folder> <flow> "message"` starts a flow from Terminal or a script, waits for it to end and prints its answer; `--no-wait` only starts it. A `queenbee://run?flow=…&message=…` link starts one too, once you say yes in the app.
- Run history says how each run ended: finished, ended without an answer, gave up after the most tries, stopped at the hand-off limit, failed or stopped. So does the notice when a run ends.
- Two more warnings on the canvas: an And whose inputs are on different sides of one If or Switch, which can never hear from all of them, and a Loop with nothing on Done.
- The orchestrator's reference now states the limits a run keeps: 50 hand-offs, a Script card's 10 minutes and last 20,000 characters, a condition's 60 seconds, and how Or and Flow cards behave.
- Flow › Next Agent Needing You (⌘J) goes from card to card waiting on you, across open flows. The Dock icon shows how many there are.
- A menu bar item: what is waiting on you, each open flow and whether it is running, and Stop for a run. Click a card to go to it.
- Edit › Command Palette (⌘K): add any kind of card, run or stop the flow, go to a card by name, and link the selected card to another by name.
- Each flow's canvas opens where you left it, at the same zoom, also after you reopen the app.
- An agent still starting after 20 seconds says so on its card, with Retry. It may be asking you something in its terminal, such as whether to trust the folder.

### Changed
- Stop ends a run at once, even while a condition is being judged, and interrupts the run's agents that are in the middle of a turn, so they stop spending on it.
- A Flow card that reaches a sub-flow that is already running waits for that run to end and then runs it, instead of failing.
- Queen Bee has one window. File › New Window is gone; the Dock icon, a notification or the menu bar item brings the window back after you close it.
- Quitting while a run is going or an agent is working or waiting on you asks first.
- Deleting a flow moves it to the Trash, with its run history kept, as a delete from a paired device does.
- ⌘Z in an agent's terminal or a card's browser no longer undoes changes to the canvas. An Undo, Redo or delete that would remove an agent in the middle of its work asks first.
- A card's new name in its settings is kept when you click or tab away, not only on Return. The Log tab stays put while you scroll up to read it.

### Fixed
- An agent the run isn't waiting on no longer stops the run when its session ends, is restarted or its card is deleted. When the run is waiting on it, the log names it and says why.
- An Or card inside a loop passes on the first reply of every round, not only the first round's.
- A condition that takes longer than 60 seconds to judge counts as No and says so, instead of holding up the run, and a long message is no longer too big to be judged.
- The hand-off that would pass a run's limit of 50 is no longer typed into an agent after the run has stopped.
- Retry and "run from here" give a card all of its message, not the first 8,000 characters.
- A reply an agent finishes for a run that has ended is not passed on in the next run.
- A flow's file is flushed to the disk before it replaces the old one, and the version before is kept, so a power cut can't leave an empty flow.
- A run's history is never overwritten by an older copy, and the last run's cost is recorded even when the flow is closed straight after it.
- An agent whose conversation Claude Code summarised mid-task no longer looks idle, so a hand-off isn't typed into it while it works.
- An agent whose folder was changed starts a new conversation in the new folder instead of failing to resume every time it starts.
- If your shell's startup files take more than 10 seconds to load, Queen Bee goes on without them and says so, instead of never starting its agents.
- Downloading the browser for agent cards no longer holds up the app, and a failed download no longer leaves its file open.
- The canvas no longer slows down with every switch of flow, and with many cards it redraws less. A card's browser stops streaming while the window is hidden or covered. While agents run, macOS no longer slows the app down in the background.

### Security
- A program running in an agent's terminal can no longer read your clipboard by asking the terminal for it (OSC 52). Pasting with ⌘V works as before.

## [0.5.0] - 2026-10-19

### Added

- Remote, in Settings: pair an iPad or iPhone with this Mac over local Wi-Fi, with no server and no account.
- A companion app for iPad and iPhone, built from source and installed on your own device. It shows every flow with its state, the open flow's canvas live, each agent's terminal with scroll-back, the run log, End cards' answers, earlier runs, cost, and which cards are waiting on you. The README has the steps to install it with a free Apple ID.
- "Can control", a switch for each paired device in Settings → Remote. It is off until you turn it on. With it on, the device can run and stop flows, approve and reject, allow a Script card's command, start and restart agents, and send messages and keys to the orchestrator and to any agent. The Mac checks the switch for every one of these, and writes what a device did in the flow's log with the device's name.
- Edit, in the companion app, for a device with "Can control" on. Press Edit to move, resize, link, add, copy, group and delete cards by touch, change a card's settings, a link's limit and a group's name in the details, and make, rename and delete flows. Undo and Redo are shared with the Mac. A flow deleted from a device goes to the Trash on the Mac.
- The rest of the Mac's controls, in the companion app, for a device with "Can control" on: Run from This Start, Retry, Stop Its Agents, the orchestrator's Start, Restart and Restart to apply, Undo beside "Not in use yet", turning a schedule on and off, Clear for the log, closing the message at the top of a flow, Copy, Cut, Paste and Select All for cards, across flows too, the map, the Browser switch, adding an agent from a role, saving, updating and deleting roles with the line that says a card has changed since its role was saved, New sub-flow, pins, sub-flows under the flow that runs them, Find across flows and cards, sub-flow costs, and Clear browser data, Restart and the Mac's Download offer for a project's browser.
- An agent card's browser on the iPad and iPhone: the page beside the card's terminal, as on the Mac, and full screen with the address bar, Back, Forward, Reload, the Mac's notices, and the page to tap, scroll, type into, copy from and paste into. Only a device with "Can control" is sent the page.
- `./scripts/e2e.py parity browser-canned browser-remote browser-mobile` check all of this, with a made-up Mac, the stand-in device and the iPad against a small local site.

### Changed

- In the companion app the panel's tabs are Orchestrator, Run and History, and it opens on Orchestrator. On an iPad a selected card's details slide over the panel, with a way back to the tab under them; on an iPhone they come up in a sheet from the bottom. A flow's settings are in the "…" menu beside Run.
- Every Claude Code session starts with Claude Code's classic renderer, whatever your own "tui" setting says, so a card's terminal keeps output to scroll back through on the Mac and on a device. It is passed to the session when it starts; nothing is written to your settings.

### Security

- A change made from a paired device is held to more than one made on the Mac. A Script card's command changed from a device stops the run and must be allowed on the Mac itself: no device can allow it, even in a scheduled run. Any change from a device to what a flow does turns off that flow's schedules, and those of flows that run it as a sub-flow, until they are turned on again on the Mac or with Turn on from a device, which is noted in the log each time. A device cannot change an agent's folder or set a permission mode that skips permission checks.
- A role saved or changed from a device is marked on the Mac with the device's name. The Mac asks before you first use it, keeps what it held before so it can be put back, and keeps a role deleted from a device for 30 days to be restored.
- Clear on a device keeps every line of the log that says what a device did or that a schedule went on or off. Closing the message at the top of a flow from a device is noted with what it said.
- A card's page goes only to a device with "Can control", and stops at once when it is turned off. A page can't flood a device: its address and title are cut short and sent at most four times a second, and what a device says it has on screen is held to a pace of its own. Copy asks the page in a world its scripts can't reach and gives up after three seconds.
- A `javascript:` address, or any other that isn't a web address, typed into the bar of an agent card's browser on the Mac is refused. One with no dot in it used to be sent to the search engine as words to search for.
- Agent cards added from a device do not start a session by themselves in a flow that is open on the Mac, and a flow can be given twelve agents at most from a device.
- What a device sends is capped in characters and in bytes, a flow added to from a device at 200 cards, 400 links and 2 MB, and a device at 60 commands in a burst and 20 a second after that.
- Each kind of edit from a device is written in the flow's log once, with the device's name, and half a minute later one more line says how many more there were.
- A flow deleted from a device keeps its runs and its log, so one put back from the Trash has them again. Its agents are stopped only once its file is in the Trash.
- A flow's own settings changed from a device turn its schedules off, as other changes from a device do.
- A message too big to send from a device is refused on the device, with a reason, instead of cutting the connection.
- A flow that two projects open on the Mac share by id can't be opened or changed from a device.
- A paired device stays paired when its key can't be read from the Keychain at launch, for instance when an access prompt is turned down; the Mac tries again.
- The Mac asks about a role changed from a device on the window in front, and asks again if a device changes it while the question is up.

### Fixed

- An agent whose program can't be started no longer stays at "Starting" for ever. It ends, and can be started again.

## [0.4.0] - 2026-10-13

### Added

- An agent card can have a web browser in it. Turn on **Browser** in the card's settings and the card doubles in width: the terminal on the left, a live page on the right. The agent gets tools to open an address, read the page, take a screenshot, scroll, go back, wait, click, type and press a key. You can click, scroll and type in the page yourself, for instance to sign in. The orchestrator can turn the switch on when it builds a flow.
- The browser is a Chromium-based browser already on the Mac (Chrome, Chromium, Edge or Brave), run hidden. With none installed, the card offers to download Chrome for Testing, about 150 MB, for Queen Bee's own use.
- Every agent with a browser in a project shares one set of sign-ins, kept apart from your own browser. **Clear browser data** in a flow's settings forgets them.
- `./scripts/e2e.py browser nobrowser` checks the browser against a small site served on the Mac, with a real agent.

- A running orchestrator can be restarted from its panel, keeping its conversation. When the flow has been renamed since it started, the button reads **Restart to apply**.

### Fixed

- A link a message is travelling shows its orange dashes again. The line had gone missing while the agent it led to was working, leaving only the arrowhead and the count, and came back green when the run moved on.
- The orchestrator no longer writes steps for things the app can't do, such as opening a second browser tab. What every card, setting and agent can do is now declared in one place in the code. The app writes it into each project as `.queenbee/CAPABILITIES.md` whenever an orchestrator's session starts and tells the orchestrator to read it when it has changed, its tools take their settings from it, and the build writes the same text out as `CAPABILITIES.md` in the repository. A new card or setting that isn't described there doesn't build or fails the tests.

- New instructions reach a session that is resumed. Claude Code keeps the instructions a conversation began with, so an agent restarted with **Restart to apply**, and an orchestrator reopened after an update, went on following the old ones. The app now hands the current ones to the session when it starts.

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

[Unreleased]: https://github.com/bamboozledkitty/queen-bee/compare/v0.7.1...HEAD
[0.7.1]: https://github.com/bamboozledkitty/queen-bee/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.4...v0.4.0
[0.3.4]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/bamboozledkitty/queen-bee/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/bamboozledkitty/queen-bee/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/bamboozledkitty/queen-bee/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/bamboozledkitty/queen-bee/releases/tag/v0.1.0
