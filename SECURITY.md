# Security

## Reporting a problem

Please report security problems privately through
[GitHub's private vulnerability reporting](https://github.com/bamboozledkitty/queen-bee/security/advisories/new),
not in a public issue. Say what you found, how to reproduce it and which version you used.

Only the latest release gets security fixes.

## What Queen Bee does on your Mac

Queen Bee starts Claude Code sessions as you, in the folders you choose. It is not sandboxed. A session can do
whatever Claude Code can do under the permission mode its card has, so treat a flow like a script you are about to run.

- **Flow files are instructions.** A flow in `<project>/.queenbee/flows/` holds each agent's instructions, working
  folder and permission mode, and opening the flow starts those sessions. When you add a folder that already has
  flows in it, the app asks whether you trust it first. The `.queenbee` folder ignores itself in git, so flows are
  not shared by accident. Flows that arrive later in a folder you already trusted are not asked about again.
  A flow file whose ids the app could not have made, such as a card called `orchestrator` or an id with a slash
  in it, is not loaded and shows in the sidebar as a file the app can't read.
- **Permission modes are limited.** A card can use manual, accept edits, plan or auto. A mode that skips permission
  checks cannot be set from a flow file, the settings panel or the orchestrator's tools.
- **Script cards run commands with no prompt.** A Script card runs a shell command as you when a run reaches it.
  It only runs a command you typed into its settings on this Mac or allowed yourself. A command written by the
  orchestrator, pasted in, arriving in a flow file or written from a paired device stops the run and asks you
  first. What you allowed is kept in the app's own settings, not in the flow file.
- **Approval cards hold a run, not the orchestrator.** A run stops at an Approval card until you answer. Only a
  reply to a message the run handed an agent is passed on, so an agent further along that finishes some other
  turn doesn't carry the run past the card. The orchestrator can still edit the flow, which includes taking an
  Approval card out.
- **End cards write files.** An End card can save the final answer to a file in the project folder, and the
  orchestrator can set that up without asking. A save can't leave the project folder, and it is refused inside
  `.git`, `.claude` and `.queenbee`, where a file could change what git, Claude Code or Queen Bee does next. Any
  other file in the project can be overwritten.
- **Schedules start runs with nobody watching.** A Start card can run on the clock or when a file in the project
  changes, while the app is open. A schedule only fires once you have set it or turned it on in this app, or a
  paired device with "Can control" turned it on, and only for the command it was turned on with, so one that arrives in a flow file stays off until you agree. If the orchestrator
  changes that command, or an agent's instructions, folder or permissions, the flow's schedules go off until you turn
  them on again. A paired device is held to more: see "Can control" below. A copied Start card never brings
  its schedule with it. Other edits by the orchestrator leave a schedule on: a Prompt card added after Start,
  Start linked to a different agent, or a change inside a sub-flow. A flow file changed on disk while the app
  is closed is not compared with what you agreed to either.
- **Sub-flows have a depth limit.** A Flow card runs another flow of the same project. How deep that can nest is
  set on the flow at the top, three levels unless changed and never more than ten, and a run stops at the limit, so
  flows can't be chained without end.
- **An orchestrator works downward only.** A flow's orchestrator can edit its own flow and the sub-flows below it,
  and can make new sub-flows there. It cannot edit the flows above or beside its own, and it can only point a Flow
  card at a flow already below its own or at a sub-flow nothing uses yet; linking any other flow in is yours to do.
- **The orchestrator can edit and run the flow without asking.** Its tools are pre-approved. Text an agent reads
  from the web or a file can end up in front of the orchestrator, so the usual prompt-injection caution applies.
- **An agent's browser is a real browser.** An agent card with its Browser switch on drives a hidden Chromium-based
  browser. Opening a page, reading it, taking a screenshot, scrolling, going back and waiting need no approval.
  Clicking, typing and pressing keys go through Claude Code's approval and the card's permission mode. An agent
  reaches only the tab of its own card, and only while the switch is on. The browser opens `http` and `https`
  addresses only, never `file:` or `chrome:`, and it downloads nothing. The app controls it over a private pipe,
  not a debugging port, so other software can't drive it through the app. Its profile, with any sign-ins you make
  in a card, is in `~/Library/Application Support/QueenBee/browser/`, one per project, apart from your own
  browser. Every agent with a browser in that project is signed in to whatever you signed in to there.
- **A web page can try to steer an agent.** What an agent reads on a page goes into its conversation. The agent is
  told that a page is something it found and never a request from you, and acting on a page needs approval, but
  neither is a guarantee. An agent that reads the web and can also run shell commands without asking is the
  riskiest combination: give such a card a permission mode that asks.
- **The app's socket is local.** The helper talks to the app over a unix socket in
  `~/Library/Application Support/QueenBee/`, a folder only your account can open. Each session has its own secret,
  and only the orchestrator's secret unlocks the flow-editing tools. That keeps an agent from using those tools through
  its own session. It is not a wall against anything that can run commands as you: other software on your account,
  or an agent you have allowed to run any shell command, could read another session's secret.
- **Sessions use Claude Code's classic renderer.** Queen Bee starts every session with Claude Code's classic
  renderer, whatever your own "tui" setting says, so a card's terminal keeps its scroll-back and a paired device
  has it to show. It is passed to each session when it starts. Nothing is written to your Claude Code settings.
- **Messages typed into a terminal are cleaned.** A hand-off the app types into an agent's terminal has its
  escape sequences and control characters removed first, so text one agent wrote can't press keys in another's
  session.
- **Updates are signed.** The app only installs an update signed with the project's update key. Releases are signed
  with a Developer ID but are not yet notarized by Apple. The terminal installer refuses an app that isn't signed
  with the project's Developer ID certificate, checked up to Apple's root.
- **Remote is off until you turn it on.** With "Let your iPad or iPhone connect" on in Settings, an iPad or iPhone
  you paired can connect over your local network and see your flows, their runs and their terminals. A paired
  device can only watch until you turn on "Can control" for it, which the next point is about. A device that
  only watches is sent every flow of the projects in your sidebar with its cards and their settings, the names of
  every flow's cards, the runs and the log, every session's terminal, your saved roles with their settings, and
  what each flow has cost. It is sent nothing of the pages in agents' browsers: no picture, no address and no
  title, because a page there can be one you are signed in to. Its card shows a line saying so in their place. Pairing takes a
  one-time code shown on this Mac, which works once and for two minutes. Each paired device has its own key, kept
  in the Keychain on both sides and never in a file, and every connection is encrypted with it; a device without a
  key is told nothing. Removing a device in Settings deletes its key and closes its connection at once. Queen
  Bee does not connect to any server for this, and nothing is reachable from outside your network unless your
  network makes it so.
- **"Can control" lets a device act, and is off until you turn it on.** Each paired device has a "Can control"
  switch in Settings, under Remote. It is off when a device is paired, and off again if the device is paired a
  second time. The Mac checks it for every single thing a device asks, at the moment it asks, so a device
  with it off can do nothing whatever its app sends, and turning it off takes effect at once, for a device that
  is connected too. With it on, the device can do what these buttons and keys on your Mac do:
  start and stop runs, a run from a chosen Start card included, and Retry a card a run stopped at; approve or
  reject a message an Approval card is holding; allow a Script card's command, which is then remembered for that
  card exactly as if you had allowed it on the Mac, unless a device wrote the command, which a later point is
  about; start, restart and stop a flow's agents, and start and restart its orchestrator; put an agent's settings
  back to what its session is using; turn a Start card's schedule on and off; clear the log, close the message at
  the top of a flow, and pin a flow; type into any session of a flow, the orchestrator's included; and see and use
  an agent card's browser. Typing is the wide one. A session's terminal is where Claude Code asks "may I run this
  command?", and a device that can type there can answer yes. So a device with control can do what you can do in
  those terminals, which is whatever Claude Code can do on your Mac. Turn it on only for a device you would hand
  your Mac's keyboard to.
- **A device with "Can control" can use an agent's browser as you can.** It is sent pictures of the page in each
  agent card it has on its screen, at most ten a second, with the page's address and title. It can click, scroll
  and type in the page, type an address into the card's bar (`http` and `https` only, the same rules as the Mac's
  bar), go back, forward and reload, and copy from and paste into the page. This is the person's own input, so it
  does not go through Claude Code's approval or the card's permission mode, and it acts on whatever site the card
  is on, signed in or not. An address on your Mac or on your local network can be opened, as from the Mac's bar.
  The Mac sends a page's selected text to the device when it asks to Copy. It can also clear a project's browser
  data, take up the Mac's own offer to download a browser (it cannot choose what is downloaded or from where), and
  restart a browser that stopped. Using a card's browser is noted in the flow's log once every 30 seconds for each
  card, never with what was typed or where. Only the cards on the device's screen are sent anything, and turning
  "Can control" off stops the pictures at once. A page can't make the Mac flood the device: each picture is 200 KB
  at most and dropped rather than queued, the bar is told at most four times a second with the address cut to
  2,048 characters and the title to 300, and the device may say which cards are on its screen four times a second.
  Copy asks the page in a world the page's own scripts can't reach, gives up after three seconds, and is sent only
  if the device still has control and the card on its screen.
