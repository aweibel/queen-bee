# Queen Bee for iPad and iPhone: design

Date: 2026-10-11
Status: stage 1 of 3 is built. Stages 2 and 3 are not started.

## Where it stands

Stage 1, "Link and mirror", is built: the Mac side by the plan in
`docs/superpowers/plans/2026-10-11-ios-companion-1a-mac-link.md`, the app by
`docs/superpowers/plans/2026-10-11-ios-companion-1b-ios-app.md`. Each plan ends with what was built and how it was
checked. The rest of this document is the design as it was agreed. Where the build settled on something else, it
is listed here, and this list wins.

What stage 1 delivered:

- Pairing by a one-time code, scanned or pasted, and a connection that comes back by itself.
- The Mac's projects and flows with their states, and the open flow's canvas drawn as the Mac draws it, live.
- Each agent's terminal in its card and full screen with scroll-back, and the orchestrator's beside the canvas.
- The card and link details, the run log, End cards' answers, earlier runs, cost, and what is waiting on you.
- An iPad layout in three columns and an iPhone layout as a stack with the details in a sheet.

It is watch-only. The device sends the Mac nothing but which flow it has open.

What the build settled on. Some of it has already been written into the sections below, and some of them still
describe the first idea:

- **One listener and one key for each device.** Not one listener for all of them: the Mac opens a listener of
  its own for each paired device, encrypted with that device's key, and advertises it
  with the device's id. A device looks for its own. Pairing has a separate listener that exists only while a code
  is on screen.
- **Terminal history is kept by replaying recent output.** The Mac keeps about the last 512 KB each session
  printed and sends it when a device opens the flow, so the device's terminal has the same screen and can scroll
  back. When a card is made narrower on the Mac that kept output is emptied, and the device's history starts again
  from there. History from before any resize can differ from the Mac's by a few lines.
- **Looking at an earlier run happens on the device only.** The device does not ask the Mac to show one. The
  Mac sends the runs it has kept with the flow, and the device puts one on its own canvas and
  panels. The Mac is not told and does not change. When a new run starts, the device goes back to the latest.
- **Sub-flows are listed, not nested.** The device is told which flows are sub-flows but not which flow uses
  each, so they are listed together under their project and not tucked under a parent as on the Mac.
- **Some things the Mac shows are not sent yet**, so the device does not show them: saved roles; whether a Start
  card's schedule is on, and when it next runs; the "restart to apply" badge on an agent whose settings changed;
  what a sub-flow's sessions cost, in its parent's figures; and the cost of a run while it is going, which appears
  when the run ends.
- **The canvas and terminals do not follow the device's text size.** They are the Mac's picture, zoomed with two
  fingers. Everything else follows it.
- **The iPhone layout was run and fixed, but only upright.** Neither device has been looked at held sideways.

## Goal

A companion app for iPad and iPhone. Once paired with the Mac app it shows every project, flow and run as a
one-to-one copy of the Mac canvas, and lets you do from the device everything you can do at the Mac: run and stop
flows, answer approvals, type into sessions, and edit the canvas.

The Mac app stays the host. Sessions only ever run on the Mac.

## Constraints

- **No running costs.** No cloud service, no relay, no account. The two apps talk directly over local Wi-Fi.
- **No paid Apple membership.** The app is built from source and installed with a free Apple ID, which means
  re-installing every 7 days. TestFlight and the App Store are out of scope.
- **Open source, same repository.** Nothing private may be committed. See "Keeping the repository clean".
- **A working concept.** iPad first. iPhone runs the same app with a simpler stacked layout and is not tuned.

## Approach

The Mac owns all state. The device is a live remote: it draws what the Mac sends and sends back small commands.

Two alternatives were rejected:

- **Each device keeps its own copy and merges.** It would allow offline editing, but needs conflict handling and a
  second copy of storage and undo, and nothing can run offline anyway.
- **Mirroring the Mac window as video.** Quick, but it is not a real app, and macOS screen sharing already does it.

Consequences of the chosen approach:

- Both screens show the same flow state. Pan, zoom and selection are per device.
- Terminal size is set by the Mac card. Resizing a card on either device resizes the real terminal for both.
- Nothing works when the Mac is out of reach.

## The parts

### Shared message types, in `Core`

- `Core` adds iOS as a platform. It uses only Foundation and CoreGraphics.
- A new `Remote` source file defines every message the two apps exchange and the protocol version. Both apps compile
  against it.
- The terminal replay buffer and the mapping from a command to a flow edit live here too, so they can be unit-tested
  without either app.

### A host inside the Mac app, `App/Remote/`

- **Listener.** Advertises a Bonjour service on local Wi-Fi and accepts paired devices over an encrypted
  connection. Uses the same Network framework API as the helper socket in `AppServices`.
