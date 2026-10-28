# Queen Bee

A Mac app for building and running flows of Claude Code agents on a canvas. It is a work in progress, open source, and [contributions are welcome](CONTRIBUTING.md).

Each agent is a live `claude` session in a terminal on the canvas: click into any of them and type. Logic cards (If / Else, Switch, And, Or, Prompt, Loop until, Approval, Script, Flow, End) route each agent's finished reply to the next cards. Every flow also has an orchestrator, a Claude Code session docked beside the canvas that can build the flow, run it and talk to the agents.

![A finished run of a flow with three agents, a sub-flow, a script check and an approval: cards the run passed through carry a check and a count, and travelled links are green](docs/queen-bee-flight-plan-light.png)

The app follows light and dark: [the same run in dark](docs/queen-bee-flight-plan-dark.png).

## Install

You need macOS 26 or later on Apple silicon, and [Claude Code](https://claude.com/claude-code) 2.1.287 or later, signed in.

```sh
curl -fsSL https://raw.githubusercontent.com/bamboozledkitty/queen-bee/main/scripts/install.sh | sh
```

This downloads the latest release, checks its signature and puts it in Applications. You can [read the script](scripts/install.sh) first.

Or download `QueenBee-<version>.dmg` from the [latest release](https://github.com/bamboozledkitty/queen-bee/releases/latest) and drag **QueenBee** to Applications. Releases are signed but not yet notarized, so macOS blocks a downloaded copy the first time. Click **Done**, then open **System Settings → Privacy & Security** and click **Open Anyway** beside Queen Bee. You only do this once.

The app updates itself; what changed is in [CHANGELOG.md](CHANGELOG.md). To build from source, see [CONTRIBUTING.md](CONTRIBUTING.md#build-and-run).

Queen Bee starts Claude Code sessions as you and is not sandboxed. Read [SECURITY.md](SECURITY.md) before opening flows from someone else.

## Use

- **Add Project Folder…** at the foot of the sidebar adds a folder, and **+** beside its name makes a flow. Flows are saved in `<project>/.queenbee/flows/`, and agents work in the project folder.
- Describe the flow you want to the orchestrator and it builds it, or add cards from the palette at the canvas's top-left. **Help → Welcome to Queen Bee** shows the walk-through again.
- Drag from a dot on a card's right edge to another card to link them. Click a card's title to open its settings.
- Write the Start card's message and press **Run**. Cards the run passes through get a check and a count, and travelled links turn green. The panel on the right has the orchestrator, the run log and what reached each End card. Every run is kept.

Some cards worth knowing:

- **Approval** stops a run until you approve, edit or reject the message, or decides by itself after a time limit.
- **Script** runs a shell command and goes out Pass or Fail. A command you didn't type yourself asks before it first runs.
- **Flow** runs another flow as one step. Double-click it to open that flow.
- **For each** sends a list through one item at a time and collects the results. **Loop until** goes out Gave up when it runs out of tries.
- A **Start** card can run on a schedule or when a file changes, while Queen Bee is open.

![A run stopped at an Approval card: the card's settings show the message with Approve and Reject, and the sidebar and toolbar say the flow needs you](docs/queen-bee-approval.png)

Also:

- Turn on **Browser** in an agent's settings to give it a web browser beside its terminal. It uses Chrome, Chromium, Edge or Brave, or offers to download one.
- In a git repository each flow works on one branch, in the project folder or in a worktree of its own. The branch chip in the title bar changes it.
- A flow's settings (the sliders button) can stop a run once it has spent a set amount at API prices. Click the cost figure beside the zoom control for a breakdown.
- Save an agent's settings as a **role** to reuse it in any flow.
- **Group** (⌘G), **Tidy Up** (⇧⌘L), **Find** (⌘F) and **Undo** (⌘Z, which also undoes the orchestrator's changes). Right-click a card, a link or the canvas for a menu.

### Start a flow from outside the app

With Queen Bee open, the `qb` command inside the app starts a flow:

```sh
alias qb="/Applications/Queen Bee.app/Contents/MacOS/qb"
qb run ~/work/site "Review" "Check the homepage for broken links"
```

It takes the project folder, the flow's name or id, and an optional starting message. It waits for the run, prints what reached the End cards and exits 0; it exits 1 if the run ended with no answer and 3 if it couldn't start. `--no-wait` returns once the run has started. The folder must be one you have added and trusted.

A link works too: `queenbee://run?flow=<flow id>&message=<message>`. Queen Bee shows the flow and message and starts only when you press **Run**.

## On your iPad or iPhone

A companion app pairs with Queen Bee over your local Wi-Fi, with no server and no account. It shows every flow, the open flow's canvas live, each agent's terminal, the run log and the cost. Turn on **Can control** for a device in **Settings → Remote** and it can also run and stop flows, answer approvals, message the orchestrator and agents, and edit flows.

It isn't on the App Store: you build it and put it on your own device with a free Apple ID. [docs/mobile.md](docs/mobile.md) covers installing, pairing, connecting from another network and running it in the Simulator.

## License

[MIT](LICENSE). The licenses of the packages the app is built with are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), and a copy ships inside the app.
