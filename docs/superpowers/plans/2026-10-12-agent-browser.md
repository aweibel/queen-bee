# Agent browser: implementation plan

**Status: done, shipped in 0.4.0.**

Spec: `docs/superpowers/specs/2026-10-12-agent-browser-design.md`

## What the prototype showed (step 1, done)

Chrome 155, driven from a script over `--remote-debugging-pipe`:

- The private pipe works; no listening port is opened.
- Three tabs streaming an animation each ran at 60 frames a second.
- A tab made with `Target.createTarget` only streams if it has its own window (`newWindow: true`).
- Frames come at screen sharpness only with `--force-device-scale-factor=2`.
- `Accessibility.getFullAXTree` and `Page.captureScreenshot` work headless.

## Files

Core (`Core/Sources/QueenBeeCore`), all unit tested:

| File | Holds |
|---|---|
| `Model.swift`, `Mutations.swift`, `Tools.swift` | `Card.browser`, `CardPatch.browser`, the orchestrator's `browser` setting; turning it on doubles the card's width |
| `BrowserTools.swift` | The nine tool definitions, `BrowserToolHost`, the call dispatcher, the address check |
| `PageOutline.swift` | An accessibility tree turned into a numbered outline |
| `BrowserKeys.swift` | Key names to the codes Chrome wants |
| `CDP.swift` | Message framing for the pipe |
| `MCP.swift`, `HelperCommand.swift` | A second tool server (`qb browser-mcp`), image results |

App:

| File | Holds |
|---|---|
| `App/Browser/BrowserFinder.swift` | Finding an installed browser; downloading Chrome for Testing |
| `App/Browser/CDPConnection.swift` | Starting the process with the pipe; commands, replies, events |
| `App/Browser/BrowserHost.swift` | One per project: the process, its profile, its tabs |
| `App/Browser/BrowserTab.swift` | One per card: the tools, the stream, the person's input |
| `App/Browser/BrowserPaneView.swift` | The browser half of a card |
| `AgentCardView.swift`, `CanvasView.swift` | The split card; streaming only while in view |
| `ClaudeLauncher.swift`, `TerminalSession.swift`, `FlowController.swift`, `AppServices.swift` | Launch arguments, restart-to-apply, the tool server's door |
| `InspectorView.swift`, `FlowSettingsView.swift` | The Browser switch; Clear browser data |
| `TestHarness.swift`, `scripts/e2e.py` | A `browser` scenario |

## Tasks

1. Core: the card setting, patch, orchestrator setting, with tests.
2. Core: tools, outline, keys, framing, the second tool server, with tests.
3. App: process, connection, host, tab.
4. App: the pane view and the split card.
5. App: launch arguments, the tool server's door, the switch, restart-to-apply.
6. App: stopped and missing states, download, Clear browser data.
7. `scripts/e2e.py browser`, then one real agent by hand.
8. SECURITY.md, README, CHANGELOG.