- **Publisher.** Watches each `FlowController` and sends changes to connected devices.
- **Command handler.** Turns a device command into the same `FlowController` call the Mac UI makes, so validation,
  undo and saving are unchanged.
- **Terminal tap.** Copies each session's output as it arrives, keeps a recent buffer per session, and forwards
  typed input from a device.
- **Settings pane.** "Allow remote devices" (off by default), "Pair a device", and the list of paired devices.

With "Allow remote devices" off, no listener exists and the Mac app behaves exactly as it does today.

### A new iOS app, `Mobile/`

A second target in `project.yml`, deployment target iOS 26.

- **Client.** Finds the Mac, pairs, connects, reconnects.
- **Mirror model.** Holds the flows and run state the Mac sent, using the `Flow` and `Card` types from `Core`.
- **Touch canvas.** New UIKit views for cards, links and groups, reusing the geometry, link routing and snapping
  code in `Core`.
- **Terminals.** SwiftTerm's iOS view, fed by the stream.
- **Panels.** Sidebar, inspector, run log, history and cost in SwiftUI.

The Mac canvas (about 2,300 lines of AppKit) is not touched. Sharing one canvas between the two apps would mean
rewriting a working Mac canvas first. The cost is two canvases to keep in step.

### What syncs

Projects and flows, card and session states, live run state (marks, log, results, link messages, pending
approvals), run history, costs, roles, and terminal output.

## How messages flow

One connection per device, open while the iOS app is in the foreground. Frames use the helper's existing framing: a
four-byte length, then JSON.

### On connect

1. Both sides send their protocol version. If they differ, the device shows "Update Queen Bee on your Mac" (or on
   this device) and loads nothing else.
2. The Mac sends a snapshot: projects, flow list, roles.
3. The device says which flow it has open. The Mac sends that flow, its run state and its history, and keeps it
   updated until the device opens another.

### Mac to device

| Update | How it is sent |
|---|---|
| Flow changed | The whole flow, with a revision number. At most about 20 a second during a drag |
| Card marks, pending approvals, costs | Whole, whenever they change |
| Log lines, link messages | As they are added |
| Session state | Per card, on change |
| Terminal output | Raw bytes per session, only for the flow the device has open |

Sending the whole flow avoids patch logic. Flows are small JSON files.

### Device to Mac

Every command gets an answer: done, or refused with the reason the Mac would show.

- **Stage 2:** run, run from card, stop, approve or reject with a note, allow a command, terminal input.
- **Stage 3:** add, change and delete cards, links and groups; tidy; create, rename and delete flows; undo; redo.

### Drags

The device moves the card under the finger at once and sends the move. The Mac's copy always wins. The device
ignores incoming positions only for the card being dragged, and accepts the Mac's version on release.

### Undo

One undo history, on the Mac. Undo on a device undoes the last edit, whichever device made it.

### Joining a terminal part-way through

A device that opens a flow needs each terminal's current screen, not only new output. The Mac keeps each
session's most recent output, about 512 KB, and sends it when a device opens the flow. Fed that, the device shows
the same screen as the Mac and can scroll back through earlier output. No repaint is forced on the session; testing
showed it isn't needed. When a card is made narrower the kept output is emptied, so the device's history starts
again from that point. History never reaches back further than the kept 512 KB or so.

## Pairing and security

A paired device with control can type into terminals that run commands on the Mac.

### Pairing

1. On the Mac, Settings → Remote → "Pair a device" shows a QR code holding a long random one-time secret. It lasts
   2 minutes and works once.
2. On the device, the app lists the Macs it finds. The person picks one and scans the code.
3. The two apps agree on a permanent key for that device, stored in the Keychain on both sides. The one-time secret
   is discarded.

A scanned secret is used rather than a short typed code, because a short code can be guessed by someone recording
the Wi-Fi traffic. The app also accepts the secret as pasted text, since the Simulator has no camera.

### Every later connection

Encrypted, and both sides prove they hold the device's key before any data moves. An unpaired device cannot make a
request. Each paired device has its own listener and its own key on the Mac, so removing one device stops its
listener and leaves the others as they were.

### On the Mac

- The listeners exist only while "Let your iPad or iPhone connect" is on.
- Each paired device is listed with Remove, which discards its key at once and closes its connection.
- Each paired device has a "Can control" switch. Off means watch only.
- The Mac window shows an indicator while a device is connected.

### What a device can never do

- Add a project folder, or answer the "trust this folder" prompt.
- Change the Remote settings, or pair another device.

### Not in the concept

Connecting from outside the local network. A later "type the Mac's address" field would make it work over a private
network such as Tailscale without changing this design.

`SECURITY.md` gets a section covering all of the above.

## iPad screens and touch

### Layout

Three columns: projects and flows on the left, the canvas in the middle with a floating bar (Run, Stop, zoom, undo),
and on the right the inspector, run log, history and cost. The right column can be hidden. Same Flight plan colours,
light and dark.