- **A device with "Can control" can edit your flows.** With the switch on, the device can also change a flow: add,
  move, resize, link, copy, paste, group and delete cards; add an agent from a saved role; change a card's
  settings, its Browser switch included, a link's limit and a group's name; undo and redo; make a new sub-flow for
  a Flow card; and make, rename and delete flows in the projects already in your sidebar. A flow deleted from a
  device goes to the Trash on your Mac, with its file whole. The Mac did not see you make these changes, so it
  holds them to rules its own canvas is not held to:
  - **A Script card's command changed from a device is allowed on the Mac itself.** It stops the run and asks, and
    no device can give the answer, the one that changed it or any other: somebody at the Mac has to read it and
    allow it. The Mac remembers that a card's command came from a device for as long as the command stays as it
    is, in the app's own settings, so quitting the app or undoing and redoing changes nothing. A device can still
    allow a command that came some other way and is waiting, as it could before.
  - **A change from a device to what a flow does turns its schedules off.** That is any link, any card added or
    taken away, pasting, and any setting. Moving and resizing cards, grouping them, and notes do not count. The
    schedules of every flow that runs the changed flow as a sub-flow go off too. They stay off until somebody turns
    them on again: you on the Mac, or a device with control pressing **Turn on**, which is an act of its own and is
    noted in the log with the device's name each time. Nothing else a device does, putting things back included,
    turns one on, and a schedule set in a card's settings from a device arrives switched off. Turning a schedule on
    waits behind the device's edits sent before it, so it is agreed to for the flow as they left it. A Script card's
    command a device wrote is still held for Allow on the Mac when a scheduled run reaches it.
  - **A permission mode that skips permission checks cannot be set**, as nowhere else.
  - **An agent's folder cannot be changed from a device**, by a setting or by Undo. It is picked on the Mac.
  - **Agents added from a device do not start by themselves.** In a flow that is open on the Mac, an agent card a
    device adds, copies, pastes or brings back has no Claude Code session until someone starts it: the device's
    **Start agent** or **Start its agents**, or you on the Mac. A flow can be given twelve agents at most from a
    device.
  - **Pasting is editing.** Cards pasted from a device get new ids and names, bring no folder, session or schedule,
    and a pasted Script card's command counts as written by a device. A paste is all or nothing: one with a link or
    a group that couldn't be made pastes nothing, and every card lands on the canvas.
  - **Roles a device saves or changes are marked on the Mac.** A device can save an agent's settings as a role,
    update a role from a card that has it, and delete a role. A role from a device can't skip permission checks, its
    instructions are held to the caps below, and no device can save one once the Mac has 200. Changing a role changes
    no card that already has it. The Mac marks such a role "Changed from" the device, with the time, in the role
    menu, under Agent in the list of cards to add and in the card's settings, and the first time you pick it or reset a card to it on the Mac
    it asks "This role was changed from … Use it?", showing what it holds. The mark goes when you agree, or when you
    save the role on the Mac. What the role held before the device changed it is kept, so **Put back the earlier
    version** can restore it. A role deleted from a device is kept for 30 days, and **Restore a role deleted from a
    device** in the role menu puts it back. These are kept with the app's roles, not in any flow file.
  - **Sizes and rates are capped.** A name is 200 characters and 800 bytes at most, any other text 16,000
    characters and 48,000 bytes, a flow 200 cards, 400 links and 2 MB when it is added to from a device, and a
    project 200 flows. A device may send 60 commands in a burst and 20 a second after that; more are refused. Key
    presses for a terminal are not counted in that. A drag the Mac hears no more of ends after two seconds.
  - **Every kind of change is noted in the flow's log with the device's name.** The first of each kind is written
    at once, and half a minute later one more line says how many more there were. So a device adds two lines at
    most for each kind of change in half a minute, however many changes it makes. Turning a schedule on or off,
    and closing the message at the top of a flow, are written each time, with the first 80 characters of the
    message. A long name is cut short there. The log keeps its last 600 lines, so a device that kept changing
    things for several minutes could still push older lines out of it.
  - **A device's Clear keeps what devices did.** Clear on a device empties the log and the list of earlier runs,
    except for every line that says what a device did or that a schedule went on or off, and adds one saying which
    device cleared it. Your own Clear on the Mac empties all of it.
  - **Undo is shared with the Mac.** A device's Undo and Redo work on the Mac's own list of changes, so a device
    can undo a change you made on the Mac, and you can undo one a device made.
  - A device cannot delete the flow your Mac's window is showing, or a flow with a run going or starting, or give
    a flow a name another flow in the project has.
