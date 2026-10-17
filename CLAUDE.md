# Queen Bee

## Capabilities are declared once

`Core/Sources/QueenBeeCore/Capabilities.swift` is the one place that says what the app can do: every kind of card, each card's settings and limits, and what an agent can do. The orchestrator's instructions, the settings its tools accept and `CAPABILITIES.md` are all made from it.

Whenever you add, remove or change a card, a card setting, an agent tool or a limit on any of them:

1. Change it in `Capabilities.swift` (browser tools: `BrowserTools.swift`, whose definitions and `limits` the reference is built from). Write for the orchestrator: what it does, and what it can't do.
2. Run `./scripts/build.sh`. It rewrites `CAPABILITIES.md`. Never edit that file by hand.
3. Run `cd Core && swift test`. It fails if a setting in `CardPatch` isn't described, if a described setting can't be set, or if `CAPABILITIES.md` is out of date.
4. Commit `CAPABILITIES.md` with the change.

The app also writes the reference into each project as `.queenbee/CAPABILITIES.md` when an orchestrator's session starts, and tells the orchestrator to read it when it has changed. A session that is resumed keeps the system prompt it began with, so anything a running session must learn goes through that file or the session-start hook (`FlowController.startContext`), never through the prompt alone.

Don't describe a capability anywhere else: not in the orchestrator's prompt in `ClaudeLauncher.swift`, and not in a tool's description.