### Canvas gestures

| Gesture | Result |
|---|---|
| One-finger drag on empty canvas | Pan |
| Pinch | Zoom |
| Double-tap empty canvas | Zoom to fit |
| Tap a card | Select it and show it in the inspector |
| Drag a card by its title bar | Move, with the Mac's snapping |
| Drag a card's corner grip | Resize |
| Drag from a port dot to a card | Make a link |
| Long-press a card or link | Its menu |
| Long-press empty canvas | Add a card there |
| "Select" button, then drag | Box-select |

Port dots and grips have a finger-sized touch area. A trackpad or mouse behaves as on the Mac.

### Terminals

- On the canvas, each agent card shows its live terminal, scaled with the zoom.
- An expand button opens that terminal full screen, with the keyboard and a row of extra keys (Esc, Tab, Ctrl,
  arrows). Typing happens here, because the on-screen keyboard covers half the screen.
- A hardware keyboard works in both places.

### When something needs you

- Approval cards show Approve and Reject (with a note) on the card.
- A banner lists cards waiting on you. Tapping it jumps to the card.
- There are no alerts while the app is closed. iOS drops the connection in the background, and push notifications
  need the paid membership.

### Connection

A status pill shows Connected, Reconnecting or Mac not found. When the link is down the canvas shows the last state,
dimmed, with editing off.

### iPhone

The same app, stacked: flow list, then a full-screen canvas, with the inspector as a sheet.

## When things go wrong

| Situation | What happens |
|---|---|
| Wi-Fi drops, the device sleeps, the app goes to the background | The device retries, then takes a fresh full snapshot |
| Mac asleep or Queen Bee closed | "Mac not found", last state shown dimmed |
| Mac refuses a command | The device returns to the Mac's state and shows the Mac's reason |
| No answer to a command within a few seconds | Treated as a dropped link |
| Protocol versions differ | The update message, and nothing else loads |
| Device removed on the Mac | Connection closes, device returns to pairing |
| Device cannot keep up with terminal output | The Mac drops the backlog and sends a fresh replay |
| Any failure in the remote code | The Mac app and any run carry on. Remote work never blocks a run |

Several devices may be connected at once. Each gets the same updates.

## Testing

- **`Core` unit tests.** Every message encodes and decodes; the version check; the replay buffer; command to edit.
- **Loopback test.** A Swift test client pairs with the Mac app over localhost using a pasted secret, checks the
  snapshot, sends commands and checks the result. Runs with the existing e2e suite, using the app's test mode.
- **iOS app.** Unit tests for the mirror model, then driven in the Simulator against the Mac app on the same
  machine. Camera pairing and real Wi-Fi behaviour are checked by hand on a real device.
- **CI.** The iOS target builds, unsigned, on every push. Existing core and e2e tests stay green with Remote off.

## Keeping the repository clean

The repository is public. These rules hold for every commit in every stage.

- **Signing details stay local.** A free Apple ID still has a team id, and Xcode writes it into the project when
  you pick a team. The iOS target reads its team id and bundle id from `Mobile/Local.xcconfig`, which is
  git-ignored. A committed `Mobile/Local.example.xcconfig` shows the two lines to fill in. `project.yml` never
  holds a team id.
- **No keys in files.** Pairing secrets and device keys live only in the Keychain and in memory. They are never
  written to disk, logged, or put in a flow file, settings file or crash note.
- **Tests make their own secrets.** Every test generates a random secret when it runs. No fixture holds a key, a
  real device name, a home folder path or a local network address.
- **Nothing identifying in logs or screenshots.** Log lines name a device by a short random id. Screenshots for the
  README are taken with a sample project and a generic Mac name.
- **Ignored build output.** `.gitignore` gains `Mobile/Local.xcconfig`, `*.mobileprovision`, `*.p12`, `*.cer` and
  `*.xcarchive`. Generated Xcode projects are already ignored.
- **A check in CI.** A workflow step scans each push for secrets and fails on a team id, a private key or a
  provisioning profile in a tracked file.
- **A check before each push.** The staged diff is read for the items above before any push from this work.

## Stages

Each stage gets its own implementation plan and ends in something usable.

1. **Link and mirror.**
   The terminal replay proof first. Then pairing, the Settings pane, the live canvas, card and session states,
   terminals, run log, history and cost.
   Done when a paired iPad shows a real run from start to finish, matching the Mac.

2. **Respond.**
   Run, run from card, stop, approve or reject, allow a command, full-screen terminal typing, and the "Can control"
   switch.
   Done when the tender example can be run from the iPad without touching the Mac.

3. **Edit.**
   All canvas gestures, the inspector's editing fields, flow create, rename and delete, and shared undo.
   Done when a small flow can be built from scratch on the iPad and run.