- **What a device still cannot do.** With "Can control" on or off, no device can allow a Script card's command
  that a device wrote, change an agent's folder, add or remove a project folder, answer the "trust this folder"
  prompt, change the Remote settings (pairing, removing devices, "Can control"), change the app's own settings,
  check for updates, or do what only means something on a Mac, such as Show in Finder: the Mac has no message for
  any of those. What a device does is noted in the flow's log on the Mac with the device's name: a run started or
  stopped, a message approved or rejected, a command allowed or not run, agents and the orchestrator started,
  restarted or stopped, a message sent to a session, each kind of edit, a schedule turned on or off, a role saved,
  updated or deleted, a card's browser used, and that it typed into a session, though never what it typed. While a
  device that can control is connected, the sidebar says so.
- **What these rules do not stop.** A device with control can type into the orchestrator and into any agent, so
  it can ask them to change the flow or to run a command, and it can answer Claude Code's own permission prompts
  in their terminals. A command the orchestrator writes into a Script card at a device's asking is the
  orchestrator's, and a device may allow it. So may it allow the command of a card you copy on the Mac from one
  whose command a device wrote: the copy is a new card. A device can raise a flow's sub-flow limit as far as ten,
  and turn a schedule on, after which the flow runs with nobody watching. So the
  rules above keep a device's own edits from running unseen. They do not make "Can control" safe to give to a
  device you do not trust.

