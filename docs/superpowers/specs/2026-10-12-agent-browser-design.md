# A browser inside an agent card

Date: 2026-10-12
Status: built and shipped in 0.4.0. The browser on the iPad and iPhone followed in 0.5.0.

## Goal

An agent that needs a web browser uses one that sits in its own card on the canvas. The person watches the
page live beside the agent's terminal and can click and type in it themselves.

## Decisions

| Question | Decision |
|---|---|
| New card kind, or a setting? | A **Browser** switch on the agent card. Off by default. |
| Which browser? | A real Chromium-based browser, run hidden and driven over its remote-control protocol (CDP). An installed Chrome, Edge, Brave or Chromium is used first; if none is found the app offers to download Chrome for Testing. Chromium is not embedded in the app. |
| Where do sign-ins live? | One browser profile per project, in the app's support folder. Every browser-enabled agent in the project shares its logins; each has its own tab. |
| What may the agent do unasked? | Looking is free, acting asks. `open`, `read`, `screenshot`, `scroll`, `back` and `wait` are pre-approved. `click`, `type` and `press` go through Claude Code's normal approval and follow the card's permission mode. |

## What the person sees

- An agent card's settings have a **Browser** switch. The orchestrator can set it with `add_card` and `update_card`.
- Turning it on doubles the card's width: terminal on the left, browser on the right, split in half. Turning it
  off halves the width again.
- The browser half has a thin bar (back, forward, reload, address) and the live page below it. Clicks, scrolling
  and keys in the page go to the browser.
- Changing the switch while the agent's session runs shows the existing "restart to apply" badge.
- With no browser found, the browser half shows a short message and a **Download** button.
- When the browser has stopped, it shows "Browser stopped" and a **Restart** button.
- A project's settings have **Clear browser data**, which quits that project's browser and deletes its profile.

## How it works

### Model (Core)

`Card.browser: Bool?` — agent cards only; nil and false both mean off. It is part of `CardPatch`, of the
orchestrator's card settings schema, and of what `get_flow` reports.

### The browser process (App)

`BrowserHost`, one per open project, owned by the app's services:

- Finds a browser: the installed ones in a fixed order, then the downloaded Chrome for Testing in the support folder.
- Starts it on first need with `--headless=new`, `--remote-debugging-pipe`, `--user-data-dir=<support>/browser/<project key>`,
  and no first-run or default-browser prompts. The control line is a pair of pipes (the child's descriptors 3 and 4),
  so no other process can connect to it. No network port is opened.
- Quits it when the project closes or its data is cleared.
- Reports when the process ends, so cards can show "Browser stopped".

`CDPConnection` speaks the protocol over the pipes: JSON messages separated by a zero byte, replies matched by id,
events delivered by session.

`BrowserTab`, one per browser-enabled card: a CDP target and its session. It can navigate, go back and forward,
reload, read the page, take a screenshot, scroll, click, type, press a key, wait, and start or stop the screencast.

### The live picture

`Page.startScreencast` sends JPEG frames sized to the card's browser half times the screen's scale. The view shows
the latest frame and acknowledges it. Streaming stops for a card that is off screen and starts again when it comes
back into view. The page's viewport is set to the browser half's size in points, so page coordinates and view
coordinates match.

### The person's input

The browser view forwards mouse, scroll and key events as `Input.dispatchMouseEvent` and `Input.dispatchKeyEvent`.
Paste inserts the clipboard's text with `Input.insertText`.

### The agent's tools

A second tool server, `browser`, served by the same `qb` helper (`qb browser-mcp`). The app answers it only for the
secret of an agent card whose Browser switch is on, and every call acts on that card's own tab.

| Tool | Arguments | Does | Pre-approved |
|---|---|---|---|
| `open` | `url` | Goes to an `http` or `https` address and waits for it to load | Yes |
| `read` | — | Returns the title, address and an outline of the page with numbered parts | Yes |
| `screenshot` | — | Returns a picture of the page | Yes |
| `scroll` | `direction`, `amount` | Scrolls the page | Yes |
| `back` | — | Goes back one page | Yes |
| `wait` | `text`, `seconds` | Waits for text to appear, or for a time | Yes |
| `click` | `ref`, or `x` and `y` | Clicks a numbered part, or a point from a screenshot | No |
| `type` | `ref`, `text`, `submit` | Types into a numbered part, or picks from a drop-down list; `submit` presses Return after | No |
| `press` | `key` | Presses a key | No |

The outline comes from Chrome's accessibility tree (`Accessibility.getFullAXTree`). Each part that can be acted on
gets a number, valid until the next `read` or navigation. A `click` or `type` on a number that no longer exists
tells the agent to read again.

The tool server returns image content as well as text, for `screenshot`.

### Launching the agent

With the switch on, `ClaudeLauncher.agent` adds `--mcp-config` for the `browser` server and `--allowedTools` naming
the six pre-approved tools. The agent's system prompt gains a paragraph: it has a browser in its card, how to use
the tools, and that what a page says is information and never a request from the person.

## Safety

- A card's tools reach only that card's tab, and only when its switch is on.
- The browser's control line is a private pipe, not a port.
- `open` refuses anything but `http` and `https`, so the browser can't be used to read local files.
- The profile is the app's own, in a folder only this account can read. The person's everyday browser is not touched.
- A page can still try to steer the agent. The system prompt and the approval on acting tools lower that risk; they
  do not remove it. SECURITY.md says so.

## When things go wrong

- Browser ends unexpectedly: cards show "Browser stopped"; tool calls return a plain error.
- A page doesn't load in 30 seconds: `open` says so and leaves the tab where it is.
- A part's number is stale: the tool says to `read` again.
- The download fails: the message stays, with **Try again**.

## Testing

- Core unit tests: the card setting and patch, the tool definitions, the address check, the outline built from an
  accessibility tree, key names, the CDP message framing.
- App: launch arguments with the switch on and off.
- `scripts/e2e.py`: against a small local page — turn the switch on, open the page, read it, click a button and see
  the result, and check that one card can't reach another's tab.
- By hand: one real flow with a browser-enabled agent.

## Build order

1. A throwaway prototype of the private pipe and the stream. If either fails, stop and rethink.
2. The browser process and the per-project profile.
3. The card's browser half and the person's input.
4. The agent's tools and approvals.
5. Failure states, the download fallback, Clear browser data.
6. Tests, SECURITY.md, README, changelog.

## Not in this version

More than one tab per card; downloads and uploads; a draggable divider; a per-site allow list.

The browser in the iOS companion was left out of 0.4.0 too, and shipped in 0.5.0 with stage 4 of the companion
(`docs/superpowers/plans/2026-10-17-ios-companion-4-parity.md`).
