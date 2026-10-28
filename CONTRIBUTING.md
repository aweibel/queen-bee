# Contributing to Queen Bee

Queen Bee is an experiment that works well enough to use and has plenty left to fix. Bug reports, fixes and
ideas are all welcome. For anything larger than a fix, open an issue first so we can agree on the shape before
you spend time on it.

## What you need

- A Mac with Apple silicon, on macOS 26 or later.
- Xcode 27 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- [Claude Code](https://claude.com/claude-code) 2.1.287 or later, signed in.

## Build and run

```sh
./scripts/build.sh
open build/Build/Products/Debug/QueenBee.app
```

A build from source is its own app, Queen Bee Dev. It keeps its settings and support folder apart from an
installed copy's, so the two can be open together. The Xcode project is generated from `project.yml`, so change
that file and not the project.

## Tests

```sh
cd Core && swift test    # under a second; run it before every pull request
./scripts/e2e.py         # about nine minutes; starts real Claude Code sessions on Haiku, which uses your account
./scripts/e2e.py features   # For each, Gave up, time limits on holds, the spending limit (one short Sonnet turn) and qb run
```

### The iPad and iPhone app

```sh
./scripts/build-mobile.sh             # builds Mobile/ for the iOS Simulator, with no Apple account
./scripts/e2e.py terminals panels     # the app alone in the Simulator, fed a made-up flow and run
./scripts/e2e.py controls typing      # the same, with a made-up Mac that answers: every button, the message box and the keys
./scripts/e2e.py editing settings-edit   # the same, for Edit: each gesture, each setting, and making, renaming and deleting flows
./scripts/e2e.py parity browser-canned   # the same, for stage 4's controls and a card's browser in each of its states
./scripts/e2e.py mobile               # the app paired with the test copy of the Mac app; starts real sessions
./scripts/e2e.py browser-remote       # a card's browser from the stand-in device, against a small site on this Mac; no Simulator
./scripts/e2e.py browser-mobile       # a card's browser on the device, against the test copy and the same site
```

These scenarios only run when named. `terminals`, `panels`, `controls`, `typing`, `editing`, `settings-edit`,
`parity` and `browser-canned` need no Mac app session and no Claude Code, so they are the ones to run after any
change under `Mobile/`. `browser-remote` and `browser-mobile` start a Chromium-based browser for the test copy, which
is heavy: run them after a change to how the Mac sends a card's page or takes a device's input in it, one at a time. After a change to what a device may ask of the Mac, under `App/Remote/`, or to how `FlowController`
takes a device's edit, run `./scripts/e2e.py remote` too: it needs no Simulator, and it is where the rules a
device's edits are held to are checked against a real Mac app, down to the file it saves. A test copy of the Mac
app moves what it "deletes to the Trash" into its own support folder, so the tests leave your Trash alone. `QB_E2E_SIMULATOR="iPhone 17"` picks the simulator;
run them on an iPad and on an iPhone, because the two lay the app out differently. Keep one simulator booted at a
time: each is heavy, and the scripts use whichever is already running. The app's launch arguments for tests are
listed at the top of `Mobile/Link/DebugLaunch.swift`, and with `-qbCannedRun 3` the app shows a made-up run with
no Mac at all, which is the quick way to look at a screen. `mirror` checks the copy of a terminal a device is sent.

The end-to-end script starts a separate test copy of the app with its own support folder, so a copy you have open is
left alone. A scenario that can't run on this Mac, such as one whose app isn't built, is counted as skipped. The run
fails when a scenario you named was skipped, or when nothing passed. `QB_E2E_SHOTS=<folder>` says where screenshots go.

### Launch flags

- `--open <folder>` opens that project folder in the first window. Give it more than once to open several.
- `--float` keeps the window above others without taking focus. Terminals stop painting in a hidden window, so a
  check that looks at the window needs it.
- `--welcome` shows the first-run walk-through in a test copy, which otherwise skips it.
- `--testing` turns on the test harness and lets a second copy of the app run. `QB_SUPPORT_DIR` in the environment
  moves that copy's socket and plugin.

`--testing`, `--welcome` and `QB_SUPPORT_DIR` only work in a debug build.

To put the app on a real device, follow [docs/mobile.md](docs/mobile.md#install-it-on-your-own-device). Your team id and
bundle id go in `Mobile/Local.xcconfig`, which git ignores. Never commit that file, and never put a team id in
`project.yml` or `Mobile/Config.xcconfig`.

A new card, card setting or agent tool is described in `Core/Sources/QueenBeeCore/Capabilities.swift`, which the orchestrator's instructions and `CAPABILITIES.md` are made from. `./scripts/build.sh` rewrites `CAPABILITIES.md`; commit it with your change. The unit tests fail if it is out of date.

The unit tests run on every pull request, and so do a Debug and a Release build of the Mac app, a check that the
Release build has no test harness in it, and a build of the iPad and iPhone app for the Simulator. The end-to-end
script does not, because it needs a signed-in
Claude Code. Run it, or the scenarios near your change (`./scripts/e2e.py guard loop`), when you touch sessions,
hand-offs, the canvas or the engine, and say in the pull request which ones you ran.

## Where things live

- `Core/` is a Swift package with no UI: the flow model, the file store, the routing engine, the orchestrator's tools
  and the socket messages. `cd Core && swift test` runs its tests.
- `App/` is the SwiftUI and AppKit app. The canvas is an `NSScrollView` with magnification, and each terminal is a
  SwiftTerm view inside a card.
- `App/Browser/` runs a hidden Chromium for agent cards that have a browser, one per project, and controls it over a
  private pipe with the Chrome DevTools Protocol. The page is streamed into the card as pictures, and the agent's
  tools are served by `qb browser-mcp`.
- `Core/Sources/QueenBeeCore/Capabilities.swift` is the one place that says what each card and each agent can do. The
  app writes it into each project as `.queenbee/CAPABILITIES.md` for the orchestrator to read, its tools take their
  settings from it, and the build writes it out as [CAPABILITIES.md](CAPABILITIES.md).
- `Helper/` builds `qb`, a small binary inside the app bundle. Claude Code hooks, the plugin and the orchestrator's
  tool server all run it, and it talks to the app over a unix socket in `~/Library/Application Support/QueenBee/`.
- `Mobile/` is the iPad and iPhone app. It links the same `Core/` package, draws the canvas with UIKit and the panels
  with SwiftUI, and feeds each terminal the output the Mac sends.
- `Core/Sources/QueenBeeDesign/` is the design system both apps share: the colours as light and dark pairs, the type,
  spacing, corner and motion scales, and the parts screens are built from. Each app's `Theme` names its roles.
- `Plugin/qb-link/` is the plugin the app loads into every session. When an agent's turn ends it asks the app where
  the reply goes and sends it there as a Claude Code session message.

A few habits the code already follows:

- Anything that can be decided without a window goes in `Core/` and gets a test there.
- Every colour, type size, spacing step and timing comes from the shared design system in `Core/Sources/QueenBeeDesign`,
  which both apps use, along with its parts (buttons, status pills, rows, tabs). Screens arrange those and set no
  colour or size of their own. `swift test` checks that every text colour is readable on every surface, in light and dark.
- Words people read are plain, with no jargon. Claude Code's own option names (effort, permission modes, model)
  stay exactly as Claude Code writes them.
- Anything that lets a flow file or the orchestrator do something on the person's Mac without asking needs a
  line in [SECURITY.md](SECURITY.md).
- A change people would notice gets a line under Unreleased in [CHANGELOG.md](CHANGELOG.md).

## Sending a change

Fork, branch from `main`, keep the pull request to one thing, and describe what you changed and how you checked it.

The repository is public, so run `./scripts/check-clean.sh` before you commit and before you push. It fails if a
signing file, `Mobile/Local.xcconfig`, a team id, a key or a home folder path is tracked.

## Releasing

For maintainers. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, put the same version in
`Plugin/qb-link/.claude-plugin/plugin.json` and in `MCPServer.version` in `Core/Sources/QueenBeeCore/MCP.swift`, add a
section for the version to `CHANGELOG.md`, commit, then:

```sh
./scripts/release.sh check      # the checks alone: the version matches everywhere, the build number is above appcast.xml's, the tree is clean
./scripts/release.sh            # build, sign, notarize and write the feed, into dist/
./scripts/release.sh publish    # the same, then release it on GitHub, tag it and push appcast.xml
```

`swift test` fails too when the three versions disagree. Publish puts the disk image on GitHub before it pushes
`appcast.xml`, so installed copies are never pointed at a download that isn't there, and running it again after a
failure carries on from the step that failed. Releases from a `release/<version>` branch reach installed copies once
that branch is merged into `main`, where they read the feed. The script's header lists the certificate, notarization
profile and update key it needs.

## Known issues and where help is wanted

Bugs:

- **Retry hangs after an API failure.** A hand-off to an agent whose last turn failed is queued and never typed
  (`App/Sessions/TerminalSession.swift`, `flushSoon`).
- **A Loop set above 3 tries stops early.** Links default to 3 passes, so the run ends at the link's limit before
  the Loop card gives up (`Core/Sources/QueenBeeCore/Engine.swift`, `send`).
- **A reply from a stopped run can still leak into the next run** when the app never saw the hand-off that
  began the turn. Stop interrupts the run's agents, and a turn begun by a hand-off of another run is dropped,
  but the run is read off the prompt the `UserPromptSubmit` hook reports, and a turn without one is passed on
  (`App/FlowController.swift`, `turnRun`; `Core/Sources/QueenBeeCore/Engine.swift`, `agentReplied`).
- **Stop Its Agents also stops the flow's schedule** until the flow is opened again.
- **Schedules stay on through some orchestrator edits:** changes inside a sub-flow, a Prompt card added after
  Start, or Start linked to a different agent.
- **Two project folders holding the same flow id cross-wire**, as a copied project does. The app keeps one
  list of open flows by id, and a session's secret names only the flow id and card id
  (`App/AppServices.swift`, `register` and `credential`).
- **Deleting a sub-flow leaves its Flow card pointing at nothing**, with no warning.
- **Sessions sometimes stay at "starting"** when many start together. The end-to-end `fanout` scenario times out
  on this now and then and passes when run again by itself.
- **Nothing notices a stalled run.** A scheduled run waiting on an Approval card with no time limit waits for good.

Security hardening:

- The app's socket trusts a per-session secret. Checking which process is on the other end would make the
  orchestrator's tools unreachable to an agent that can run shell commands.

Speed. None of this has been measured yet, so the first job is a stress flow and some Instruments recordings:

- Dragging a card rewrites the whole flow on every pointer move, which redraws most of the window.
- Terminals that are off screen, or hidden under the zoomed-out view, keep painting.
- Every link is redrawn whenever anything changes.
- Opening a flow starts every agent's session, and none is stopped until you quit.
- Flow files and run history are read and written on the main thread.

Other:

- Releases are signed but not notarized. `./scripts/release.sh` notarizes once a notarization profile is set up;
  the releases so far were made with `QB_SKIP_NOTARIZE=1`.
- The iPad and iPhone app has not been checked with VoiceOver by ear, on an iPad held sideways, or on an iPhone
  held sideways. The Simulator can't be turned from a script.