## What the iPad and iPhone app does

The companion app shows what a paired Mac sends it, and sends the Mac what you press and type there. It has no
account and talks to no server.

- **What it stores.** In its own settings: an id for the device, and the name and id of the Mac it is paired with.
  In the device's Keychain: the key it shares with that Mac. The key is kept so that it can be read only on that
  device: it is not copied to another device by a backup, a transfer or iCloud Keychain. Flows, logs, messages and terminal output
  are held in memory while the app is open and are not written to the device.
- **What it sends the Mac.** When pairing: the device's id and its name, which is what the Mac lists it as. On
  each connection: its id, its name and the version of the link it speaks. After that, which flow it has open, and
  each thing you ask of the Mac from it: a button you pressed, such as Run or Approve, a message you wrote for a
  session, keys you pressed for a session's terminal, a change you made to a flow with Edit on, cards you pasted,
  and what you did in a card's browser, text you typed or pasted into the page included. It also tells the Mac
  which agent cards with a browser it has on its screen, so the Mac sends pictures of those and no others. The Mac
  refuses every one of these but the last unless "Can control" is on for the device, and the app shows no buttons,
  no Edit and no place to type while it is off. A button press, a message or a key that can't go now is given up, and so is a change
  made on the canvas.
- **What it keeps to send later.** One thing: what you wrote in a card's setting, when the Mac could not be reached
  or turned it down. It is kept in memory on the device, shown where you wrote it with a line saying it has not
  been sent, until you send it or discard it or close the app. It is never written to the device's storage, and it
  is never sent without the Mac checking it like any other change.
