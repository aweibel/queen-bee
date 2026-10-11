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
- **Permission modes are limited.** A card can use manual, accept edits, plan or auto. A mode that skips permission
  checks cannot be set from a flow file, the settings panel or the orchestrator's tools.
- **Script cards run commands with no prompt.** A Script card runs a shell command as you when a run reaches it.
  It only runs a command you typed into its settings or allowed yourself on this Mac. A command written by the
  orchestrator, pasted in, or arriving in a flow file stops the run and asks you first. What you allowed is kept in
  the app's own settings, not in the flow file.
- **End cards write files.** An End card can save the final answer to a file in the project folder, and the
  orchestrator can set that up without asking. A save can't leave the project folder, and it is refused inside
  `.git`, `.claude` and `.queenbee`, where a file could change what git, Claude Code or Queen Bee does next. Any
  other file in the project can be overwritten.
- **Schedules start runs with nobody watching.** A Start card can run on the clock or when a file in the project
  changes, while the app is open. A schedule only fires once you have set it or turned it on in this app, and only
  for the command you set it with, so one that arrives in a flow file stays off until you agree. If the orchestrator
  changes that command, or an agent's instructions, folder or permissions, the flow's schedules go off until you turn
  them on again. A copied Start card never brings its schedule with it.
- **Sub-flows have a depth limit.** A Flow card runs another flow of the same project. How deep that can nest is
  set on the flow at the top, three levels unless changed and never more than ten, and a run stops at the limit, so
  flows can't be chained without end.
- **An orchestrator works downward only.** A flow's orchestrator can edit its own flow and the sub-flows below it,
  and can make new sub-flows there. It cannot edit the flows above or beside its own, and it can only point a Flow
  card at a flow already below its own or at a sub-flow nothing uses yet; linking any other flow in is yours to do.
- **The orchestrator can edit and run the flow without asking.** Its tools are pre-approved. Text an agent reads
  from the web or a file can end up in front of the orchestrator, so the usual prompt-injection caution applies.
- **The app's socket is local.** The helper talks to the app over a unix socket in
  `~/Library/Application Support/QueenBee/`, a folder only your account can open. Each session has its own secret,
  and only the orchestrator's secret unlocks the flow-editing tools. That keeps an agent from using those tools through
  its own session. It is not a wall against anything that can run commands as you: other software on your account,
  or an agent you have allowed to run any shell command, could read another session's secret.
- **Updates are signed.** The app only installs an update signed with the project's update key. Releases are signed
  with a Developer ID but are not yet notarized by Apple.
- **Remote is off until you turn it on.** With "Let your iPad or iPhone connect" on in Settings, an iPad or iPhone
  you paired can connect over your local network and see your flows, their runs and their terminals. A paired
  device can only watch until you turn on "Can control" for it, which the next point is about. Pairing takes a
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
  start and stop runs; approve or reject a message an Approval card is holding; allow a Script card's command, which
  is then remembered for that card exactly as if you had allowed it on the Mac; start or restart a flow's agents;
  and type into any session of a flow, the orchestrator's included. Typing is the wide one. A session's terminal
  is where Claude Code asks "may I run this command?", and a device that can type there can answer yes. So a
  device with control can do what you can do in those terminals, which is whatever Claude Code can do on your Mac.
  Turn it on only for a device you would hand your Mac's keyboard to.
  With it on or off, no device can add a project folder, answer the "trust this folder" prompt, change the
  Remote settings, pair or remove a device, change a card's settings, or change the flow itself: the Mac has no
  message for any of those. What a device does is noted in the flow's log on the Mac with the device's
  name: a run started or stopped, a message approved or rejected, a command allowed or not run, agents started, a
  message sent to a session, and that it typed into a session, though never what it typed. While a device that can
  control is connected, the sidebar says so.

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
  session, or keys you pressed for a session's terminal. The Mac refuses every one of these unless "Can control"
  is on for the device, and the app shows no buttons and no place to type while it is off. Nothing is kept to
  send later: what can't go now is given up.
- **Terminals give nothing back.** A terminal on the device is drawn from the output of the session on the Mac.
  That output holds the questions a program asks its terminal, and the terminal on the device answers them, as
  any terminal would. Every answer is dropped on the device. So is anything else the terminal would send: taps on
  it are not passed on, and a program on the Mac cannot read or set the device's clipboard. What you type for a
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

- The session plugin is copied to Application Support at launch, where another program running as you could change it.
- A flow's regular-expression checks run as written. A pathological pattern can stall a run.
- A Remote connection is encrypted with a key both sides already hold, and that key is not replaced by a fresh one
  for each connection. So someone who recorded the Wi-Fi traffic while a device was being paired, and who also saw
  the code that pairing used, could work out that device's key and read what it is sent. The code is on screen for
  two minutes at most. Treat it like a password: don't share your screen or photograph it while it shows.
- Anyone holding a paired, unlocked iPad or iPhone can read everything that device is sent: instructions, messages
  between agents, and whatever is on each terminal. If "Can control" is on for it, they can also run your flows and
  type into your sessions. The app has no lock of its own. Remove the device in the Mac's settings if it is lost.
- Text a device sends for a session is entered there as one paste, with anything a terminal would act on taken out
  of it first. Keys are different: they are sent as they are, because Esc and Ctrl-C are what they are for.
- A build of the iPad and iPhone app from source in the Debug configuration, which is what Run in Xcode makes,
  includes launch arguments for tests that can point the app at a made-up Mac. In the Simulator that build also
  writes what it is showing to a file in the app's own folder, for the tests to read. None of this is in a Release
  build, and the file is never written on a real device.
