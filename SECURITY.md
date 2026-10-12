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
  It only runs a command you typed into its settings or allowed yourself on this Mac. A command written by the
  orchestrator, pasted in, or arriving in a flow file stops the run and asks you first. What you allowed is kept in
  the app's own settings, not in the flow file.
- **Approval cards hold a run, not the orchestrator.** A run stops at an Approval card until you answer. Only a
  reply to a message the run handed an agent is passed on, so an agent further along that finishes some other
  turn doesn't carry the run past the card. The orchestrator can still edit the flow, which includes taking an
  Approval card out.
- **End cards write files.** An End card can save the final answer to a file in the project folder, and the
  orchestrator can set that up without asking. A save can't leave the project folder, and it is refused inside
  `.git`, `.claude` and `.queenbee`, where a file could change what git, Claude Code or Queen Bee does next. Any
  other file in the project can be overwritten.
- **Schedules start runs with nobody watching.** A Start card can run on the clock or when a file in the project
  changes, while the app is open. A schedule only fires once you have set it or turned it on in this app, and only
  for the command you set it with, so one that arrives in a flow file stays off until you agree. If the orchestrator
  changes that command, or an agent's instructions, folder or permissions, the flow's schedules go off until you turn
  them on again. A copied Start card never brings its schedule with it. Other edits by the orchestrator leave a
  schedule on: a Prompt card added after Start, Start linked to a different agent, or a change inside a sub-flow.
  A flow file changed on disk while the app is closed is not compared with what you agreed to either.
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
- **Messages typed into a terminal are cleaned.** A hand-off the app types into an agent's terminal has its
  escape sequences and control characters removed first, so text one agent wrote can't press keys in another's
  session.
- **Updates are signed.** The app only installs an update signed with the project's update key. Releases are signed
  with a Developer ID but are not yet notarized by Apple. The terminal installer refuses an app that isn't signed
  with the project's Developer ID certificate, checked up to Apple's root.

## Known limits

- The session plugin is copied to Application Support at launch, where another program running as you could change it.
- A flow's regular-expression checks run as written. A pathological pattern can stall a run.
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
