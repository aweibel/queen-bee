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
./scripts/e2e.py         # about seven minutes; starts real Claude Code sessions on Haiku, which uses your account
```

### The iPad and iPhone app

```sh
./scripts/build-mobile.sh             # builds Mobile/ for the iOS Simulator, with no Apple account
./scripts/e2e.py terminals panels     # the app alone in the Simulator, fed a made-up flow and run
./scripts/e2e.py controls typing      # the same, with a made-up Mac that answers: every button, the message box and the keys
./scripts/e2e.py editing settings-edit   # the same, for Edit: each gesture, each setting, and making, renaming and deleting flows
./scripts/e2e.py mobile               # the app paired with the test copy of the Mac app; starts real sessions
```

These seven scenarios only run when named. `terminals`, `panels`, `controls`, `typing`, `editing` and
`settings-edit` need no Mac app session and no Claude Code, so they are the ones to run after any change under
`Mobile/`. After a change to what a device may ask of the Mac, under `App/Remote/`, or to how `FlowController`
takes a device's edit, run `./scripts/e2e.py remote` too: it needs no Simulator, and it is where the rules a
device's edits are held to are checked against a real Mac app, down to the file it saves. A test copy of the Mac
app moves what it "deletes to the Trash" into its own support folder, so the tests leave your Trash alone. `QB_E2E_SIMULATOR="iPhone 17"` picks the simulator;
run them on an iPad and on an iPhone, because the two lay the app out differently. Keep one simulator booted at a
time: each is heavy, and the scripts use whichever is already running. The app's launch arguments for tests are
listed at the top of `Mobile/Link/DebugLaunch.swift`, and with `-qbCannedRun 3` the app shows a made-up run with
no Mac at all, which is the quick way to look at a screen.

To put the app on a real device, follow [the README](README.md#install-it-on-your-own-device). Your team id and
bundle id go in `Mobile/Local.xcconfig`, which git ignores. Never commit that file, and never put a team id in
`project.yml` or `Mobile/Config.xcconfig`.

The unit tests run on every pull request, and so does a build of the iPad and iPhone app for the Simulator. The end-to-end script does not, because it needs a signed-in
Claude Code. Run it, or the scenarios near your change (`./scripts/e2e.py guard loop`), when you touch sessions,
hand-offs, the canvas or the engine, and say in the pull request which ones you ran.

## Where things live

The README's [How it works](README.md#how-it-works) section maps the five parts: `Core/`, `App/`, `Helper/`,
`Mobile/` and `Plugin/qb-link/`. A few habits the code already follows:

- Anything that can be decided without a window goes in `Core/` and gets a test there.
- Every colour, type size, spacing step and timing comes from `App/Design/Tokens.swift`. `Mobile/Design/Tokens.swift`
  mirrors it, so change a value in both.
- Words people read are plain, with no jargon. Claude Code's own option names (effort, permission modes, model)
  stay exactly as Claude Code writes them.
- Anything that lets a flow file or the orchestrator do something on the person's Mac without asking needs a
  line in [SECURITY.md](SECURITY.md).
- A change people would notice gets a line under Unreleased in [CHANGELOG.md](CHANGELOG.md).

## Sending a change

Fork, branch from `main`, keep the pull request to one thing, and describe what you changed and how you checked it.

The repository is public, so run `./scripts/check-clean.sh` before you commit and before you push. It fails if a
signing file, `Mobile/Local.xcconfig`, a team id, a key or a home folder path is tracked.

## Known issues and where help is wanted

Bugs:

- **Retry hangs after an API failure.** A hand-off to an agent whose last turn failed is queued and never typed
  (`App/Sessions/TerminalSession.swift`, `flushSoon`).
- **A Loop set above 3 tries stops early.** Links default to 3 passes, so the run ends at the link's limit before
  the Loop card gives up (`Core/Sources/QueenBeeCore/Engine.swift`, `send`).
- **A reply from a stopped run can leak into the next run.** Replies carry no run identity.
- **Stop Its Agents also stops the flow's schedule** until the flow is opened again.
- **Schedules stay on through some orchestrator edits:** changes inside a sub-flow, a Prompt card added after
  Start, or Start linked to a different agent.
- **Two project folders holding the same flow id cross-wire**, as a copied project does.
- **Deleting a sub-flow leaves its Flow card pointing at nothing**, with no warning.
- **Sessions sometimes stay at "starting"** when many start together. The end-to-end `fanout` scenario times out
  on this now and then and passes when run again by itself.
- **Nothing notices a stalled run.** A scheduled run waiting on an Approval card waits for good.

Security hardening:

- The app's socket trusts a per-session secret. Checking which process is on the other end would make the
  orchestrator's tools unreachable to an agent that can run shell commands.
- Text typed into a terminal isn't stripped of escape sequences.

Speed. None of this has been measured yet, so the first job is a stress flow and some Instruments recordings:

- Dragging a card rewrites the whole flow on every pointer move, which redraws most of the window.
- Terminals that are off screen, or hidden under the zoomed-out view, keep painting.
- Every link is redrawn whenever anything changes.
- Opening a flow starts every agent's session, and none is stopped until you quit.
- Flow files and run history are read and written on the main thread.

Other:

- Releases are signed but not notarized.
- The Mac app's build isn't checked in CI, only the `Core` tests and the iPad and iPhone app's build.
- The iPad and iPhone app has not been checked with VoiceOver by ear, on an iPad held sideways, or on an iPhone
  held sideways. The Simulator can't be turned from a script.
