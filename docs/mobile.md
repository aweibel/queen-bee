# Queen Bee on iPad and iPhone

There is a companion app for iPad and iPhone. It pairs with Queen Bee on your Mac over your local Wi-Fi, with no server and no account, and shows what the Mac is doing.

It shows:

- every project and its flows, with the same "needs you", "running" and "stopped" badges as the Mac's sidebar;
- the open flow's canvas as the Mac draws it, live: cards, links, groups, run marks and counts;
- each agent's terminal in its card, and full screen, where you can scroll back through earlier output;
- the run log, the answers the End cards collected, earlier runs, and what the flow has cost, with its sub-flows;
- which cards are waiting on you;
- pinned flows first, sub-flows under the flow that runs them, and **Find** across every flow and card.

On an iPad the panel beside the canvas has three tabs: **Orchestrator**, **Run** (the log and the answers) and
**History** (earlier runs and cost). Tap a card, a link or a group and its details slide in over the panel, with a
way back to the tab you were on; tap empty canvas and they go. On an iPhone a card's details come up in a sheet over
the canvas, and the button in the bar at the top brings up the panel's three tabs in a sheet of their own. On an
iPhone's first screen, a bar at the foot switches between **Needs you** (the flows waiting on you, running or
stopped) and **Flows**, and opens into a menu with your Mac's connection, **Settings** and your pinned flows.

A device you have just paired only watches. Turn on **Can control** for it on the Mac, as described below, and from the device you can also:

- run a flow from its Start card and stop a run, with **Run** and **Stop** at the foot of the canvas;
- **Approve** or **Reject** a message an Approval card is holding, with a note saying why, and edit the message before approving it;
- let a Script card's command run with **Allow and run**, after reading it in full, or choose **Don't run**;
- start a flow's sessions with **Start its agents**, and start or restart one agent from its card;
- start a run part-way through, with **Run from here…** in a card's details;
- send a message to the orchestrator or to any agent, and press keys in its terminal;
- build and change a flow by touch, once you press **Edit**: see [Edit a flow](#edit-a-flow) below;
- nearly everything else the Mac's buttons do: **Run from This Start**, **Retry**, **Stop Its Agents**, start and
  restart the orchestrator and **Restart to apply**, **Undo** beside "Not in use yet", turn a schedule on and off,
  **Clear** the log, close the message at the top of a flow, pin a flow, and save, update and delete roles;
- see an agent card's browser beside its terminal, and use it full screen: tap, scroll and type in the page, type an
  address, go back and forward, reload, and copy and paste. Clear its data, restart it, or take up the Mac's offer
  to download one.

The buttons are on the cards themselves, in the "needs you" list at the top of the canvas, and in a card's details.
A few things stay on the Mac: allowing a Script command a device wrote, an agent's folder, project folders and
"trust this folder", Remote settings, the app's own settings and updates. A device that only watches sees no
page of any card's browser: the card says "Turn on “Can control” for this device to see the page."

## Let a device control your Mac

On the Mac, open Queen Bee's **Settings** and find **Remote**. Each paired device is listed there with a **Can control** switch. Turn it on for the device. It is off for every device until you do, and off again for a device you pair a second time. Turning it off takes effect at once.

Under the list the Mac says what the switch allows: "A device with “Can control” on can start and stop runs, answer approvals, type into sessions and edit flows on this Mac." Typing into a session includes answering Claude Code when it asks whether it may run a command, so give this only to a device you would hand your Mac's keyboard to. The same goes for an agent's browser: what a device does there is your own input, on whatever site the card is signed in to. [SECURITY.md](../SECURITY.md) has the whole list of what it allows and what it never does. Everything done from a device is written in the flow's log on the Mac with the device's name.

## Talk to the orchestrator or an agent

Open the session's terminal full screen: tap the arrows on an agent's card, or tap the arrows on the **Orchestrator** tab of the panel beside the canvas. On an iPhone the panel comes up from its button in the bar at the top. Under the terminal there are two ways to type.

- **Message** is a box and a **Send** button. Write what you want to say and send it. The Mac delivers it when the session is ready for a message, so you can send one while it is busy. This is the way to chat with the orchestrator. The panel's **Orchestrator** tab has a message box of its own, so you can write to it without opening its terminal.
- **Keys** brings up the keyboard with a row of extra keys above it: Esc, Tab, Ctrl, the arrows, Enter and the digits and letters Claude Code's prompts ask for. Each key goes to the session as you press it. Use it to answer a prompt in the terminal, such as "Allow this command? 1. Yes 2. No", or to interrupt with Esc. When an agent is waiting for an answer like that, its line in the "needs you" list has **Open its terminal**, which opens it with the keys out.

## Edit a flow

Editing is a mode you turn on, so a stray finger never moves a card while you are only watching. Press **Edit** at the foot of the canvas, or at the foot of a card's details on an iPhone. A bar appears with **Undo**, **Redo**, **Add Card**, **Select**, **Tidy Up** and **Done**. While it is on:

- drag a card by its title bar to move it, with the same snapping and guides as on the Mac, and drag the grip at its corner to resize it;
- drag from a port dot to another card to link them;
- copy, cut and paste cards, across flows too, and select all;
- touch and hold a card, a link or a group for its menu: duplicate, delete, group, ungroup, fold, rename, run from here. Touch and hold empty canvas to add a card there;
- press **Select**, then drag a box round cards or tap them, to move, group or delete several at once;
- open a card's details to change its settings: the same fields as the Mac's settings panel, with the same names and choices. A link's limit and a group's name are there too. The flow's own settings are in the **…** menu beside the run bar, and in the flow's menu in the list;
- in the list of flows, **+** beside a project makes a flow in it, and touching and holding a flow renames or deletes it.

Undo and Redo are the Mac's own, shared with whoever is at the Mac: either of you can undo what the other did. Deleting several cards, or a card with links, asks first. Deleting one link or one unlinked card does not, because Undo brings it back. Deleting a flow always asks, by the flow's name, and the flow goes to the Trash on your Mac.

The Mac did not see you make these changes, so it treats them more carefully than its own:

- A Script card's command you change from a device stops the run and waits to be allowed **on the Mac**. No device can allow it. The device says so where its **Allow and run** button would be.
- Any change to what a flow does turns that flow's schedules off, and those of any flow that runs it as a sub-flow. Moving and resizing cards, grouping them and writing notes don't count. A schedule set from a device arrives switched off, and **Turn on** in the Start card's details turns it on, which the Mac's log notes each time.
- A role saved or changed from a device is marked on the Mac, which asks before you first use it there and keeps what the role held before. A role deleted from a device can be restored on the Mac for 30 days.
- An agent's folder is shown and is changed on the Mac. A permission mode that skips permission checks can't be set.
- An agent card you add from a device does not start by itself in a flow that is open on the Mac: press **Start agent** on it. A flow can be given twelve agents from a device.
- What you write in a setting is sent when you leave the field or pause. If the Mac can't be reached or turns it down, what you wrote stays in the field, marked as not saved, with the Mac's reason beside it.

[SECURITY.md](../SECURITY.md) has all of the rules and what they do not stop.

## After you update the Mac app

The two apps must be on the same version. When you update Queen Bee on your Mac, build and install the iPad and iPhone app again from Xcode, from the same version of the source. Until you do, the device says which of the two needs updating and shows nothing else.

The app isn't on the App Store. You build it yourself and put it on your own device, which a free Apple ID is enough for. The device needs iOS or iPadOS 26 or later.

## Install it on your own device

You need Xcode 27 and xcodegen, as for building the Mac app.

1. Sign in to Xcode with your Apple ID: **Xcode → Settings… → Accounts**, then **+**. On the same pane choose **Manage Certificates…**, then **+**, then **Apple Development**.
2. Find your team id. It is ten letters and digits. In a terminal:

   ```sh
   security find-certificate -a -c "Apple Development" -p | awk '/BEGIN/{c=""} {c=c $0 "\n"} /END CERT/{cmd="openssl x509 -noout -checkend 0 -subject"; printf "%s", c | cmd; close(cmd)}' | grep -B1 "will not expire" | grep -o "OU *= *[A-Z0-9]*" | sort -u
   ```

   The team id is the part after `OU=`. The command looks only at certificates that are still good, because a Mac that has been signed in to Xcode before can hold expired ones from another account.
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

5. Plug in the iPad or iPhone. In Xcode's toolbar pick the **QueenBeeMobile** scheme and your device. It installs a
   Release build, which has none of the test harness in it. **QueenBeeMobile Debug** is the same app built for
   debugging from Xcode.
6. On the device, turn on **Settings → Privacy & Security → Developer Mode**, and restart it when asked. The switch only appears once the device has been connected to Xcode.
7. Press **Run** in Xcode.
8. The first time, the app won't open until you trust yourself as its developer: on the device, **Settings → General → VPN & Device Management**, tap your Apple ID, then **Trust**. Open Queen Bee again.

An app installed with a free Apple ID stops opening after 7 days. Press **Run** in Xcode again to install it afresh. It stays paired.

## Pair it with your Mac

Both need to be on the same Wi-Fi.

1. On the Mac, open Queen Bee's **Settings** and find **Remote**. Turn on **Let your iPad or iPhone connect**, then click **Pair a device…**. A code appears. It works once, for two minutes.
2. On the device, open Queen Bee and tap **Continue**. The first time, iOS asks whether Queen Bee may find devices on your local network. Allow it.
3. Choose your Mac from the list, then point the camera at the code.

From then on the device connects by itself whenever both apps are open on the same Wi-Fi. To stop a device connecting, click **Remove** beside it in the Mac's settings, or tap the gear on the device and choose **Forget this Mac**. [SECURITY.md](../SECURITY.md) says what a paired device can see and what each side stores.

If the device can't connect, its pill says so and it keeps trying. When your Mac turns its key down several times
running, it says "Can't connect to your Mac — retrying" and offers **Pair Again…** beside that. A Mac going to
sleep or a Wi-Fi drop part-way through connecting never makes a device forget its key.

Switching to another app for a moment doesn't disconnect: the device stays connected for about 25 seconds after you
leave Queen Bee, then lets go until you come back.

## Connect from another network

Pairing needs the same Wi-Fi. After that, a device can also reach the Mac by its address, as over a private network
such as [Tailscale](https://tailscale.com).

1. On the Mac, in **Settings → Remote**, turn on **Let devices connect by address too**. The Mac shows the port it
   listens on, 51720, and the addresses it can be reached at.
2. On the device, tap the gear, and under **Connect by address** type one of those addresses, such as
   `mac.tail1234.ts.net` or `100.64.0.7`, then **Save**. Add `:port` only if the Mac shows a different port.

The device still looks for the Mac on the Wi-Fi first, and tries the address when it isn't found there. Each device
still needs its own key from pairing, and the connection is encrypted with it as on the Wi-Fi. Use an address only on
a network you trust: don't open the port to the internet.

## Notifications

While Queen Bee on the device is connected, and for the short while after you leave it, it can tell you when a
message is waiting for approval, a Script card is waiting to be allowed, a session asks you something, or a run
ends. On a device with **Can control**, an approval can be answered from the notification with **Approve** or
**Reject**, and a script with **Allow** or **Don't Allow**, once the device is unlocked. The app asks whether it may
notify you the first time it connects; the switch is under **Notifications** in its settings. Nothing comes from a
server, so once iOS stops the app in the background, nothing more arrives until you open it again.

## Run it in the Simulator

No Apple ID is needed for this.

```sh
./scripts/build-mobile.sh
xcrun simctl boot "iPad Pro 11-inch (M5)"
open -a Simulator
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/QueenBeeMobile.app
xcrun simctl launch booted dev.queenbee.mobile
```

Use the name of any iPad or iPhone simulator you have (`xcrun simctl list devices` lists them). The Simulator has no camera, so the app asks for the code as text: on the Mac click **Copy the code as text** under the code, then paste it into the app.