- **Terminals give nothing back.** A terminal on the device is drawn from the output of the session on the Mac.
  That output holds the questions a program asks its terminal, and the terminal on the device answers them, as
  any terminal would. Every answer is dropped on the device. So is anything else the terminal would send: taps on
  it are not passed on, and a program on the Mac cannot read or set the device's clipboard. The one way text from
  the Mac reaches the device's clipboard is Copy in a card's browser: the page's selected text, up to 100,000
  characters, is put there when you press it. What you type for a
  session does not go through the terminal at all. It goes from the app's own message box and keys, as the keys
  you pressed and nothing more.
- **Looking at an earlier run changes only the device.** The Mac is not told, and what it shows does not change.
- **Forget this Mac.** In the app's settings, this deletes the key from the Keychain and the Mac's name and id
  from the app. The device then has to be paired again. The Mac still lists the device until you remove it there,
  but with its key gone the device can no longer connect. Deleting the app also deletes its settings; to be
  sure the key is gone too, use Forget this Mac first.
- **The camera and the local network.** The camera is used only on the pairing screen, to read the code on the
  Mac's screen, and no picture is kept. The local network is used only to find and reach Queen Bee on your Mac.

## Known limits

- The orchestrator reads what the app can do from `.queenbee/CAPABILITIES.md` in the project, which the app rewrites
  each time an orchestrator's session starts. An agent that can write files in the project could change it
  between starts, which is one more way text from an agent can reach the orchestrator.

- An agent's `read` of a page covers the page itself, not frames from other sites embedded in it. A screenshot
  shows those, and `click` takes a point from a screenshot.
- When Queen Bee downloads its own browser, that copy doesn't update itself, and it keeps its cookies under a
  fixed key instead of one from your keychain. A browser you installed yourself has neither limit.
- A page that asks for a file to be chosen, the camera, or a passkey can't be answered in a card's browser.
- A device with "Can control" can open any `http` or `https` address in a card's browser, ones on your Mac and on
  your local network included, and the browser it drives has the project's shared profile, with whatever you are
  signed in to there.
- What a device shows of a card's browser is a picture of the page on the Mac, not the page. What it does there
  is done on the Mac's page.

- The session plugin is copied to Application Support at launch, where another program running as you could change it.
- A flow's regular-expression checks run as written. A pathological pattern can stall a run.
- A Remote connection is encrypted with a key both sides already hold, and that key is not replaced by a fresh one
  for each connection. So someone who recorded the Wi-Fi traffic while a device was being paired, and who also saw
  the code that pairing used, could work out that device's key and read what it is sent. The code is on screen for
  two minutes at most. Treat it like a password: don't share your screen or photograph it while it shows.
- Anyone holding a paired, unlocked iPad or iPhone can read everything that device is sent: instructions, messages
  between agents, and whatever is on each terminal. If "Can control" is on for it, they can also run your flows,
  change them, and type into your sessions. The app has no lock of its own. Remove the device in the Mac's
  settings if it is lost.
- Text a device sends for a session is entered there as one paste, with anything a terminal would act on taken out
  of it first. Keys are different: they are sent as they are, because Esc and Ctrl-C are what they are for.
- A build of the iPad and iPhone app from source in the Debug configuration, which is what Run in Xcode makes,
  includes launch arguments for tests that can point the app at a made-up Mac. In the Simulator that build also
  writes what it is showing to a file in the app's own folder, for the tests to read. None of this is in a Release
  build, and the file is never written on a real device.
- The rule that an agent may only message the agents it is linked to is there to keep a flow tidy, not to
  contain an agent. The app answers it, and a session that can't reach the app is allowed to send, so that
  sessions keep working when Queen Bee is closed.
- Two project folders open together that hold a flow with the same id cross-wire: a session of one can be
  answered by the other's flow. A project folder copied along with its `.queenbee` folder does this. Open one
  of the two at a time.
- A reply carries no mark of the run it answers. After a run is stopped, a late reply from it can be taken as
  the answer in the next run, if that agent has been handed a message there.
- Allowing a Script card's command allows that command line, not the files it runs. If it runs a script in
  the project, a change to that script is not asked about.
