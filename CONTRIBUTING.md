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

The unit tests run on every pull request. The end-to-end script does not, because it needs a signed-in
Claude Code. Run it, or the scenarios near your change (`./scripts/e2e.py guard loop`), when you touch sessions,
hand-offs, the canvas or the engine, and say in the pull request which ones you ran.

## Where things live

The README's [How it works](README.md#how-it-works) section maps the four parts: `Core/`, `App/`, `Helper/` and
`Plugin/qb-link/`. A few habits the code already follows:

- Anything that can be decided without a window goes in `Core/` and gets a test there.
- Every colour, type size, spacing step and timing comes from `App/Design/Tokens.swift`.
- Words people read are plain, with no jargon. Claude Code's own option names (effort, permission modes, model)
  stay exactly as Claude Code writes them.
- Anything that lets a flow file or the orchestrator do something on the person's Mac without asking needs a
  line in [SECURITY.md](SECURITY.md).
- A change people would notice gets a line under Unreleased in [CHANGELOG.md](CHANGELOG.md).

## Sending a change

Fork, branch from `main`, keep the pull request to one thing, and describe what you changed and how you checked it.

## Known issues and where help is wanted

Bugs:

- **Retry hangs after an API failure.** A hand-off to an agent whose last turn failed is queued and never typed
  (`App/Sessions/TerminalSession.swift`, `flushSoon`).
- **A Loop set above 3 tries stops early.** Links default to 3 passes, so the run ends at the link's limit before
  the Loop card gives up (`Core/Sources/QueenBeeCore/Engine.swift`, `send`).
- **A reply from a stopped run can leak into the next run**, once the same agent has been handed a message
  there. Replies carry no run identity. The engine only checks that the agent is owed a reply
  (`Core/Sources/QueenBeeCore/Engine.swift`, `agentReplied`).
- **Stop Its Agents also stops the flow's schedule** until the flow is opened again.
- **Schedules stay on through some orchestrator edits:** changes inside a sub-flow, a Prompt card added after
  Start, or Start linked to a different agent.
- **Two project folders holding the same flow id cross-wire**, as a copied project does. The app keeps one
  list of open flows by id, and a session's secret names only the flow id and card id
  (`App/AppServices.swift`, `register` and `credential`).
- **Deleting a sub-flow leaves its Flow card pointing at nothing**, with no warning.
- **Sessions sometimes stay at "starting"** when many start together. The end-to-end `fanout` scenario times out
  on this now and then and passes when run again by itself.
- **Nothing notices a stalled run.** A scheduled run waiting on an Approval card waits for good.

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

- Releases are signed but not notarized.
- The app build isn't checked in CI, only the `Core` tests.
