# Queen Bee

A Mac app for building and running flows of Claude Code agents on a canvas. It needs macOS 26 or later on Apple silicon.

Queen Bee is a work in progress. It is open source, and [contributions are welcome](CONTRIBUTING.md).

Each agent is a live `claude` session in a terminal that sits on the canvas. You can click into any of them and type. Logic cards (If / Else, Switch, And, Or, Prompt, Loop until, Approval, Script, Flow, End) route each agent's finished reply to the next cards. Every flow also has an orchestrator, a Claude Code session docked beside the canvas that can edit the flow, run it and talk to the agents.

![A finished run: cards the run passed through carry a check and a count, and travelled links are green](docs/queen-bee-flight-plan-light.jpg)

The app follows light and dark. [The same run in dark](docs/queen-bee-flight-plan-dark.jpg).

## Install

**From a terminal** (opens straight away):

```sh
curl -fsSL https://raw.githubusercontent.com/bamboozledkitty/queen-bee/main/scripts/install.sh | sh
```

This downloads the latest release, checks it is signed by the Queen Bee developer's certificate and puts it in Applications. You can [read the script](scripts/install.sh) first.

**From the disk image:**

1. Download `QueenBee-<version>.dmg` from the [latest release](https://github.com/bamboozledkitty/queen-bee/releases/latest).
2. Open it and drag **QueenBee** onto the Applications folder beside it.
3. Open Queen Bee from Applications. macOS will say it could not verify the app; the steps below get past that.

You need:

- macOS 26 or later on Apple silicon.
- [Claude Code](https://claude.com/claude-code) 2.1.287 or later, signed in. The app loads a small plugin into each session, which needs that version.

Releases are signed with a Developer ID but not yet notarized by Apple. A copy downloaded in a browser is blocked the first time you open it, with a message that Apple could not verify it. The terminal install doesn't hit this. To open a blocked copy:

1. Click **Done** on that message.
2. Open **System Settings → Privacy & Security** and scroll to the Security section.
3. Click **Open Anyway** beside the line about Queen Bee, then confirm.

You only do this once. The app checks for updates by itself, and **Queen Bee → Check for Updates…** checks straight away. What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

Queen Bee starts Claude Code sessions as you and is not sandboxed. Read [SECURITY.md](SECURITY.md) before opening flows from someone else.

Flows are saved in `<project>/.queenbee/flows/`, and agents work in the project folder.

## Build from source

You need Xcode 27 and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./scripts/build.sh
open build/Build/Products/Debug/QueenBee.app
```

A build from source is called Queen Bee Dev. It keeps its own settings and support folder, so it can run beside an installed copy without touching it.

## Use

- **Add Project Folder…** at the foot of the sidebar adds a folder. Each folder lists its flows, and **+** beside its name makes a new one.
- The first time you open the app, a short walk-through explains agents, logic cards and the orchestrator. **Help → Welcome to Queen Bee** shows it again.

  ![The walk-through's second step: every agent is a live terminal](docs/queen-bee-first-run.jpg)

- An empty flow shows a note pointing at the orchestrator: describe the flow you want there and it builds it. Close the note to build by hand.
- The **palette** at the canvas's top-left holds the card types. Click one to add it, or drag it to where you want it. Rest the pointer on one to read what it does. Each agent card starts its own Claude Code session.
- An **Approval** card stops a run until you approve, edit or reject the message. A **Script** card runs a shell command and goes out Pass or Fail; a command you didn't type yourself asks before it first runs. A **Flow** card runs another flow as one step: double-click it to open that flow, or to make a new sub-flow with an Input and an Output, and use the names in the title bar to go back. Sub-flows can hold Flow cards of their own, three levels deep unless you change the limit in the top flow's settings (the sliders button in the toolbar).
- A Start card's settings can make it run on a schedule or when a file changes. Schedules run only while Queen Bee is open.
- **Run from here…** in a card's settings starts a run at that card with a message you give it. A card a run stopped at offers **Retry**.
- An agent's settings can be saved as a **role**, which then sits under Agent in the palette for any flow.
- Select several cards and choose **Group** (⌘G) to frame them under a name. Double-click the name to fold the group into one card. **Tidy Up** (⇧⌘L) lays the whole flow out left to right. **Find** (⌘F) goes to a card or flow by name. A map in the corner shows the whole flow once it has five cards or more.
- Drag a card by its title bar. Drag its bottom-right corner to resize it. A dragged card lines up with its neighbours or settles on the grid; hold Option to place it freely. Pinch to zoom and two-finger scroll to pan, or use the zoom control at the bottom-right. With a mouse: the wheel pans up and down, Shift with the wheel pans sideways, Command (or Control) with the wheel zooms about the pointer, and holding Space or the middle button turns the pointer into a hand that drags the canvas.
- Shift-click cards, or drag a box on empty canvas, to select several. They move, duplicate (⌘D), copy, paste and delete together, and the arrow keys nudge them. Escape deselects.
- ⌘Z undoes the last change to the flow, including changes the orchestrator made. With the cursor in a text box, it undoes typing there first.
- Right-click a card, a link or empty canvas for a menu.
- Zoomed out below 40%, each card shows its name and state in large type in place of its contents.
- Drag from a dot on a card's right edge onto another card to link them. Click a link to change its max passes or delete it.
- Click a card's title to open its settings: rename it in the header, change its rows, and delete or restart it from the footer. Click inside a terminal to type in it; click empty canvas to give the keyboard back.
- Write the Start card's command, then press **Run**. Cards the run passes through get a check and a count, travelled links turn green, and the link a message is on now shows orange dashes.
- The panel on the right has the **Orchestrator**, the run **Log**, and the **Output** of each End card. The line at the canvas's bottom-left shows the latest step. Every run is kept between launches, and the Log tab's menu puts an earlier run back on the canvas.
- Click a link to read the messages it carried in the run on show.
- The figure beside the zoom control is what the flow has used, at API prices, as Claude Code reports it. Click it for a breakdown by agent and by run.
- When the app is in the background, a notification tells you that a card needs you or a run has ended. **Settings** turns this off.
- A flow that needs you says so on its sidebar row, and the toolbar shows a button that takes you to the waiting card.
- **View → Appearance** switches between light, dark and following the system.
- **Remote.** An iPad or iPhone on the same Wi-Fi can watch your flows. **Settings → Remote** turns it on and pairs a device. See [On your iPad or iPhone](#on-your-ipad-or-iphone).

## On your iPad or iPhone

There is a companion app for iPad and iPhone. It pairs with Queen Bee on your Mac over your local Wi-Fi, with no server and no account, and shows what the Mac is doing.

For now it only watches. It shows:

- every project and its flows, with the same "needs you", "running" and "stopped" badges as the Mac's sidebar;
- the open flow's canvas as the Mac draws it, live: cards, links, groups, run marks and counts;
- each agent's terminal in its card, and full screen, where you can scroll back through earlier output;
- the run log, the answers the End cards collected, earlier runs, and what the flow has cost;
- which cards are waiting on you.

It can't yet run or stop a flow, approve or reject, type into a terminal, or edit anything. You do those on the Mac.

The app isn't on the App Store. You build it yourself and put it on your own device, which a free Apple ID is enough for. The device needs iOS or iPadOS 26 or later.

### Install it on your own device

You need Xcode 27 and xcodegen, as for building the Mac app.

1. Sign in to Xcode with your Apple ID: **Xcode → Settings… → Accounts**, then **+**. On the same pane choose **Manage Certificates…**, then **+**, then **Apple Development**.
2. Find your team id. It is ten letters and digits. In a terminal:

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

   The team id is the part after `OU=`.
3. Make your own settings file and fill in its two lines:

   ```sh
   cp Mobile/Local.example.xcconfig Mobile/Local.xcconfig
   ```

   Open `Mobile/Local.xcconfig`, remove the two slashes at the start of the `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` lines, put your team id after the first `=`, and change `yourname` in the second to something nobody else would pick. Git ignores this file. Never commit it.
4. Generate the project and open it:

   ```sh
   xcodegen generate
   open QueenBee.xcodeproj
   ```

5. Plug in the iPad or iPhone. In Xcode's toolbar pick the **QueenBeeMobile** scheme and your device.
6. On the device, turn on **Settings → Privacy & Security → Developer Mode**, and restart it when asked. The switch only appears once the device has been connected to Xcode.
7. Press **Run** in Xcode.
8. The first time, the app won't open until you trust yourself as its developer: on the device, **Settings → General → VPN & Device Management**, tap your Apple ID, then **Trust**. Open Queen Bee again.

An app installed with a free Apple ID stops opening after 7 days. Press **Run** in Xcode again to install it afresh. It stays paired.

### Pair it with your Mac

Both need to be on the same Wi-Fi.

1. On the Mac, open Queen Bee's **Settings** and find **Remote**. Turn on **Let your iPad or iPhone connect**, then click **Pair a device…**. A code appears. It works once, for two minutes.
2. On the device, open Queen Bee and tap **Continue**. The first time, iOS asks whether Queen Bee may find devices on your local network. Allow it.
3. Choose your Mac from the list, then point the camera at the code.

From then on the device connects by itself whenever both apps are open on the same Wi-Fi. To stop a device connecting, click **Remove** beside it in the Mac's settings, or tap the gear on the device and choose **Forget this Mac**. [SECURITY.md](SECURITY.md) says what a paired device can see and what each side stores.

### Run it in the Simulator

No Apple ID is needed for this.

```sh
./scripts/build-mobile.sh
xcrun simctl boot "iPad Pro 11-inch (M5)"
open -a Simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/QueenBeeMobile.app
xcrun simctl launch booted dev.queenbee.mobile
```

Use the name of any iPad or iPhone simulator you have (`xcrun simctl list devices` lists them). The Simulator has no camera, so the app asks for the code as text: on the Mac click **Copy the code as text** under the code, then paste it into the app.

## How it works

- `Core/` is a Swift package with no UI: the flow model, the file store, the routing engine, the orchestrator's tools and the socket messages. `cd Core && swift test` runs its tests.
- `App/` is the SwiftUI and AppKit app. The canvas is an `NSScrollView` with magnification, and each terminal is a SwiftTerm view inside a card. `App/Design/Tokens.swift` holds every colour, type size, spacing step and timing the views use.
- `Helper/` builds `qb`, a small binary inside the app bundle. Claude Code hooks, the plugin and the orchestrator's tool server all run it, and it talks to the app over a unix socket in `~/Library/Application Support/QueenBee/`.
- `Mobile/` is the iPad and iPhone app. It links the same `Core/` package for the messages, the flow model and the link routes, draws the canvas with UIKit and the panels with SwiftUI, and feeds each terminal the output the Mac sends. `Mobile/Design/Tokens.swift` mirrors the Mac's tokens value for value.
- `Plugin/qb-link/` is the plugin the app loads into every session. When an agent's turn ends it asks the app where the reply goes and sends it there as a Claude Code session message.

## Tests

```sh
cd Core && swift test        # 242 unit tests on the model, store, engine, link router, snapping, layout, triggers, tools, the Remote link and what a device makes of it
./scripts/e2e.py             # end-to-end: real Claude Code sessions on Haiku, about seven minutes
```

The end-to-end script starts a separate test copy of the app with its own support folder, so a copy you have open is left alone. It builds a scratch project with one flow per scenario and drives the app through a test harness that only exists when the app is launched with `--testing`. Name scenarios to run a few: `./scripts/e2e.py guard loop`.

The iPad and iPhone app is checked in the iOS Simulator by three scenarios that only run when named. Build it first with `./scripts/build-mobile.sh`.

```sh
./scripts/e2e.py terminals panels   # the app alone, fed a made-up flow and run: no Mac app, no Claude Code
./scripts/e2e.py mobile             # the app paired with the test copy of the Mac app, with real sessions
```

`QB_E2E_SIMULATOR="iPhone 17"` picks the simulator, and `QB_E2E_SHOTS=<folder>` says where the screenshots go.

## Launch flags

- `--open <folder>` opens that project folder in the first window.
- `--float` keeps the window above others without taking focus. Terminals stop painting in a hidden window, so a check that looks at the window needs it.
- `--welcome` shows the first-run walk-through in a test copy, which otherwise skips it.
- `--testing` turns on the test harness and lets a second copy of the app run. `QB_SUPPORT_DIR` in the environment moves that copy's socket and plugin.

`--testing`, `--welcome` and `QB_SUPPORT_DIR` only work in a debug build.

## Releasing

For maintainers. Raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, put the same version in `Plugin/qb-link/.claude-plugin/plugin.json` and in `serverInfo` in `Core/Sources/QueenBeeCore/MCP.swift`, add a section for the version to `CHANGELOG.md`, then:

```sh
./scripts/release.sh            # build, sign, notarize and write appcast.xml, into dist/
./scripts/release.sh publish    # the same, then tag, push and create the GitHub release
```

The script's header lists the certificate, notarization profile and update key it needs.

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) covers building, testing and the list of known issues where help is wanted.

## License

[MIT](LICENSE)
