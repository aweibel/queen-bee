#!/usr/bin/env python3
"""End-to-end checks of the built app, driven through its test harness.

Launches a separate test copy of Queen Bee (`--testing`, its own support folder, so a copy
you have open is left alone), opens a scratch project with one flow per scenario, runs real
Claude Code sessions on Haiku, and checks what the app did.

    ./scripts/build.sh && ./scripts/e2e.py            # every scenario
    ./scripts/e2e.py guard loop                        # some of them

Scenarios: guard, settings, remote, scroll, pan, fanout, switch, loop, exit, apifail, ask, gates, subflow, timed, deep, noclaude.
`mirror` is run only when named: it checks the copy of a terminal that a paired device is sent.
`mobile` is run only when named: it runs the iPad app in the iOS Simulator against the test copy. Build it
first with ./scripts/build-mobile.sh. Its screenshots go to the folder named by QB_E2E_SHOTS, or a new one.
`terminals` is run only when named: it checks the iPad app's terminals against output made up inside the app,
so it needs the Simulator and no Mac app or Claude Code session.
`panels` is run only when named: it checks the iPad app's panels against a run made up inside the app, the same way.
`typing` is run only when named: it checks the iPad app's message box and keys under a terminal, the same way.
`controls` is run only when named: it checks the iPad app's run bar and buttons against a Mac made up inside the app,
the same way.
"""
import atexit
import glob
import json
import math
import os
import plistlib
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Build/Products/Debug/QueenBee.app")
CHECK = os.path.join(ROOT, "build/Build/Products/Debug/qb-remote-check")
MOBILE_APP = os.path.join(ROOT, "build/Build/Products/Debug-iphonesimulator/QueenBeeMobile.app")
# Unix socket paths are capped at 104 bytes, so the test copy's support folder has to be short.
# Each run has its own, named for its process, so two runs at once leave each other alone.
SUPPORT_PREFIX = os.path.expanduser("~/Library/Application Support/QBTest-")
SUPPORT = SUPPORT_PREFIX + str(os.getpid())

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"  ({detail})" if detail and not ok else ""), flush=True)
    return ok


# ---- talking to the app ----

def call(support, flow_id, payload, timeout=320):
    body = json.dumps({"kind": "test", "session": f"{flow_id}/test", "payload": payload}).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(os.path.join(support, "qb.sock"))
        s.sendall(struct.pack(">I", len(body)) + body)
        need = struct.unpack(">I", read_exactly(s, 4))[0]
        return json.loads(read_exactly(s, need))


def read_exactly(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("the app closed the connection")
        buf += chunk
    return buf


class App:
    def __init__(self, project, support=SUPPORT, env=None):
        self.project = project
        self.support = support
        shutil.rmtree(support, ignore_errors=True)
        atexit.register(shutil.rmtree, support, ignore_errors=True)
        cmd = ["open", "-g", "-n", APP, "--env", f"QB_SUPPORT_DIR={support}"]
        for k, v in (env or {}).items():
            cmd += ["--env", f"{k}={v}"]
        # The defaults-style flag goes first: after a bare flag, macOS would read it as that flag's value.
        cmd += ["--args", "-ApplePersistenceIgnoreState", "YES", "--testing", "--open", project]
        subprocess.run(cmd, check=True)
        deadline = time.time() + 30
        self.pid = None
        while time.time() < deadline:
            mine = [p for p in pids() if uses(p, support)]
            if mine and os.path.exists(os.path.join(support, "qb.sock")):
                self.pid = mine[0]
                break
            time.sleep(0.3)
        if self.pid is None:
            raise RuntimeError("the test copy of the app didn't start")

    def op(self, flow_id, op, **kw):
        return call(self.support, flow_id, dict(op=op, **kw))

    def state(self, flow_id):
        return self.op(flow_id, "state")

    def wait(self, flow_id, cond, timeout, what):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = self.state(flow_id)
            if cond(last):
                return last
            time.sleep(1)
        raise TimeoutError(f"timed out after {timeout}s waiting for {what}; log tail: {last and last.get('log', [])[-6:]}; "
                           f"sessions: { {k: v['state'] for k, v in (last or {}).get('sessions', {}).items()} }")

    def open_flow(self, flow, timeout=150):
        """Puts a flow on screen and waits until every agent's session is ready for input."""
        fid = flow["id"]
        # The socket opens before the project window has loaded its flows, so ask until the flow is known.
        deadline = time.time() + 30
        while "sessions" not in self.state(fid):
            if time.time() > deadline:
                raise RuntimeError(f"the app never loaded the flow {flow['name']}")
            time.sleep(0.5)
        self.op(fid, "select")
        agents = [c["name"] for c in flow["cards"] if c["kind"] == "agent"]
        return self.wait(fid, lambda s: all(s["sessions"].get(a, {}).get("state") == "idle" for a in agents),
                         timeout, f"sessions of {flow['name']} to be idle")

    def quit(self):
        if self.pid:
            subprocess.run(["kill", "-TERM", str(self.pid)])
            for _ in range(40):
                if self.pid not in pids():
                    break
                time.sleep(0.25)


def pids():
    out = subprocess.run(["pgrep", "-x", "QueenBee"], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def uses(pid, support):
    """Whether a copy of the app was started on this support folder. Another run's copy never is."""
    out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return f"QB_SUPPORT_DIR={support} " in out + " "


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def sweep():
    """Clears up after runs that died without tidying: quits the copy of the app each left
    running and removes its folder. A run that is still going keeps its own."""
    for folder in glob.glob(SUPPORT_PREFIX + "*"):
        owner = os.path.basename(folder)[len("QBTest-"):].split("-")[0]
        if owner.isdigit() and not alive(int(owner)):
            for pid in pids():
                if uses(pid, folder):
                    subprocess.run(["kill", "-TERM", str(pid)])
            shutil.rmtree(folder, ignore_errors=True)


# ---- building flows ----

def card(kind, name, x, y, **settings):
    width, height = (480, 300) if kind == "agent" else (240, 120)
    c = {"id": name.lower().replace(" ", "").replace("?", "")[:8] + f"{abs(hash(name)) % 9000 + 1000}", "kind": kind, "name": name,
         "x": x, "y": y, "width": width, "height": height}
    if kind == "agent":
        settings.setdefault("model", "haiku")
    c.update(settings)
    return c


def flow(name, cards, links):
    ids = {c["name"]: c["id"] for c in cards}
    fid = "t" + name.lower()[:7].ljust(7, "0")
    return {"version": 1, "id": fid, "name": name, "notifyOrchestrator": False, "cards": cards,
            "links": [{"id": f"l{i}", "from": ids[a], "port": port, "to": ids[b], "maxPasses": passes}
                      for i, (a, port, b, passes) in enumerate(links)]}


def write(project, order, f):
    folder = os.path.join(project, ".queenbee", "flows")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, f"{order}-{f['name'].lower()}.json"), "w") as out:
        json.dump(f, out, indent=2)


SAY = "Whatever you are asked, reply with exactly this and nothing else: "

GUARD = flow("Guard", [
    card("agent", "Alice", 60, 60, instructions="You follow the person's requests exactly."),
    card("agent", "Bob", 600, 60, instructions="When another session messages you, reply with exactly: BOB-GOT-IT"),
    card("agent", "Carol", 1140, 60, instructions="When another session messages you, reply with exactly: CAROL-GOT-IT"),
], [("Alice", "out", "Bob", 3)])

WORDS = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF", "HOTEL"]
FANOUT = flow("Fanout",
              [card("start", "Start", 40, 40, command="Reply with your assigned word.")]
              + [card("agent", f"W{i + 1}", 340 + (i % 4) * 500, 40 + (i // 4) * 320, instructions=SAY + w) for i, w in enumerate(WORDS)]
              + [card("and", "Everyone", 340, 720), card("or", "Fastest", 340, 880),
                 card("end", "All", 660, 720), card("end", "First", 660, 880)],
              [("Start", "out", f"W{i + 1}", 3) for i in range(8)]
              + [(f"W{i + 1}", "out", "Everyone", 3) for i in range(8)]
              + [(f"W{i + 1}", "out", "Fastest", 3) for i in range(8)]
              + [("Everyone", "out", "All", 3), ("Fastest", "out", "First", 3)])

SWITCH = flow("Switch", [
    card("start", "Start", 40, 40, command="The login button crashes the app when I tap it twice."),
    card("switch", "Triage", 340, 40, branches=["bug", "feature"], height=160),
    card("agent", "BugFixer", 660, 40, instructions=SAY + "BUG-HANDLED"),
    card("agent", "Planner", 660, 380, instructions=SAY + "FEATURE-HANDLED"),
    card("end", "Out", 1220, 40),
], [("Start", "out", "Triage", 3), ("Triage", "bug", "BugFixer", 3), ("Triage", "feature", "Planner", 3),
    ("Triage", "other", "Out", 3), ("BugFixer", "out", "Out", 3), ("Planner", "out", "Out", 3)])

LOOP = flow("Loop", [
    card("start", "Start", 40, 40, command="Go"),
    card("agent", "Counter", 340, 40, instructions=(
        "You are a counter. Each message you get has a first line in square brackets, which you ignore. "
        "If the rest of the message is the word Go, reply with exactly: X. "
        "Otherwise the rest is a row of X characters: reply with that row plus one more X. Reply with nothing else.")),
    card("loop", "Enough?", 900, 40, check="contains", value="XXX", maxTries=5, height=140),
    card("end", "Out", 1220, 40),
], [("Start", "out", "Counter", 3), ("Counter", "out", "Enough?", 6), ("Enough?", "again", "Counter", 6), ("Enough?", "done", "Out", 3)])

EXIT = flow("Exit", [
    card("start", "Start", 40, 40, command="Run the shell command `sleep 45`, then reply with exactly: done"),
    card("agent", "Sleeper", 340, 40),
    card("end", "Out", 900, 40),
], [("Start", "out", "Sleeper", 3), ("Sleeper", "out", "Out", 3)])

APIFAIL = flow("Apifail", [
    card("start", "Start", 40, 40, command="Say hi"),
    card("agent", "Broken", 340, 40, model="claude-no-such-model-0"),
    card("end", "Out", 900, 40),
], [("Start", "out", "Broken", 3), ("Broken", "out", "Out", 3)])

# Far is well out of view of a window that shows Near.
PAN = flow("Pan", [card("start", "Near", 300, 200, command="Go"), card("end", "Far", 4000, 200)], [])

ASK = flow("Ask", [
    card("start", "Start", 40, 40, command="What is the password?"),
    card("agent", "Asker", 340, 40, instructions="You don't know the password. When a hand-off asks for it, use your SendMessage tool once to ask "
         "the session that runs this flow to send you a message containing only the word BANANA, then end your turn. "
         "When that message arrives, reply with exactly the word it contains and nothing else."),
    card("end", "Out", 900, 40),
], [("Start", "out", "Asker", 1), ("Asker", "out", "Out", 1)])

# No agents, so a device can start, hold up and stop runs of it at the cost of nothing but its orchestrator.
# The gates scenario has a flow of its own like it: a command allowed here stays allowed.
DOORS = flow("Doors", [
    card("start", "Start", 0, 0, command="hello from afar"),
    card("script", "Shout", 312, 0, command="tr a-z A-Z"),
    card("approval", "Check it", 624, 0, text="Is this loud enough?"),
    card("end", "Done", 936, 0),
    card("end", "Binned", 936, 192),
], [("Start", "out", "Shout", 9), ("Shout", "pass", "Check it", 9), ("Check it", "approved", "Done", 9),
    ("Check it", "rejected", "Binned", 9), ("Shout", "fail", "Binned", 9)])

FLOWS = {"doors": DOORS, "guard": GUARD, "pan": PAN, "fanout": FANOUT, "switch": SWITCH, "loop": LOOP, "exit": EXIT, "apifail": APIFAIL, "ask": ASK}


# ---- scenarios ----

def scenario_guard(app):
    print("guard: an agent may message a linked agent, not an unlinked one", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    app.op(fid, "type", card="Alice", text="Use your SendMessage tool to send the message ping to the session named Carol. "
                                           "Then tell me exactly what the tool returned, quoting it word for word.")
    s = app.wait(fid, lambda s: s["sessions"]["Alice"]["lastReply"] and s["sessions"]["Alice"]["state"] == "idle", 120, "Alice to answer")
    reply = s["sessions"]["Alice"]["lastReply"]
    check("the send to unlinked Carol was refused with the canvas's reason", "linked" in reply.lower(), reply[:300])
    time.sleep(4)
    s = app.state(fid)
    check("Carol received nothing", s["sessions"]["Carol"]["lastReply"] is None and s["sessions"]["Carol"]["state"] == "idle",
          str(s["sessions"]["Carol"]))
    app.op(fid, "type", card="Alice", text="Now send the message ping to the session named Bob the same way, and tell me what the tool returned.")
    try:
        s = app.wait(fid, lambda s: s["sessions"]["Alice"]["lastReply"] not in (None, reply) and s["sessions"]["Alice"]["state"] == "idle",
                     120, "Alice to answer the second request")
        second = s["sessions"]["Alice"]["lastReply"]
        try:
            s = app.wait(fid, lambda s: s["sessions"]["Bob"]["lastReply"], 60, "Bob to get Alice's message")
            check("the send to linked Bob went through", "BOB-GOT-IT" in s["sessions"]["Bob"]["lastReply"], s["sessions"]["Bob"]["lastReply"][:200])
        except TimeoutError:
            check("the send to linked Bob went through", False, "Bob never answered. Alice said: " + second[:500])
    except TimeoutError as e:
        check("the send to linked Bob went through", False, str(e)[:300])
    app.wait(fid, lambda s: s["orchestrator"]["state"] == "idle", 90, "the orchestrator to be ready")
    app.op(fid, "type", card="orchestrator", text="Use your SendMessage tool to send the message ping to the agent named Carol. Then tell me what the tool returned.")
    try:
        s = app.wait(fid, lambda s: s["sessions"]["Carol"]["lastReply"], 120, "Carol to get the orchestrator's message")
        check("the orchestrator can message any agent by its card name", "CAROL-GOT-IT" in s["sessions"]["Carol"]["lastReply"],
              s["sessions"]["Carol"]["lastReply"][:200])
    except TimeoutError:
        said = app.state(fid)["orchestrator"]["lastReply"] or ""
        check("the orchestrator can message any agent by its card name", False, "Carol never answered. The orchestrator said: " + said[:500])


def scenario_settings(app):
    print("settings: a changed card says it needs a restart, and Undo puts it back", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    before = app.state(fid)["sessions"]["Alice"]
    check("a freshly started session has nothing waiting", before["awaitingRestart"] == [], str(before["awaitingRestart"]))
    app.op(fid, "edit", card="Alice", instructions="Something else entirely.", model="sonnet", effort="high")
    changed = app.state(fid)["sessions"]["Alice"]
    check("changing settings lists what the session doesn't have yet",
          changed["awaitingRestart"] == ["instructions", "model", "effort"], str(changed["awaitingRestart"]))
    app.op(fid, "revert", card="Alice")
    after = app.state(fid)["sessions"]["Alice"]
    check("Undo clears the list", after["awaitingRestart"] == [], str(after["awaitingRestart"]))
    check("Undo restores the instructions, model and effort",
          (after["instructions"], after["model"], after["effort"]) == (before["instructions"], before["model"], before["effort"]),
          f"{after['instructions']!r} {after['model']} {after['effort']}")
    app.op(fid, "edit", card="Alice", effort="high")
    app.op(fid, "restart", card="Alice")
    s = app.wait(fid, lambda s: s["sessions"]["Alice"]["state"] == "idle", 90, "Alice to come back")
    check("after Restart to apply nothing is waiting", s["sessions"]["Alice"]["awaitingRestart"] == [], str(s["sessions"]["Alice"]["awaitingRestart"]))
    app.op(fid, "edit", card="Alice", effort="")


class Device:
    """The stand-in for a paired device: runs qb-remote-check and reads what it prints."""

    def __init__(self, *args):
        self.proc = subprocess.Popen([CHECK, *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.lines = queue.Queue()
        self.seen = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(json.loads(line))
        self.lines.put({"type": "exited"})

    def tell(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def until(self, wanted, timeout=20):
        """The next message that passes `wanted` (a type name or a test), or None. Earlier ones stay in `seen`."""
        test = wanted if callable(wanted) else (lambda m: m["type"] == wanted)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.lines.get(timeout=max(0.1, deadline - time.time()))
            except queue.Empty:
                return None
            self.seen.append(message)
            if test(message):
                return message
            if message["type"] == "exited":
                return None
        return None

    def saw(self, kind, timeout=10):
        """A message of that type, whether it has been read past already or is still to come."""
        return next((m for m in self.seen if m["type"] == kind), None) or self.until(kind, timeout)

    def stop(self):
        self.proc.kill()


def remote_control(app, device, device_id):
    """What a device may do to the Mac: nothing until "Can control" is on for it, and then only what the Mac's
    own buttons and keyboard do. The device has Guard open, with its agents idle."""
    guard, doors = GUARD["id"], DOORS["id"]
    alice = next(c["id"] for c in GUARD["cards"] if c["name"] == "Alice")
    gate = next(c["id"] for c in DOORS["cards"] if c["name"] == "Check it")
    sent = [0]

    def ask(do, flow=doors, **fields):
        """Sends one command and returns the Mac's answer to it."""
        sent[0] += 1
        n = sent[0]
        device.tell(json.dumps(dict(id=n, do=do, flow=flow, **fields)))
        return device.until(lambda m: m["type"] == "answer" and m["id"] == n, 30)

    def done(answer):
        return answer is not None and answer["refusal"] is None

    def refused(answer, words):
        return answer is not None and words in (answer["refusal"] or "")

    def since(mark, test, timeout=20):
        """A message that passes `test` among those read since `mark`, or the next one to come."""
        return next((m for m in device.seen[mark:] if test(m)), None) or device.until(test, timeout)

    def screen():
        return "\n".join(app.op(guard, "terminal", card="Alice")["screen"])

    def mac():
        """Everything a command could change on the Mac."""
        d, g = app.state(doors), app.state(guard)
        return ({k: d[k] for k in ("isRunning", "log", "runs", "holds", "results", "sessions", "orchestrator", "marks")},
                {k: g[k] for k in ("isRunning", "log", "runs", "sessions")}, app.op("app", "remote-state")["selected"])

    every = [("openOnMac", {}), ("run", {}), ("run", {"text": "typed on the device"}), ("runFrom", {"card": gate, "text": "straight to the gate"}),
             ("stop", {}), ("approve", {"hold": "none", "text": "yes"}), ("reject", {"hold": "none", "text": "no"}),
             ("allowScript", {"hold": "none"}), ("refuseScript", {"hold": "none"}), ("startSession", {"flow": guard, "card": alice}),
             ("prompt", {"flow": guard, "key": alice, "text": "Reply with exactly the word REFUSED and nothing else."}),
             ("prompt", {"flow": guard, "key": "orchestrator", "text": "Reply with exactly the word REFUSED and nothing else."}),
             ("keys", {"flow": guard, "key": alice, "hex": "zzqq".encode().hex()})]

    check("pairing leaves a device able to watch and nothing more", app.op("app", "remote-state")["controlling"] == 0)
    before = mac()
    answers = [(do, ask(do, **fields)) for do, fields in every]
    unrefused = [do for do, answer in answers if not refused(answer, "can only watch")]
    check("a device that may only watch has every kind of command refused, and is told how to change that",
          not unrefused and all("Can control" in a["refusal"] for _, a in answers), str(unrefused or answers[:2]))
    time.sleep(3)
    check("and nothing happens on the Mac", mac() == before and "zzqq" not in screen(),
          str([(a, b) for a, b in zip(mac(), before) if a != b])[:600])

    app.op("app", "remote-control", device=device_id, on=True)
    told = device.until("control", 10)
    check("turning “Can control” on tells a connected device at once", told is not None and told["canControl"] is True, str(device.seen[-3:]))
    with open(os.path.join(app.support, "remote-devices.json")) as saved:
        kept = [d["canControl"] for d in json.load(saved)["devices"]]
    check("and it is kept, in the file the devices are saved in", app.op("app", "remote-state")["controlling"] == 1 and kept == [True], str(kept))

    # Doors has never been on screen on the Mac, so none of its sessions have started.
    device.tell(f"open {doors}")
    opened = device.until(lambda m: m["type"] == "opened" and m["name"] == "Doors")
    check("the device opens a flow whose sessions haven't started",
          opened is not None and all(v == "notStarted" for v in opened["sessions"].values()) and opened["cardIDs"].get("Check it") == gate,
          str(opened))
    mark = len(device.seen)
    check("it can ask the Mac to start them", done(ask("openOnMac")), str(device.seen[-3:]))
    started = since(mark, lambda m: m["type"] == "run" and m["flow"] == doors
                    and m["sessions"].get("orchestrator", "notStarted") != "notStarted", 60)
    check("and they start", started is not None, str(device.seen[-4:]))
    check("while the Mac goes on showing the flow it was showing", app.op("app", "remote-state")["selected"] == guard)

    def hold_of(kind, mark):
        """The id of the message held at a card of that kind, as the device is told of it."""
        update = since(mark, lambda m: m["type"] == "run" and m["flow"] == doors and m["holds"] and m["holds"][0]["kind"] == kind)
        return update and update["holds"][0]

    mark = len(device.seen)
    check("it can start a run", done(ask("run")), str(device.seen[-3:]))
    script = hold_of("script", mark)
    s = app.state(doors)
    check("and the run starts on the Mac, and stops at the script's command as it would there",
          s["isRunning"] and script is not None and script["needsAllow"], f"{s['isRunning']} {script}")
    check("and the Mac's log says which device started it", "Run started from Test device" in s["log"], str(s["log"]))
    check("a second run is refused in the Mac's words while one is going", refused(ask("run"), "already going"), str(device.seen[-2:]))
    check("an approval can't be given to a script's command", refused(ask("approve", hold=script["id"], text="yes"), "no longer waiting"),
          str(device.seen[-2:]))
    mark = len(device.seen)
    check("it can allow a script's command", done(ask("allowScript", hold=script["id"])), str(device.seen[-3:]))
    approval = hold_of("approval", mark)
    h = held(app, doors, "Check it")
    check("and the command runs", approval is not None and h[0]["text"] == "HELLO FROM AFAR", f"{approval} {h}")
    check("it can reject a held message with a note", done(ask("reject", hold=approval["id"], text="Too loud")), str(device.seen[-3:]))
    s = app.wait(doors, lambda s: not s["isRunning"], 20, "the rejected run to end")
    binned = s["results"].get("Binned", "")
    check("and the note goes out ahead of the message", list(s["results"]) == ["Binned"] and binned.startswith("Too loud\n"), str(s["results"]))
    check("an answer to a message that is no longer held is refused",
          refused(ask("approve", hold=approval["id"], text="late"), "no longer waiting"), str(device.seen[-2:]))

    mark = len(device.seen)
    check("it can run the flow again", done(ask("run")), str(device.seen[-3:]))
    approval = hold_of("approval", mark)
    h = held(app, doors, "Check it")
    check("a command allowed from a device stays allowed, as one allowed on the Mac does",
          approval is not None and not h[0]["needsAllow"] and h[0]["card"] == "Check it", f"{approval} {h}")
    check("it can approve a held message, edited", done(ask("approve", hold=approval["id"], text="EDITED FROM AFAR")), str(device.seen[-3:]))
    s = app.wait(doors, lambda s: not s["isRunning"], 20, "the approved run to end")
    check("and the edited message goes on", s["results"] == {"Done": "EDITED FROM AFAR"}, str(s["results"]))

    check("it can start a run at a card", done(ask("runFrom", card=gate, text="straight to the gate")), str(device.seen[-3:]))
    h = held(app, doors, "Check it")
    check("and the message arrives there", h[0]["text"] == "straight to the gate", str(h))
    check("it can stop a run", done(ask("stop")), str(device.seen[-3:]))
    s = app.wait(doors, lambda s: not s["isRunning"], 20, "the run to stop")
    check("and the run stops", not s["holds"] and s["runs"][-1]["outcome"] == "stopped", f"{s['holds']} {s['runs'][-1]}")
    check("and the Mac's log says which device stopped it", "Stopped from Test device" in s["log"], str(s["log"][-4:]))
    check("stopping when nothing runs is refused", refused(ask("stop"), "No run is going"), str(device.seen[-2:]))

    was = app.state(guard)["sessions"]["Alice"]["lastReply"]
    check("it can send an agent a message", done(ask("prompt", flow=guard, key=alice, text="Reply with exactly the word PINEAPPLE and nothing else.")),
          str(device.seen[-3:]))
    try:
        s = app.wait(guard, lambda s: s["sessions"]["Alice"]["lastReply"] not in (None, was) and s["sessions"]["Alice"]["state"] == "idle",
                     120, "Alice to answer the device")
        check("and the agent replies", "PINEAPPLE" in s["sessions"]["Alice"]["lastReply"], s["sessions"]["Alice"]["lastReply"][:200])
    except TimeoutError as e:
        check("and the agent replies", False, str(e)[:300])
    check("and the Mac's log says which device sent it", "Test device sent a message to Alice" in app.state(guard)["log"], str(app.state(guard)["log"][-4:]))

    check("it can press keys in a session's terminal", done(ask("keys", flow=guard, key=alice, hex="qbkeys".encode().hex())), str(device.seen[-3:]))
    deadline = time.time() + 10
    while "qbkeys" not in screen() and time.time() < deadline:
        time.sleep(0.3)
    check("and they are typed there", "qbkeys" in screen(), screen()[-400:])
    # Ctrl-U empties the line, so nothing typed here is ever sent to the agent.
    ask("keys", flow=guard, key=alice, hex="15")
    deadline = time.time() + 10
    while "qbkeys" in screen() and time.time() < deadline:
        time.sleep(0.3)
    s = app.state(guard)["sessions"]["Alice"]
    check("and a control key does what it does on the Mac", "qbkeys" not in screen() and s["state"] == "idle", f"{s['state']} {screen()[-300:]}")

    # The orchestrator the device started may still be starting, and that would show as a change.
    app.wait(doors, lambda s: s["orchestrator"]["state"] == "idle", 90, "Doors' orchestrator to be ready")
    quiet = mac()
    check("a message longer than a device may send is refused",
          refused(ask("prompt", flow=guard, key=alice, text="a" * 16001), "too long"), str(device.seen[-1:])[:300])
    check("and so are too many keys at once", refused(ask("keys", flow=guard, key=alice, hex="61" * 4097), "too much"), str(device.seen[-1:])[:300])
    check("and a message that says nothing", refused(ask("prompt", flow=guard, key=alice, text="  "), "nothing to send"), str(device.seen[-1:]))
    check("a command for a flow the Mac doesn't have is refused", refused(ask("stop", flow="tnowhere"), "no longer on your Mac"), str(device.seen[-1:]))
    check("and for a card the flow doesn't have", refused(ask("startSession", card="nocard"), "no longer in the flow"), str(device.seen[-1:]))
    check("and for a card that isn't an agent", refused(ask("startSession", card=gate), "Only an agent"), str(device.seen[-1:]))
    check("and for a session that isn't running", refused(ask("prompt", key=gate, text="hello"), "isn't running")
          and refused(ask("keys", key="nocard", hex="61"), "isn't running"), str(device.seen[-2:]))
    check("and none of those does anything on the Mac", mac() == quiet, str([(a, b) for a, b in zip(mac(), quiet) if a != b])[:600])

    app.op("app", "remote-control", device=device_id, on=False)
    told = device.until("control", 10)
    check("turning “Can control” off tells a connected device at once", told is not None and told["canControl"] is False, str(device.seen[-3:]))
    check("and its next command is refused", refused(ask("run"), "can only watch"), str(device.seen[-2:]))
    time.sleep(1)
    check("and does nothing", mac() == quiet)
    app.op(doors, "close")


def scenario_remote(app):
    print("remote: a paired device gets the flow, its changes and its terminals, and nobody else gets anything", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    if app.op("app", "remote-state")["on"] is False:
        check("nothing is put on offer while Remote is off", "error" in app.op("app", "remote-pair"))
    check("Remote turns on", app.op("app", "remote-on").get("on") is True)
    offer = app.op("app", "remote-pair")
    check("pairing puts a one-time code on offer", str(offer.get("code", "")).startswith("queenbee-pair:1:"), str(offer.keys()))

    device = Device("--code", offer["code"], "--pair-port", str(int(offer["port"])), "--flow", fid, "--seconds", "600")
    try:
        paired = device.until("paired")
        check("the device pairs", paired is not None, str(device.seen))
        check("the code is put away once it has been used", app.op("app", "remote-state")["pairing"] is False)
        # The stand-in gives its id in capitals, as an iPad does, and says hello with it that way.
        check("the Mac keeps the device's id in lower case and tells it so", paired["device"] == paired["device"].lower(), str(paired))
        port = int(app.op("app", "remote-port", device=paired["device"])["port"])
        device.tell(str(port))

        welcome = device.until("welcome")
        check("a paired device is let in, to watch only", welcome is not None and welcome["canControl"] is False, str(device.seen))
        library = device.until("library")
        check("it is sent the flow list", library is not None and "Guard" in library["flows"], str(library))
        opened = device.until("opened")
        check("it is sent the flow it opened", opened is not None and opened["name"] == "Guard" and opened["cards"] == 3, str(opened))
        check("with each session's state", opened is not None and "orchestrator" in opened["sessions"], str(opened))
        wanted = set(opened["sessions"]) if opened else set()
        screens = set()
        while wanted - screens:
            screen = device.until(lambda m: m["type"] == "terminal" and m["reset"] and m["bytes"] > 0)
            if screen is None:
                break
            screens.add(screen["key"])
        check("and every terminal's screen as it is now", len(wanted) >= 2 and wanted <= screens,
              f"wanted {sorted(wanted)}, got {sorted(screens)}")

        app.op(fid, "edit", card="Alice", effort="high")
        changed = device.until(lambda m: m["type"] == "flow" and "high" in m["efforts"])
        check("a change on the Mac reaches the device", changed is not None and changed["revision"] >= 1, str(device.seen[-4:]))
        app.op(fid, "edit", card="Alice", effort="")
        check("and so does changing it back", device.until(lambda m: m["type"] == "flow" and "high" not in m["efforts"]) is not None)

        # Pan has not been on screen on the Mac, so it has no sessions yet. It has no agents, so opening it
        # there starts only its orchestrator.
        other = PAN["id"]
        device.tell(f"open {other}")
        unopened = device.until(lambda m: m["type"] == "opened" and m["name"] == "Pan")
        check("it can open a flow the Mac hasn't opened, whose sessions haven't started",
              unopened is not None and all(v == "notStarted" for v in unopened["sessions"].values()), str(unopened))
        app.op(other, "select")
        started = device.until(lambda m: m["type"] == "run" and m["flow"] == other
                               and m["sessions"].get("orchestrator", "notStarted") != "notStarted", 60)
        check("and is told when the Mac opens that flow and its sessions start", started is not None, str(device.seen[-4:]))
        check("and is sent the new session's screen",
              device.until(lambda m: m["type"] == "terminal" and m["key"] == "orchestrator" and m["reset"], 30) is not None)
        app.op(fid, "select")
        app.op(other, "close")
        device.tell(f"open {fid}")
        check("and can go back to the first flow", device.until(lambda m: m["type"] == "opened" and m["name"] == "Guard") is not None)

        remote_control(app, device, paired["device"])

        again = Device("--code", offer["code"], "--pair-port", str(int(offer["port"])), "--flow", fid)
        check("a used code pairs nothing", again.until(lambda m: m["type"] in ("pair-failed", "pair-refused"), 10) is not None, str(again.seen))
        again.stop()
        check("and it paired nothing", app.op("app", "remote-state")["devices"] == 1)

        app.op("app", "remote-vault", fails=True)
        second = app.op("app", "remote-pair")
        unlucky = Device("--code", second["code"], "--pair-port", str(int(second["port"])), "--flow", fid)
        refused = unlucky.until("pair-refused", 10)
        unlucky.stop()
        app.op("app", "remote-vault", fails=False)
        check("a device whose key can't be kept is told so", refused is not None and "couldn't save" in refused["reason"], str(unlucky.seen))
        state = app.op("app", "remote-state")
        check("and isn't listed, and the Mac says why", state["devices"] == 1 and "Keychain" in (state["problem"] or ""), str(state))

        stranger = Device("--port", str(port), "--device", paired["device"], "--wrong-key")
        kept_out = stranger.until("kept-out", 10)
        # Turned down by the listener itself: giving up on a port nothing answers would prove nothing.
        check("a device without the key is kept out", kept_out is not None and "timed out" not in kept_out["error"], str(stranger.seen))
        stranger.stop()
        device.tell("stranger")
        told = device.until("stranger-refused", 10)
        check("a device that has the key and gives another id is told it isn't paired",
              told is not None and "no longer paired" in told["reason"], str(device.seen[-3:]))
        check("and the paired device is still connected, alone", app.op("app", "remote-state")["connected"] == 1)

        device.tell("reconnect")
        check("a device that connects again takes over from its old connection",
              device.until("reconnected", 10) is not None and device.until("welcome", 10) is not None, str(device.seen[-4:]))
        check("and is connected once, not twice", app.op("app", "remote-state")["connected"] == 1)

        device.tell("silent")
        check("a connection can be open without having said hello", device.until("silent-open", 10) is not None, str(device.seen[-3:]))
        app.op("app", "remote-remove", device=paired["device"])
        check("removing a device ends its connection", device.until("ended", 10) is not None, str(device.seen[-3:]))
        check("and the one that never said hello", device.saw("silent-ended", 5) is not None, str(device.seen[-3:]))
        state = app.op("app", "remote-state")
        check("and forgets it", state["devices"] == 0 and state["connected"] == 0, str(state))
        late = Device("--port", str(port), "--device", paired["device"], "--wrong-key")
        gone = late.until("kept-out", 10)
        # A key being turned down would mean something still listens. Only the connection itself failing
        # shows that nothing does, and that is seen from here, not taken from what the app says.
        check("and nothing listens where it used to connect",
              gone is not None and "refused" in gone["error"].lower() and kept_out is not None and gone["error"] != kept_out["error"],
              f"{late.seen} against {kept_out}")
        check("and the app agrees", state["listening"] == 0, str(state))
        late.stop()
    finally:
        device.stop()


def simctl(*args, timeout=180):
    return subprocess.run(["xcrun", "simctl", *args], capture_output=True, text=True, timeout=timeout)


def simulator():
    """The id of a running Simulator the iPad app can run in, booting one if none is. None if this Mac has none.
    QB_E2E_SIMULATOR names the one to use, as in "iPad Pro 11-inch (M5)"."""
    try:
        listing = json.loads(simctl("list", "devices", "available", "-j").stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    devices = []
    for runtime, found in listing.get("devices", {}).items():
        # The runtime's name ends "iOS-26-0". The app needs iOS 26 or later.
        parts = runtime.rsplit(".", 1)[-1].split("-")
        if parts[0] == "iOS" and parts[1].isdigit() and int(parts[1]) >= 26:
            devices += found
    named = os.environ.get("QB_E2E_SIMULATOR")
    if named:
        devices = [d for d in devices if d["name"] == named]
    devices.sort(key=lambda d: (d["state"] != "Booted", "iPad" not in d["name"]))
    if not devices:
        return None
    if devices[0]["state"] != "Booted":
        simctl("boot", devices[0]["udid"])
        simctl("bootstatus", devices[0]["udid"], "-b", timeout=300)
    return devices[0]["udid"]


def free_port():
    """A port nothing is listening on. The app has to be told its ports before the listeners exist."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Mobile:
    """The iPad app in a Simulator. It can't be asked anything, so it writes its state to a file that is read here."""

    def __init__(self, udid):
        self.udid = udid
        # Read from the app as it was built: the project's own id, or the one Local.xcconfig gives it on a
        # machine set up to install the app on a real device.
        with open(os.path.join(MOBILE_APP, "Info.plist"), "rb") as f:
            self.id = plistlib.load(f)["CFBundleIdentifier"]
        self.shots = os.environ.get("QB_E2E_SHOTS") or tempfile.mkdtemp(prefix="qb-shots-")
        os.makedirs(self.shots, exist_ok=True)
        # A copy left by an earlier run would still be paired with a Mac that is gone.
        simctl("uninstall", udid, self.id)
        installed = simctl("install", udid, MOBILE_APP)
        if installed.returncode != 0:
            raise RuntimeError("the iPad app couldn't be installed: " + installed.stderr.strip()[:300])

    def _state_file(self):
        folder = simctl("get_app_container", self.udid, self.id, "data").stdout.strip()
        return os.path.join(folder, "Library/Caches/qb-state.json")

    def launch(self, *args):
        """Starts the app afresh. What the last run wrote is thrown away first, so it can't be read as this run's."""
        self.quit()
        try:
            os.remove(self._state_file())
        except OSError:
            pass
        for left in glob.glob(os.path.join(os.path.dirname(self._state_file()), "qb-wait-*")):
            os.remove(left)
        started = simctl("launch", self.udid, self.id, *args)
        if started.returncode != 0:
            raise RuntimeError("the iPad app couldn't be launched: " + started.stderr.strip()[:300])

    def quit(self):
        simctl("terminate", self.udid, self.id)

    def go(self, name):
        """Lets the app past the step `wait:<name>` it was launched with."""
        with open(os.path.join(os.path.dirname(self._state_file()), "qb-wait-" + name), "w"):
            pass

    def state(self):
        try:
            with open(self._state_file()) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def wait(self, cond, timeout, what):
        """What the app says once `cond` is true of it, or what it last said if that never happens."""
        deadline = time.time() + timeout
        last = {}
        while time.time() < deadline:
            last = self.state()
            if last and cond(last):
                return last
            time.sleep(0.5)
        print(f"        (timed out after {timeout}s waiting for {what})", flush=True)
        return last

    def shot(self, name):
        # A moment for the screen to settle: the state is written before the view has finished changing.
        time.sleep(1.5)
        path = os.path.join(self.shots, name + ".png")
        simctl("io", self.udid, "screenshot", path)
        return path

    def appearance(self, mode):
        """Turns the whole Simulator light or dark. The app follows without being launched again."""
        simctl("ui", self.udid, "appearance", mode)


def count_to(app, fid, name, first, last):
    """Has an agent print a long reply: a number a line, with no tools. Returns how long it took."""
    before = app.state(fid)["sessions"][name]["lastReply"]
    started = time.time()
    app.op(fid, "type", card=name, text=f"Print the numbers {first} to {last}, one per line, as plain text. Do not use any tools and add nothing else.")
    app.wait(fid, lambda s: s["sessions"][name]["lastReply"] not in (None, before) and s["sessions"][name]["state"] == "idle",
             180, f"{name} to count to {last}")
    return time.time() - started


def inside(inner, outer, slack=1.0):
    """Whether one rectangle on screen lies within another, give or take a point."""
    return (inner["x"] >= outer["x"] - slack and inner["y"] >= outer["y"] - slack
            and inner["x"] + inner["width"] <= outer["x"] + outer["width"] + slack
            and inner["y"] + inner["height"] <= outer["y"] + outer["height"] + slack)


def shown_card(state, name):
    return next((c for c in (state.get("canvas") or {}).get("cards", []) if c["name"] == name), {})


def scenario_mobile(app):
    print("mobile: the iPad app pairs with the Mac, connects, comes back by itself, and learns when it is removed", flush=True)
    if not os.path.exists(MOBILE_APP):
        print("  SKIP  the iPad app isn't built. Build it first: ./scripts/build-mobile.sh", flush=True)
        return
    udid = simulator()
    if udid is None:
        print("  SKIP  this Mac has no iOS 26 Simulator to run the iPad app in", flush=True)
        return
    app.open_flow(GUARD)
    # Printed before the app has ever connected, so the app can only have it from the Mac's kept output.
    count_to(app, GUARD["id"], "Alice", 1, 120)
    mobile = Mobile(udid)
    print(f"        screenshots: {mobile.shots}", flush=True)

    def remote(cond, timeout, what):
        deadline = time.time() + timeout
        while True:
            state = app.op("app", "remote-state")
            if cond(state) or time.time() > deadline:
                return state
            time.sleep(0.5)

    try:
        mobile.launch()
        first = mobile.wait(lambda s: s["state"] == "unpaired", 30, "the app to start")
        check("a new copy of the app starts with no Mac and no key", first.get("state") == "unpaired" and first.get("hasKey") is False, str(first))
        mobile.shot("mobile-1-first-run")
        mobile.launch("-qbShow", "macs")
        mobile.wait(lambda s: s["state"] == "unpaired", 30, "the app to start")
        mobile.shot("mobile-2-choose-mac")
        mobile.launch("-qbShow", "code")
        mobile.wait(lambda s: s["state"] == "unpaired", 30, "the app to start")
        mobile.shot("mobile-3-paste-code")

        check("Remote turns on", app.op("app", "remote-on").get("on") is True)
        pair_port, device_port = free_port(), free_port()
        offer = app.op("app", "remote-pair", pairPort=pair_port, devicePort=device_port)
        check("the Mac offers to pair on the port it was asked to", int(offer.get("port", 0)) == pair_port, str(offer.keys()))
        mobile.launch("-qbHost", "127.0.0.1", "-qbPairPort", str(pair_port), "-qbPairCode", offer["code"], "-qbDevicePort", str(device_port))
        s = mobile.wait(lambda s: s["state"] == "connected" and s["flows"], 40, "the app to pair and connect")
        check("the app pairs and connects", s.get("state") == "connected", str(s))
        device = s.get("device", "")
        state = remote(lambda r: r["connected"] == 1, 10, "the Mac to see the device")
        check("the Mac lists one device, connected", state["devices"] == 1 and state["connected"] == 1 and state["pairing"] is False, str(state))
        check("the Mac listens for it on the port it was asked to", int(app.op("app", "remote-port", device=device).get("port", 0)) == device_port)
        check("the app is sent the flow list", "Guard" in s.get("flows", []), str(s))
        check("the app kept the Mac's name and its own key", bool(s.get("mac")) and s.get("hasKey") is True, str(s))
        mobile.launch("-qbOpen", "Guard")
        s = mobile.wait(lambda s: s.get("openFlow") == "Guard" and s.get("openFlowCards"), 40, "the app to open the flow")
        check("told to open a flow by name, the app opens it and is sent its cards",
              s.get("openFlow") == "Guard" and s.get("openFlowCards") == len(GUARD["cards"]), str(s))
        state = remote(lambda r: r.get("open") == ["Guard"], 10, "the Mac to see the flow opened")
        check("the Mac saw the device open it", state.get("open") == ["Guard"], str(state))
        mobile.shot("mobile-4-connected")

        def frames(state):
            return {c["name"]: (c["x"], c["y"], c["width"], c["height"]) for c in (state.get("canvas") or {}).get("cards", [])}

        def drawn(state):
            return (state.get("canvas") or {}).get("flow") == GUARD["id"] and len(frames(state)) == len(GUARD["cards"])

        in_file = {c["name"]: (c["x"], c["y"], c["width"], c["height"]) for c in GUARD["cards"]}
        s = mobile.wait(drawn, 20, "the canvas to draw the flow")
        canvas = s.get("canvas") or {}
        check("the canvas draws every card where the flow file puts it, at its size", frames(s) == in_file, str(frames(s)))
        check("and every link", canvas.get("links") == len(GUARD["links"]), str(canvas.get("links")))
        check("the surface is the size of the Mac's", canvas.get("contentSize") == {"width": 14000, "height": 11000}, str(canvas.get("contentSize")))
        clear = canvas.get("clear") or {"x": 0, "y": 0, "width": 0, "height": 0}
        whole = all(clear["x"] <= x and x + w <= clear["x"] + clear["width"] and clear["y"] <= y and y + h <= clear["y"] + clear["height"]
                    for x, y, w, h in in_file.values())
        check("a newly opened flow starts fitted, whole and clear of the panels", canvas.get("fitted") is True and whole, f"{clear} {canvas.get('zoom')}")
        check("no further in than the Mac's own size", 0.05 <= canvas.get("zoom", 0) <= 1, str(canvas.get("zoom")))
        s = mobile.wait(lambda s: drawn(s) and all("idle" in c["badges"] for c in s["canvas"]["cards"]), 10, "the cards to say their sessions are idle")
        check("each agent's card says what its session is doing", all("idle" in c["badges"] for c in s.get("canvas", {}).get("cards", [])),
              str([c["badges"] for c in s.get("canvas", {}).get("cards", [])]))
        check("and has a place for its terminal", all(c["hasTerminalPlace"] for c in s.get("canvas", {}).get("cards", [])))

        alice = next(c["id"] for c in GUARD["cards"] if c["name"] == "Alice")

        def same_terminal(what, also=lambda real, shown: True):
            """Checks the app's terminal for Alice against the Mac's own, once both have stopped changing."""
            deadline = time.time() + 20
            while True:
                real = app.op(GUARD["id"], "terminal", card="Alice")
                state = mobile.state()
                shown = (state.get("terminals") or {}).get(alice) or {}
                ok = (real.get("screen") == shown.get("screen") and (real.get("cols"), real.get("rows")) == (shown.get("cols"), shown.get("rows"))
                      and real.get("cursor") == shown.get("cursor") and also(real, shown))
                if ok or time.time() > deadline:
                    break
                time.sleep(0.5)
            rows = [i for i, (a, b) in enumerate(zip(real.get("screen", []), shown.get("screen", []))) if a != b]
            detail = f"Mac {real.get('cols')}x{real.get('rows')} cursor {real.get('cursor')}, app {shown.get('cols')}x{shown.get('rows')} cursor {shown.get('cursor')}"
            if rows:
                detail += f", {len(rows)} rows differ, first is row {rows[0]}: {real['screen'][rows[0]]!r} against {shown['screen'][rows[0]]!r}"
            check(what, ok, detail)
            return real, shown, state

        def said(screen, number):
            return any(row.strip() == str(number) for row in screen)

        real, shown, s = same_terminal("the app shows Alice's terminal as the Mac does, at the Mac's columns and rows",
                                       also=lambda real, shown: said(shown.get("screen", []), 120))
        check("with what she printed before the app connected", said(shown.get("screen", []), 120), str(shown.get("screen", [])[-6:]))
        check("and the output before that to scroll back through", shown.get("scrollback", 0) > 0 and shown.get("scrollback") == real.get("scrollback"),
              f"Mac {real.get('scrollback')} lines, app {shown.get('scrollback')}")
        place = shown_card(s, "Alice").get("terminalPlace") or {}
        check("the terminal is in her card, inside the place for it",
              shown_card(s, "Alice").get("hasTerminal") is True and shown.get("shown") is True and bool(place) and inside(shown.get("onScreen", {}), place),
              f"{shown.get('onScreen')} in {place}")
        print(f"        Alice's terminal is {shown.get('cols')}x{shown.get('rows')}, drawn at {shown.get('scale', 0):.3f} of the Mac's size; "
              f"a character here is {shown.get('cell')}", flush=True)
        heard = app.op("app", "remote-state").get("received")
        count_to(app, GUARD["id"], "Alice", 121, 240)
        real, shown, s = same_terminal("it still shows the same after a long reply printed while the app watched",
                                       also=lambda real, shown: said(shown.get("screen", []), 240))
        check("with the end of that reply on it", said(shown.get("screen", []), 240), str(shown.get("screen", [])[-6:]))
        check("and the same earlier output as the Mac", shown.get("scrollback", 0) > 0 and shown.get("scrollback") == real.get("scrollback"),
              f"Mac {real.get('scrollback')} lines, app {shown.get('scrollback')}")
        every = (s.get("terminals") or {}).values()
        check("the questions the programs asked their terminals were answered to nobody", sum(t["droppedReplies"] for t in every) > 0
              and not any(t["isFirstResponder"] for t in every), str({k: t["droppedReplies"] for k, t in (s.get("terminals") or {}).items()}))
        check("and the app sent the Mac nothing for any of it", app.op("app", "remote-state").get("received") == heard,
              f"{heard} messages before, {app.op('app', 'remote-state').get('received')} after")
        check("the session that runs the flow has a terminal too", "orchestrator" in (s.get("terminals") or {}), str(list((s.get("terminals") or {}).keys())))

        # Launched again, the app is sent every screen afresh: the terminals start from nothing and end up the same.
        mobile.launch("-qbOpen", "Guard", "-qbZoomCard", "Alice")
        mobile.wait(lambda s: shown_card(s, "Alice").get("hasTerminal"), 40, "the app to connect again and show the terminal")
        same_terminal("launched again, the terminal is rebuilt from what the Mac sends and shows the same")
        mobile.shot("mobile-4c-terminal-in-card")
        mobile.appearance("dark")
        mobile.shot("mobile-4d-terminal-in-card-dark")
        mobile.launch("-qbOpen", "Guard", "-qbZoomCard", "Alice", "-qbZoom", "1.4")
        mobile.wait(lambda s: shown_card(s, "Alice").get("hasTerminal") and (s.get("canvas") or {}).get("zoom", 0) > 1.3, 40, "the app to show the terminal zoomed in")
        mobile.shot("mobile-4e-terminal-zoomed-in-dark")
        mobile.appearance("light")
        mobile.shot("mobile-4f-terminal-zoomed-in")
        mobile.launch("-qbOpen", "Guard", "-qbExpand", "Alice")
        s = mobile.wait(lambda s: s.get("expanded") == alice and ((s.get("terminals") or {}).get(alice) or {}).get("shown"), 40, "the terminal to open full screen")
        check("a terminal opens full screen", s.get("expanded") == alice, str(s.get("expanded")))
        real, shown, s = same_terminal("and shows the same there")
        check("at a size that can be read", shown.get("onScreen", {}).get("width", 0) >= shown.get("natural", {}).get("width", 1) - 1,
              f"{shown.get('onScreen')} for {shown.get('natural')}")
        mobile.shot("mobile-4g-terminal-full-screen")
        mobile.launch("-qbOpen", "Guard", "-qbShow", "orchestrator")
        s = mobile.wait(lambda s: ((s.get("terminals") or {}).get("orchestrator") or {}).get("shown") and drawn(s), 40, "the orchestrator's terminal to show")
        check("the terminal of the session that runs the flow is in the panel beside the canvas",
              ((s.get("terminals") or {}).get("orchestrator") or {}).get("shown") is True, str((s.get("terminals") or {}).get("orchestrator", {}).get("shown")))
        mobile.shot("mobile-4h-orchestrator-terminal")
        app.op(GUARD["id"], "drag", card="Carol", dx=48, dy=72)
        moved_at = time.time()
        there = dict(in_file, Carol=(in_file["Carol"][0] + 48, in_file["Carol"][1] + 72) + in_file["Carol"][2:])
        s = mobile.wait(lambda s: frames(s) == there, 10, "the card to move on the canvas")
        check("a card moved on the Mac moves on the canvas, and only that card", frames(s) == there, str(frames(s)))
        check("within a couple of seconds", time.time() - moved_at < 2.5, f"{time.time() - moved_at:.1f}s")
        app.op(GUARD["id"], "undo")
        s = mobile.wait(lambda s: frames(s) == in_file, 10, "the card to go back")
        check("and goes back when the move is undone", frames(s) == in_file, str(frames(s)))

        # A run with no agents in it, so the one session it needs is the flow's own.
        gid = GATES["id"]

        shown = shown_card

        app.op(gid, "select")
        mobile.launch("-qbOpen", "Gates")
        s = mobile.wait(lambda s: (s.get("canvas") or {}).get("flow") == gid and len(frames(s)) == len(GATES["cards"]), 40, "the canvas to draw another flow")

        def panel(state):
            return state.get("panel") or {}

        def needing(state):
            return [c["name"] for c in panel(state).get("needsYou", [])]

        check("with nothing waiting, the app lists no card as needing you", needing(s) == [], str(needing(s)))

        # From here the device drives the Mac: the same presses its buttons make, refused until the Mac allows them.
        def controls(state):
            return state.get("controls") or {}

        def did(state):
            return [(d["step"], d["refusal"]) for d in controls(state).get("done", [])]

        def press(steps, *args, also=lambda s: True):
            """Launches the app to press those buttons in turn, and waits for the Mac's answer to each."""
            mobile.launch("-qbOpen", "Gates", "-qbDo", steps, *args)
            return mobile.wait(lambda s: len(did(s)) >= len(steps.split(";")) and also(s), 60, f"the Mac to answer {steps}")

        def mac():
            """Everything a press could change on the Mac."""
            now = app.state(gid)
            return {k: now[k] for k in ("isRunning", "log", "runs", "holds", "results", "marks")}

        def refused(state, steps):
            return [step for step, _ in did(state)] == steps.split(";") and all("can only watch" in (r or "") for _, r in did(state))

        def allow(on):
            app.op("app", "remote-control", device=entry["id"], on=on)

        with open(os.path.join(app.support, "remote-devices.json")) as saved:
            entry = next(d for d in json.load(saved)["devices"] if d["id"].lower() == device.lower())
        name = entry["name"]
        waiting = "Waiting for you to let its command run"
        script, approval = ["Don't run", "Allow and run"], ["Reject", "Approve"]

        before = mac()
        s = press("run;stop;startAgents")
        c = controls(s)
        check("a device the Mac hasn't allowed has no controls, and one line saying how to get them",
              c.get("canAct") is False and c.get("bar") == [] and c.get("cards") == {} and "Can control" in (c.get("hint") or ""), str(c))
        check("pressed anyway, the Mac refuses each one", refused(s, "run;stop;startAgents"), str(did(s)))
        time.sleep(2)
        check("and nothing happens on the Mac", mac() == before, str([k for k in before if mac()[k] != before[k]]))
        mobile.shot("mobile-7a-watch-only")
        allow(True)
        s = mobile.wait(lambda s: controls(s).get("canAct"), 15, "the app to hear it may control the Mac")
        check("turned on on the Mac, the controls come at once", controls(s).get("canAct") is True and controls(s).get("bar", [])[-1:] == ["Run"]
              and controls(s).get("hint") is None, str(controls(s)))
        mobile.shot("mobile-7b-can-control")

        # Fitted, this flow is too small on screen for a card's buttons, so the canvas is brought in to the script.
        s = press("run", "-qbZoomCard", "Shout", also=lambda s: shown(s, "Shout").get("text") == waiting and needing(s) and shown(s, "Shout").get("buttons"))
        held(app, gid)
        real = app.state(gid)
        check("Run on the device starts a run on the Mac", did(s) == [("run", None)] and real["isRunning"], f"{did(s)} {real['isRunning']}")
        check("and the Mac's log says which device started it", f"Run started from {name}" in real["log"], str(real["log"][-4:]))
        check("a card holding a message says what it is waiting for", shown(s, "Shout").get("text") == waiting, str(shown(s, "Shout")))
        check("the banner over the canvas names the script that is waiting to be allowed",
              panel(s).get("needsYou") == [{"name": "Shout", "reason": waiting}], str(panel(s).get("needsYou")))
        check("and the script's card, the banner and the run bar offer the Mac's own answers",
              controls(s).get("cards") == {"Shout": script} and controls(s).get("banner") == {"Shout": script} and controls(s).get("bar") == ["Stop"]
              and [b["title"] for b in shown(s, "Shout").get("buttons", [])] == script, f"{controls(s)} {shown(s, 'Shout').get('buttons')}")
        check("the link the run came along shows its count, and the card it left its tick",
              s.get("canvas", {}).get("passes") == {"l0": 1} and shown(s, "Start").get("badges") == ["✓"], str(s.get("canvas", {}).get("passes")))
        mobile.shot("mobile-4a-run-waiting")

        allow(False)
        before = mac()
        s = press("allow:Shout;dontRun:Shout")
        time.sleep(2)
        check("with control turned off again, the script can't be allowed or skipped from the device", refused(s, "allow:Shout;dontRun:Shout") and mac() == before,
              f"{did(s)} {[k for k in before if mac()[k] != before[k]]}")
        allow(True)
        s = press("allow:Shout", also=lambda s: needing(s) == ["Check it"])
        h = held(app, gid, "Check it")
        check("turned on, Allow on the device lets the command run on the Mac", did(s) == [("allow:Shout", None)] and h[0]["text"] == "HELLO FROM THE START CARD",
              f"{did(s)} {h}")
        check("then the approval that is holding the message", panel(s).get("needsYou") == [{"name": "Check it", "reason": "Waiting for you to approve"}],
              str(panel(s).get("needsYou")))
        check("with Reject and Approve on its card", controls(s).get("cards") == {"Check it": approval}, str(controls(s).get("cards")))
        mobile.shot("mobile-7c-approval-waiting")
        allow(False)
        before = mac()
        s = press("approve:Check it;reject:Check it:no")
        time.sleep(2)
        check("with control off, the message can't be approved or rejected from the device", refused(s, "approve:Check it;reject:Check it:no") and mac() == before,
              f"{did(s)} {[k for k in before if mac()[k] != before[k]]}")
        allow(True)
        s = press("reject:Check it:Not yet", also=lambda s: needing(s) == [])
        real = app.wait(gid, lambda s: not s["isRunning"], 20, "the rejected run to end")
        check("Reject on the device sends the message down Rejected, with the note ahead of it",
              did(s) == [("reject:Check it:Not yet", None)] and list(real["results"]) == ["Binned"] and real["results"]["Binned"].startswith("Not yet\n"),
              f"{did(s)} {real['results']}")

        s = press("run", also=lambda s: needing(s) == ["Check it"])
        h = held(app, gid, "Check it")
        check("a second run from the device goes straight to the approval: the command it allowed stays allowed",
              did(s) == [("run", None)] and not h[0]["needsAllow"], f"{did(s)} {h}")
        s = press("stop", also=lambda s: controls(s).get("bar", [])[-1:] == ["Run"])
        real = app.wait(gid, lambda s: not s["isRunning"], 20, "the run to stop")
        check("Stop on the device stops it", did(s) == [("stop", None)] and not real["holds"] and real["runs"][-1]["outcome"] == "stopped",
              f"{did(s)} {real['runs'][-1]['outcome']}")
        check("and the Mac's log says which device stopped it", f"Stopped from {name}" in real["log"], str(real["log"][-4:]))

        kept = len(panel(s).get("runs", []))
        s = press("run;approve:Check it", also=lambda s: needing(s) == [] and shown(s, "Done").get("badges") == ["✓"])
        check("a third run is started and approved from the device", did(s) == [("run", None), ("approve:Check it", None)], str(did(s)))
        real = app.wait(gid, lambda s: not s["isRunning"], 20, "the run to end")
        s = mobile.wait(lambda s: shown(s, "Done").get("badges") == ["✓"] and len(panel(s).get("runs", [])) == kept + 1
                        and panel(s).get("log") == real["log"], 10, "the canvas to show where the run went")
        check("when the run ends nothing is waiting any more", needing(s) == [], str(needing(s)))
        check("the list of runs has one more, and it finished", len(panel(s).get("runs", [])) == kept + 1 and panel(s)["runs"][0]["outcome"] == "finished"
              and panel(s)["runs"][0]["id"] == real["runs"][-1]["id"], f"{kept} before, now {panel(s).get('runs')}")
        check("the log has the Mac's lines, every one", panel(s).get("log") == real["log"] and len(real["log"]) > 3,
              f"Mac {len(real['log'])} lines, app {len(panel(s).get('log', []))}")
        check("and the End card's answer is under its name", panel(s).get("results") == {"Done": "HELLO FROM THE START CARD"}, str(panel(s).get("results")))
        check("when the run ends the canvas shows where it went and what came out",
              shown(s, "Done").get("badges") == ["✓"] and shown(s, "Done").get("text") == "HELLO FROM THE START CARD"
              and shown(s, "Binned").get("badges") == [] and s["canvas"].get("passes") == {"l0": 1, "l1": 1, "l2": 1} and s["canvas"].get("live") == [],
              f"{shown(s, 'Done')} {s.get('canvas', {}).get('passes')}")

        # Typing, to the one session this flow has: its orchestrator. A message first, then keys, then both
        # again with control turned off. The app does each when the file it is waiting for appears.
        app.wait(gid, lambda s: s["orchestrator"]["state"] == "idle", 120, "Gates' orchestrator to be ready")
        # A moment, and asked again: anything the runs above left for it to be told has reached it by now.
        time.sleep(3)
        app.wait(gid, lambda s: s["orchestrator"]["state"] == "idle", 120, "Gates' orchestrator to be ready")
        word, ask_for = "PINEAPPLE", "Reply with exactly the word made by joining PINE and APPLE, in capitals, and nothing else. Do not use any tools."

        def composer(state):
            return state.get("composer") or {}

        def box(state):
            return (composer(state).get("typing") or {}).get("orchestrator") or {}

        def mac_screen():
            return "\n".join(app.op(gid, "terminal", card="orchestrator")["screen"])

        def device_screen(state):
            return "\n".join(((state.get("terminals") or {}).get("orchestrator") or {}).get("screen", []))

        def both_show(text, shown=True):
            """Waits until the Mac's terminal and the device's copy of it both show the text, or both don't."""
            deadline = time.time() + 20
            while True:
                real, here = text in mac_screen(), text in device_screen(mobile.state())
                if (real == shown and here == shown) or time.time() > deadline:
                    return real == shown and here == shown
                time.sleep(0.4)

        was = app.state(gid)["orchestrator"]["lastReply"]
        mobile.launch("-qbOpen", "Gates", "-qbExpand", "orchestrator", "-qbDo",
                      f"wait:a;say:orchestrator:{ask_for};wait:b;type:orchestrator:qbkeys;wait:c;key:orchestrator:ctrl-u;wait:d;say:orchestrator:Say BANANA;type:orchestrator:qbnope")
        s = mobile.wait(lambda s: s.get("expanded") == "orchestrator" and "viewer" in composer(s).get("bars", {}) and box(s).get("bar"), 40,
                        "the orchestrator's terminal to open with its message box")
        check("with control on, the orchestrator's terminal opens with a message box under it",
              box(s).get("bar") is True and composer(s).get("mode") == "message" and composer(s).get("commands") == 0, str(composer(s)))
        mobile.shot("mobile-8a-message-box")
        heard = app.op("app", "remote-state").get("received")
        dropped = ((s.get("terminals") or {}).get("orchestrator") or {}).get("droppedReplies", 0)
        mobile.go("a")
        s = mobile.wait(lambda s: len(did(s)) >= 2, 30, "the Mac to take the message")
        check("a message sent from the device is taken by the Mac, and the box is emptied", did(s)[-1:] == [(f"say:orchestrator:{ask_for}", None)]
              and composer(s).get("drafts") == {}, f"{did(s)} {composer(s).get('drafts')}")
        try:
            real = app.wait(gid, lambda s: s["orchestrator"]["lastReply"] not in (None, was) and s["orchestrator"]["state"] == "idle",
                            180, "the orchestrator to answer the device")
            reply = real["orchestrator"]["lastReply"]
            check("and the orchestrator replies to it", word in reply, reply[:200])
        except TimeoutError as e:
            reply = was
            check("and the orchestrator replies to it", False, str(e)[:300])
        check("the reply shows in the device's terminal, as in the Mac's", both_show(word), device_screen(mobile.state())[-300:])
        check("and the Mac's log says which device sent the message", f"{name} sent a message to the orchestrator" in app.state(gid)["log"], str(app.state(gid)["log"][-4:]))
        mobile.shot("mobile-8b-orchestrator-replied")
        mobile.go("b")
        check("keys typed on the device are typed in the Mac's terminal", both_show("qbkeys"), mac_screen()[-300:])
        mobile.go("c")
        # Ctrl-U empties the line, so nothing typed here is ever sent to the orchestrator.
        check("and Ctrl-U from the device clears them, as it does on the Mac", both_show("qbkeys", shown=False), mac_screen()[-300:])
        s = mobile.wait(lambda s: len(did(s)) >= 6, 20, "the keys to be answered")
        now = app.state(gid)["orchestrator"]
        check("with nothing sent to the orchestrator by them", now["lastReply"] == reply and now["state"] == "idle", f"{now['state']} {str(now['lastReply'])[:80]}")
        sent = composer(s).get("sent", [])
        check("what left the device was the message and the two lots of keys, as the bytes they make",
              sent == [f"prompt:orchestrator:{len(ask_for)}", "keys:orchestrator:" + "qbkeys".encode().hex(), "keys:orchestrator:15"], str(sent))
        after = app.op("app", "remote-state").get("received")
        check("and the Mac heard exactly those three commands from it, and nothing else", after - heard == 3 and composer(s).get("commands") == 3,
              f"{heard} messages before, {after} after; the app sent {composer(s).get('commands')} commands")
        every = s.get("terminals") or {}
        now_dropped = (every.get("orchestrator") or {}).get("droppedReplies", 0)
        # Claude Code asks its terminal most of its questions as it starts, so the count may not move while a
        # short message is typed. What matters is that answers were made, none was sent, and none could be.
        check("the terminal's own answers were dropped, before the typing and through it, and no terminal had the keyboard",
              now_dropped > 0 and now_dropped >= dropped and not any(t["isFirstResponder"] for t in every.values()), f"{dropped} before, {now_dropped} after")
        print(f"        answers dropped by the orchestrator's terminal: {dropped} before typing, {now_dropped} after", flush=True)

        allow(False)
        s = mobile.wait(lambda s: box(s).get("bar") is False, 15, "the app to hear it may no longer control the Mac")
        check("with control turned off, the message box goes and a line says how to get it back",
              box(s).get("bar") is False and "Can control" in (box(s).get("line") or ""), str(box(s)))
        mobile.shot("mobile-8c-cannot-control")
        before, heard = mac(), app.op("app", "remote-state").get("received")
        mobile.go("d")
        s = mobile.wait(lambda s: len(did(s)) >= 9, 30, "the Mac to refuse the message and the keys")
        check("typed anyway, the message and the keys are both refused", [r is not None and "can only watch" in r for _, r in did(s)[-2:]] == [True, True], str(did(s)[-2:]))
        time.sleep(3)
        now = app.state(gid)["orchestrator"]
        check("and nothing is typed on the Mac", mac() == before and "qbnope" not in mac_screen() and "BANANA" not in mac_screen()
              and now["lastReply"] == reply and now["state"] == "idle", f"{[k for k in before if mac()[k] != before[k]]} {mac_screen()[-200:]}")
        check("the message that was refused is still in its box", composer(s).get("drafts") == {"orchestrator": len("Say BANANA")}, str(composer(s).get("drafts")))
        allow(True)
        mobile.wait(lambda s: controls(s).get("canAct"), 15, "the app to hear it may control the Mac again")

        # A second run that ends another way, so there is an earlier one to look back at.
        app.op(gid, "run")
        held(app, gid, "Check it")
        app.op(gid, "hold", answer="reject", text="Too loud")
        real = app.wait(gid, lambda s: not s["isRunning"], 20, "the second run to end")
        earlier = real["runs"][-2]["id"]
        mobile.launch("-qbOpen", "Gates", "-qbShow", "runs", "-qbViewRun", str(len(real["runs"]) - 2))
        s = mobile.wait(lambda s: panel(s).get("viewedRun") == earlier and shown(s, "Done").get("badges") == ["✓"], 40, "the app to show the earlier run")
        check("an earlier run can be put on show on the device", panel(s).get("viewedRun") == earlier
              and [r["onShow"] for r in panel(s).get("runs", [])][:2] == [False, True], str(panel(s).get("runs")))
        check("the canvas and the panels show that run's marks, counts and answer",
              shown(s, "Done").get("text") == "HELLO FROM THE START CARD" and shown(s, "Binned").get("badges") == []
              and s["canvas"].get("passes") == {"l0": 1, "l1": 1, "l2": 1} and panel(s).get("results") == {"Done": "HELLO FROM THE START CARD"},
              f"{shown(s, 'Done')} {shown(s, 'Binned')} {s['canvas'].get('passes')} {panel(s).get('results')}")
        part = panel(s).get("log", [])
        check("and only that run's part of the log", 0 < len(part) < len(real["log"])
              and any(real["log"][i:i + len(part)] == part for i in range(len(real["log"]))) and part[0].startswith("Run started"), str(part))
        now = app.state(gid)
        check("the Mac goes on showing its latest run, and is told nothing", now["viewedRun"] is None and list(now["results"]) == ["Binned"],
              f"{now['viewedRun']} {now['results']}")
        mobile.shot("mobile-4i-earlier-run")
        app.op(gid, "close")

        mobile.quit()
        state = remote(lambda r: r["connected"] == 0, 20, "the Mac to notice the app has gone")
        check("quitting the app ends its connection", state["connected"] == 0 and state["devices"] == 1, str(state))
        mobile.launch("-qbOpen", "Guard", "-qbSelect", "Bob")
        s = mobile.wait(lambda s: s["state"] == "connected" and s["flows"] and s.get("openFlowCards") and (s.get("canvas") or {}).get("selected"),
                        40, "the app to connect again")
        bob = next(c["id"] for c in GUARD["cards"] if c["name"] == "Bob")
        check("a card can be selected on the canvas, and only it is", (s.get("canvas") or {}).get("selected") == {"card": bob}
              and [c["name"] for c in s["canvas"]["cards"] if c["selected"]] == ["Bob"], str((s.get("canvas") or {}).get("selected")))
        mobile.shot("mobile-4b-card-selected")
        check("launched again with nothing said about the Mac, the app connects by itself", s.get("state") == "connected" and s.get("device") == device, str(s))
        check("with the key it kept", s.get("hasKey") is True and remote(lambda r: r["connected"] == 1, 10, "the Mac to see it")["connected"] == 1, str(s))

        app.op("app", "remote-on", on=False)
        s = mobile.wait(lambda s: s["state"] == "lookingForMac" and s["macNotFound"], 40, "the app to say the Mac can't be found")
        check("when the Mac stops listening the app says it can't find it", s.get("state") == "lookingForMac" and s.get("macNotFound") is True, str(s))
        check("and keeps the flow it had open, to show dimmed", s.get("openFlow") == "Guard" and s.get("openFlowCards") == len(GUARD["cards"]), str(s))
        mobile.shot("mobile-5-mac-not-found")
        app.op("app", "remote-on")
        s = mobile.wait(lambda s: s["state"] == "connected", 40, "the app to connect again")
        check("and connects again when the Mac is back", s.get("state") == "connected" and s.get("macNotFound") is False, str(s))
        state = remote(lambda r: r.get("open") == ["Guard"], 10, "the Mac to see the flow opened again")
        check("and asks for its open flow again", state.get("open") == ["Guard"], str(state))

        app.op("app", "remote-remove", device=device)
        s = mobile.wait(lambda s: s["state"] == "mustPairAgain", 30, "the app to say it must be paired again")
        check("removed on the Mac, the app says it must be paired again", s.get("state") == "mustPairAgain" and "no longer paired" in (s.get("text") or ""), str(s))
        state = app.op("app", "remote-state")
        check("and the Mac has forgotten it", state["devices"] == 0 and state["connected"] == 0, str(state))
        mobile.shot("mobile-6-pair-again")
    finally:
        mobile.appearance("light")
        mobile.quit()


def scenario_terminals():
    print("terminals: the iPad app's terminals, fed output made up inside the app", flush=True)
    if not os.path.exists(MOBILE_APP):
        print("  SKIP  the iPad app isn't built. Build it first: ./scripts/build-mobile.sh", flush=True)
        return
    udid = simulator()
    if udid is None:
        print("  SKIP  this Mac has no iOS 26 Simulator to run the iPad app in", flush=True)
        return
    mobile = Mobile(udid)
    print(f"        screenshots: {mobile.shots}", flush=True)
    agent = "agent001"
    # What `DebugCanned` in the app prints, in the order it prints it.
    first = ["● Agent ready in ~/example", "A made-up session, for checking the terminal."] + [str(n) for n in range(1, 121)]
    more = ["✓ still going"] + [str(n) for n in range(121, 151)] + ["> "]
    fresh = ["after the fresh start"] + [str(n) for n in range(1, 41)] + [""]

    def play(steps, *args, also=lambda s: True):
        mobile.launch("-qbCanned", str(steps), *args)
        return mobile.wait(lambda s: s.get("cannedStep") == steps and agent in (s.get("terminals") or {})
                           and (steps < 2 or shown_card(s, "Agent").get("hasTerminal") is not None) and also(s), 30, f"step {steps} of the made-up stream")

    def terminal(state, key=agent):
        return (state.get("terminals") or {}).get(key) or {}

    def rows(lines, t, back=0):
        """The rows a terminal of that height shows of these lines, when scrolled back that many."""
        end = len(lines) - back
        return [line.rstrip() for line in lines[end - t.get("rows", 0):end]]

    def screen(t):
        return [row.rstrip() for row in t.get("screen", [])]

    try:
        s = play(1)
        t = terminal(s)
        check("a terminal's first screen is taken in before its flow has arrived", t.get("resets") == 1 and screen(t) == rows(first + [""], t)
              and s.get("openFlowCards") is None, f"{screen(t)[-3:]} {s.get('openFlowCards')}")
        check("output for a flow that isn't the open one is left out", t.get("chunks") == 1, str(t.get("chunks")))

        s = play(3, also=lambda s: shown_card(s, "Agent").get("terminalPlace"))
        t, card = terminal(s), shown_card(s, "Agent")
        cell, place, zoom = t.get("cell", {"width": 1, "height": 1}), card.get("terminalPlace") or {}, s.get("canvas", {}).get("zoom", 1)
        fits = (int((480 - 12) / cell["width"]), int((300 - 28 - 8) / cell["height"]))
        check("the terminal has exactly the columns and rows it was sent", (t.get("cols"), t.get("rows")) == fits, f"{t.get('cols')}x{t.get('rows')}, sent {fits}")
        check("output that follows on, cut inside a colour and inside a character, comes out whole",
              screen(t) == rows(first + more, t) and t.get("chunks") == 6, f"{screen(t)[-4:]} after {t.get('chunks')} chunks")
        check("everything before it can be scrolled back to", t.get("scrollback") == len(first + more) - t.get("rows", 0), str(t.get("scrollback")))
        check("each question in the stream was answered to nobody", t.get("droppedReplies", 0) >= 4 and t.get("isFirstResponder") is False,
              f"{t.get('droppedReplies')} replies, {t.get('droppedBytes')} bytes")
        on = t.get("onScreen", {})
        check("in its card the terminal is the Mac's own size, from the top left of the place for it",
              t.get("scale") == 1 and bool(place) and inside(on, place) and abs(on["x"] - place["x"]) < 1 and abs(on["y"] - place["y"]) < 1
              and abs(on["width"] - t["natural"]["width"] * zoom) < 1, f"{on} in {place} at zoom {zoom}")
        check("the orchestrator's terminal is kept though it has no card", (terminal(s, "orchestrator").get("cols"), terminal(s, "orchestrator").get("rows")) == (58, 40),
              str(terminal(s, "orchestrator").get("cols")))
        check("shown no larger than life, it is drawn at the screen's own fineness", t.get("sharpness") == 1, str(t.get("sharpness")))
        mobile.shot("terminals-1-card")

        s = play(3, "-qbZoom", "0.6", also=lambda s: abs((s.get("canvas") or {}).get("zoom", 1) - 0.6) < 0.01)
        t, place, zoom = terminal(s), shown_card(s, "Agent").get("terminalPlace") or {}, s.get("canvas", {}).get("zoom", 1)
        on = t.get("onScreen", {})
        check("zoomed out, the terminal shrinks with its card", abs(zoom - 0.6) < 0.01 and bool(place) and inside(on, place)
              and abs(on["width"] - t["natural"]["width"] * 0.6) < 1, f"{on} in {place} at zoom {zoom}")
        mobile.shot("terminals-2-card-zoomed-out")

        s = play(3, "-qbZoom", "2", also=lambda s: (s.get("canvas") or {}).get("zoom", 1) > 1.9 and terminal(s).get("sharpness") == 2)
        t, place, zoom = terminal(s), shown_card(s, "Agent").get("terminalPlace") or {}, s.get("canvas", {}).get("zoom", 1)
        on = t.get("onScreen", {})
        check("zoomed in, it grows with its card", zoom > 1.2 and bool(place) and inside(on, place) and abs(on["width"] - t["natural"]["width"] * zoom) < 1.5,
              f"{on} in {place} at zoom {zoom}")
        check("and is drawn twice as finely, so its text stays sharp", t.get("sharpness") == 2, str(t.get("sharpness")))
        mobile.shot("terminals-3-card-zoomed-in")
        mobile.appearance("dark")
        mobile.shot("terminals-4-card-zoomed-in-dark")
        mobile.appearance("light")

        def in_view(state, name):
            """Whether any of a card is in the part of the canvas on screen."""
            c, v = shown_card(state, name), (state.get("canvas") or {}).get("visible") or {}
            return bool(c) and bool(v) and (c["x"] < v["x"] + v["width"] and c["x"] + c["width"] > v["x"]
                                            and c["y"] < v["y"] + v["height"] and c["y"] + c["height"] > v["y"])

        s = play(3, "-qbZoomCard", "Agent", "-qbZoom", "3", also=lambda s: (s.get("canvas") or {}).get("zoom", 1) > 2.9 and terminal(s).get("sharpness") == 2)
        check("zoomed in as far as it goes, a card's terminal is still drawn no more than twice as finely",
              s.get("canvas", {}).get("zoom", 1) > 2.9 and in_view(s, "Agent") and terminal(s).get("sharpness") == 2,
              f"sharpness {terminal(s).get('sharpness')} at zoom {s.get('canvas', {}).get('zoom')}")
        s = play(3, "-qbZoomCard", "Start", "-qbZoom", "3", also=lambda s: (s.get("canvas") or {}).get("zoom", 1) > 2.9 and terminal(s).get("sharpness") == 1)
        check("and one whose card is out of view is left at the screen's own fineness",
              s.get("canvas", {}).get("zoom", 1) > 2.9 and not in_view(s, "Agent") and terminal(s).get("sharpness") == 1,
              f"sharpness {terminal(s).get('sharpness')}, in view {in_view(s, 'Agent')}, seeing {s.get('canvas', {}).get('visible')}")

        was = (terminal(s).get("cols", 0), terminal(s).get("rows", 0))
        s = play(5, also=lambda s: terminal(s).get("resets") == 2)
        t, place = terminal(s), shown_card(s, "Agent").get("terminalPlace") or {}
        check("a fresh start gives the terminal its new size", (t.get("cols"), t.get("rows")) == (was[0] - 12, was[1] - 4) and t.get("resets") == 2,
              f"{t.get('cols')}x{t.get('rows')} from {was}")
        check("and leaves nothing of the old screen, its other screen, its scroll region or its modes",
              screen(t) == rows(fresh, t) and t.get("cursor") == [0, t.get("rows", 0) - 1], f"{screen(t)[:3]} … {screen(t)[-3:]} cursor {t.get('cursor')}")
        check("nor any of the old output to scroll back to", t.get("scrollback") == len(fresh) - t.get("rows", 0), str(t.get("scrollback")))
        on = t.get("onScreen", {})
        check("smaller than its place, the terminal is stretched to fill it", t.get("scale", 0) > 1 and bool(place) and inside(on, place)
              and min(place["width"] - on["width"], place["height"] - on["height"]) < 1, f"{on} in {place}, scale {t.get('scale')}")
        mobile.shot("terminals-5-fresh-start")

        s = play(3, "-qbExpand", "Agent", "-qbScrollBack", "40",
                 also=lambda s: s.get("expanded") == agent and screen(terminal(s)) == rows(first + more, terminal(s), back=40))
        t = terminal(s)
        check("the terminal opens full screen", s.get("expanded") == agent and t.get("shown") is True, str(s.get("expanded")))
        check("where it scrolls back through earlier output", screen(t) == rows(first + more, t, back=40), f"{screen(t)[:2]} … {screen(t)[-2:]}")
        on, natural, canvas = t.get("onScreen", {}), t.get("natural", {}).get("width", 1), s.get("canvas") or {}
        # The canvas is still there underneath, and what it can see across is the width of the screen.
        across = canvas.get("visible", {}).get("width", 0) * canvas.get("zoom", 0)
        if natural + 24 <= across:
            check("at least as large as on the Mac, and within the screen", on.get("width", 0) >= natural - 1 and on.get("x", -1) >= 0, str(on))
        else:
            # An iPhone held upright is narrower than the Mac's terminal, so there it can't be life size and whole.
            check("on a screen narrower than the Mac's terminal, it fills the width with every column in view",
                  abs(on.get("width", 0) - (across - 24)) < 1 and on.get("x", -1) >= 0, f"{on} of {across:.0f} across, {natural:.0f} on the Mac")
        check("and still takes no typing", t.get("isFirstResponder") is False)
        check("full screen it keeps its own fineness, up to three times the screen's",
              t.get("sharpness") == min(3, math.ceil(on.get("width", 0) / natural - 0.01)), f"{t.get('sharpness')} for {on.get('width')} of {natural}")
        check("its card goes without it meanwhile", shown_card(s, "Agent").get("hasTerminal") is False, str(shown_card(s, "Agent").get("hasTerminal")))
        mobile.shot("terminals-6-full-screen-scrolled-back")

        s = play(3, "-qbShow", "orchestrator", also=lambda s: terminal(s, "orchestrator").get("shown"))
        t = terminal(s, "orchestrator")
        check("the orchestrator's terminal is shown in the panel beside the canvas", t.get("shown") is True and t.get("scale", 0) > 0
              and t.get("onScreen", {}).get("width", 0) > 100, f"{t.get('onScreen')} scale {t.get('scale')}")
        mobile.shot("terminals-7-orchestrator")
    finally:
        mobile.appearance("light")
        mobile.quit()


def scenario_panels():
    print("panels: the iPad app's panels, fed a run made up inside the app", flush=True)
    if not os.path.exists(MOBILE_APP):
        print("  SKIP  the iPad app isn't built. Build it first: ./scripts/build-mobile.sh", flush=True)
        return
    udid = simulator()
    if udid is None:
        print("  SKIP  this Mac has no iOS 26 Simulator to run the iPad app in", flush=True)
        return
    mobile = Mobile(udid)
    print(f"        screenshots: {mobile.shots}", flush=True)
    # What `DebugCannedRun` in the app plays, stage by stage.
    command = "Write a welcome note for new members of the book club."
    note = "Welcome to the book club.\n\nWe meet on the first Thursday"
    changes, answer = "Changes are made on your Mac for now.", "Answer on your Mac for now."

    def play(stage, *args, also=lambda s: True):
        mobile.launch("-qbCannedRun", str(stage), *args)
        return mobile.wait(lambda s: s.get("cannedStage") == stage and len((s.get("canvas") or {}).get("cards", [])) == 8 and also(s),
                           30, f"stage {stage} of the made-up run")

    def panel(state):
        return state.get("panel") or {}

    def details(state):
        return panel(state).get("details") or {}

    def items(state):
        return {i["label"]: i["value"] for i in details(state).get("items", [])}

    def styled(state, style):
        return [(i["label"], i["value"]) for i in details(state).get("items", []) if i["style"] == style]

    def room(state):
        """How tall the part of the canvas nothing floats over is, on screen."""
        canvas = state.get("canvas") or {}
        return canvas.get("clear", {}).get("height", 0) * canvas.get("zoom", 0)

    def both(name):
        """The same screen in light and in dark."""
        mobile.shot(name + "-light")
        mobile.appearance("dark")
        mobile.shot(name + "-dark")
        mobile.appearance("light")

    try:
        s = play(1, "-qbSelect", "Writer", also=lambda s: details(s).get("title") == "Writer")
        p = panel(s)
        check("the banner lists the cards waiting on the person, in canvas order, with what each waits for",
              p.get("needsYou") == [{"name": "Writer", "reason": "Waiting for you in its terminal"},
                                    {"name": "Style guide", "reason": "Waiting for you to let its command run"}], str(p.get("needsYou")))
        with_banner = room(s)
        check("an agent's details list its settings in the Mac's words",
              items(s).get("Instructions", "").startswith("You write short notes") and items(s).get("Model") == "Opus" and items(s).get("Effort") == "high"
              and items(s).get("Permissions") == "Accept edits" and items(s).get("Folder") == "notes" and items(s).get("Cost") == "$0.50 in all"
              and details(s).get("state") == "needsYou", str(items(s)))
        check("with a line saying where changes are made, and where the answer is given",
              details(s).get("footer") == changes and details(s).get("answerLine") is True
              and styled(s, "waiting") == [("Waiting for you in its terminal.", "")], f"{details(s).get('footer')} {styled(s, 'waiting')}")
        check("the log has every line the Mac sent", len(p.get("log", [])) == 19 and p["log"][-1] == "Style guide is waiting for you to let its command run",
              str(p.get("log", [])[-2:]))
        check("earlier runs are listed newest first, with how each ended, how long it took and what it cost",
              [(r["id"], r["outcome"], r["length"], r["cost"]) for r in p.get("runs", [])]
              == [("run00002", "failed", "21 sec", "$0.08"), ("run00001", "finished", "1 min 35 sec", "$0.42")], str(p.get("runs")))
        check("while a run is going none of them is on show, and the run has no figure yet",
              not any(r["onShow"] for r in p.get("runs", [])) and p.get("cost", {}).get("runTotal") is None
              and "after it ends" in (p.get("cost", {}).get("runPending") or ""), str(p.get("cost")))
        check("the flow's running total adds up its sessions, dearest first", p.get("cost", {}).get("total") == "$0.71"
              and p["cost"]["sessions"] == [["Writer", "$0.50", "88k tokens"], ["Orchestrator", "$0.21", "36k tokens"]], str(p.get("cost")))
        both("panels-01-needs-you-agent")

        s = play(1, "-qbGoToWaiting", "1", also=lambda s: (s.get("canvas") or {}).get("selected") == {"card": "style001"})
        canvas, card = s.get("canvas") or {}, shown_card(s, "Style guide")
        clear = canvas.get("clear") or {"x": 0, "y": 0, "width": 0, "height": 0}
        # The canvas is still moving when the selection is first written, so wait for it to arrive.
        deadline = time.time() + 5
        while time.time() < deadline:
            s = mobile.state()
            canvas, card = s.get("canvas") or {}, shown_card(s, "Style guide")
            clear = canvas.get("clear") or clear
            off = (abs(card.get("x", 0) + card.get("width", 0) / 2 - clear["x"] - clear["width"] / 2),
                   abs(card.get("y", 0) + card.get("height", 0) / 2 - clear["y"] - clear["height"] / 2))
            if max(off) < 2:
                break
            time.sleep(0.3)
        check("going to a waiting card selects it and puts it in the middle of the clear part of the canvas",
              canvas.get("selected") == {"card": "style001"} and max(off) < 2, f"{canvas.get('selected')} off by {off}")
        check("and turns the panel to its details: the command, and that it is waiting to be allowed",
              panel(s).get("page") == "details" and items(s).get("Command") == "cat docs/style.md"
              and [value for _, value in styled(s, "waiting")] == ["cat docs/style.md"] and details(s).get("answerLine") is True, str(details(s)))
        both("panels-02-script-waiting")

        s = play(2, "-qbSelect", "Sign off", also=lambda s: details(s).get("title") == "Sign off")
        p = panel(s)
        check("when the run moves on, so does the banner", [c["name"] for c in p.get("needsYou", [])] == ["Sign off"], str(p.get("needsYou")))
        check("lines that arrive later are added to the log", len(p.get("log", [])) == 24 and p["log"][-1] == "Sign off is waiting for you", str(p.get("log", [])[-2:]))
        waiting = styled(s, "waiting")
        check("an approval's details show the message it is holding and who sent it",
              items(s).get("What to check before approving") == "Is this note right to send?" and len(waiting) == 1
              and waiting[0][0] == "From Short enough? Waiting for you." and waiting[0][1].startswith(note), str(waiting)[:200])
        both("panels-03-approval-waiting")

        s = play(3, "-qbShow", "runs")
        p = panel(s)
        check("the panel can be turned to a page by name", (p.get("page"), p.get("tab")) == ("runs", "history"), f"{p.get('page')} {p.get('tab')}")
        # Measured as the room with the banner was: with the panel left alone. On an iPhone the panel is a
        # sheet that comes up over the canvas's foot, and asking for a page of it brings it up.
        without_banner = room(play(3))
        check("when nothing is waiting the banner goes, and the canvas has its room back", p.get("needsYou") == [] and without_banner > with_banner + 100,
              f"{without_banner:.0f} points clear, {with_banner:.0f} with the banner")
        check("the run that ended is listed first, and is the one on show",
              [(r["id"], r["outcome"], r["cost"], r["onShow"]) for r in p.get("runs", [])][:1] == [("run00003", "finished", "$0.37", True)]
              and [r["id"] for r in p.get("runs", [])] == ["run00003", "run00002", "run00001"] and p.get("viewedRun") is None, str(p.get("runs")))
        check("the End card's answer is under its name", list(p.get("results", {})) == ["Sent"] and p["results"]["Sent"].startswith(note), str(p.get("results"))[:120])
        check("the run's cost is listed card by card with its total",
              p.get("cost", {}).get("runTotal") == "$0.37" and p["cost"]["runLines"] == [["Writer", "$0.37", "57k tokens"]]
              and p["cost"]["runTitle"] == "Latest run" and p["cost"]["total"] == "$1.08", str(p.get("cost")))
        both("panels-04-runs")
        for page in ("log", "output", "cost"):
            s = play(3, "-qbShow", page, also=lambda s: panel(s).get("page") == page)
            both(f"panels-0{5 + ('log', 'output', 'cost').index(page)}-{page}")
        check("the log has every line of every run so far", len(panel(s).get("log", [])) == 26, str(len(panel(s).get("log", []))))

        s = play(3, "-qbSelect", "link:2", also=lambda s: details(s).get("kind") == "Link")
        check("a link's details name its ends and show what it carried, with who sent it",
              details(s).get("title") == "Writer → Both ready" and items(s).get("Limit per run") == "3" and len(details(s).get("messages") or []) == 1
              and details(s)["messages"][0]["from"] == "Writer" and details(s)["messages"][0]["text"].startswith(note), str(details(s))[:300])
        both("panels-08-link-messages")
        s = play(3, "-qbSelect", "Start", also=lambda s: details(s).get("title") == "Start")
        check("a Start card's details say what it starts with and when it runs",
              items(s).get("What the run starts with") == command and items(s).get("Runs") == "On chosen days" and items(s).get("On") == "Mon, Wed"
              and items(s).get("At") == "09:00", str(items(s)))
        both("panels-09-start-schedule")

        s = play(3, "-qbViewRun", "1", "-qbShow", "log", also=lambda s: panel(s).get("viewedRun") == "run00002")
        p, canvas = panel(s), s.get("canvas") or {}
        check("an earlier run can be put on show", p.get("viewedRun") == "run00002" and [r["onShow"] for r in p.get("runs", [])] == [False, True, False],
              str(p.get("runs")))
        check("the log, the answers and the cost are that run's", len(p.get("log", [])) == 5 and p["log"][-1].startswith("Run stopped because Style guide failed")
              and p.get("results") == {} and p.get("cost", {}).get("runTotal") == "$0.08" and p["cost"]["runTitle"].startswith("Run from "),
              f"{p.get('log')} {p.get('results')} {p.get('cost')}")
        check("and so are the canvas's counts", canvas.get("passes") == {"l0": 1, "l1": 1}, str(canvas.get("passes")))
        both("panels-10-earlier-run-failed")

        s = play(3, "-qbViewRun", "0", "-qbSelect", "link:2", also=lambda s: panel(s).get("viewedRun") == "run00001" and details(s).get("kind") == "Link")
        p, canvas = panel(s), s.get("canvas") or {}
        check("a link shows what it carried in the run on show", [m["text"][:25] for m in details(s).get("messages") or []] == ["Welcome to the book club."]
              and "lighthouse" not in details(s)["messages"][0]["text"], str(details(s).get("messages")))
        check("an End card shows its answer in that run, on the canvas and in the panel",
              p.get("results", {}).get("Sent", "").endswith("Tea is on us.") and shown_card(s, "Sent").get("text", "").endswith("Tea is on us.")
              and len(canvas.get("passes", {})) == 7, f"{p.get('results')} {shown_card(s, 'Sent')}")

        s = play(3, "-qbViewRun", "2", also=lambda s: panel(s).get("lastViewedRun") is None)
        check("picking the latest run is going back to the latest", panel(s).get("viewedRun") is None and panel(s)["runs"][0]["onShow"] is True,
              str(panel(s).get("viewedRun")))

        s = play(4, "-qbViewRun", "0", also=lambda s: panel(s).get("lastViewedRun") == "run00001" and panel(s).get("viewedRun") is None)
        p = panel(s)
        check("when a new run begins on the Mac, the device goes back to showing the latest",
              p.get("lastViewedRun") == "run00001" and p.get("viewedRun") is None and not any(r["onShow"] for r in p.get("runs", []))
              and len(p.get("log", [])) == 29 and (s.get("canvas") or {}).get("passes") == {"l0": 1, "l1": 1}, f"{p.get('viewedRun')} {len(p.get('log', []))}")
    finally:
        mobile.appearance("light")
        mobile.quit()


def scenario_controls():
    print("controls: the iPad app's run bar and the buttons that answer a run, with a Mac made up inside the app", flush=True)
    if not os.path.exists(MOBILE_APP):
        print("  SKIP  the iPad app isn't built. Build it first: ./scripts/build-mobile.sh", flush=True)
        return
    udid = simulator()
    if udid is None:
        print("  SKIP  this Mac has no iOS 26 Simulator to run the iPad app in", flush=True)
        return
    mobile = Mobile(udid)
    print(f"        screenshots: {mobile.shots}", flush=True)
    # What `DebugCannedRun` in the app plays, stage by stage, and how its made-up Mac answers.
    watch_only, away = "can only watch", "Not connected to your Mac right now."
    on = ("-qbControl", "1")

    def controls(state):
        return state.get("controls") or {}

    def play(stage, *args, also=lambda s: True, steps=0):
        """Plays the made-up run to a stage, and waits for that many of the steps it was told to do."""
        mobile.launch("-qbCannedRun", str(stage), *args)
        return mobile.wait(lambda s: s.get("cannedStage") == stage and len((s.get("canvas") or {}).get("cards", [])) == 8
                           and len(controls(s).get("done", [])) >= steps and also(s), 30, f"stage {stage} of the made-up run")

    def did(state):
        return [(d["step"], d["refusal"]) for d in controls(state).get("done", [])]

    def drawn(state, name):
        """The buttons drawn on a card, as the canvas has them."""
        return [(b["title"], b["enabled"]) for b in shown_card(state, name).get("buttons", [])]

    def needing(state):
        return [c["name"] for c in (state.get("panel") or {}).get("needsYou", [])]

    def nothing(state):
        """No control anywhere: no bar, and no button on a card, in the banner or in the details."""
        c = controls(state)
        return (c.get("canAct") is False and c.get("bar") == [] and c.get("cards") == {} and c.get("banner") == {} and c.get("details") == []
                and not any(card.get("buttons") for card in (state.get("canvas") or {}).get("cards", [])))

    def both(name):
        """The same screen in light and in dark."""
        mobile.shot(name + "-light")
        mobile.appearance("dark")
        mobile.shot(name + "-dark")
        mobile.appearance("light")

    try:
        s = play(1, "-qbSelect", "Style guide")
        c = controls(s)
        check("a device that may only watch has no controls anywhere", nothing(s) and c.get("canControl") is False, str(c))
        check("and one line where the run bar would be says how to turn control on",
              "Can control" in (c.get("hint") or "") and "Settings" in c["hint"] and c.get("answerLine") == "Answer on your Mac for now.", str(c.get("hint")))
        both("controls-01-watch-only")
        s = play(1, "-qbDo", "run;stop;allow:Style guide;dontRun:Style guide", steps=4)
        check("pressed anyway, everything is refused in the Mac's words", len(did(s)) == 4 and all(watch_only in (r or "") for _, r in did(s)), str(did(s)))
        check("and nothing changes", needing(s) == ["Writer", "Style guide"] and nothing(s) and watch_only in (controls(s).get("refusal") or ""), str(needing(s)))
        both("controls-02-refusal")

        s = play(1, *on, "-qbZoomCard", "Style guide", "-qbSelect", "Style guide")
        c = controls(s)
        script = ["Don't run", "Allow and run"]
        check("allowed to control, the run bar offers Stop while a run is going", c.get("canAct") is True and c.get("bar") == ["Stop"] and c.get("hint") is None, str(c))
        check("a script waiting to be allowed has the Mac's two answers on its card, in the banner and in its details",
              c.get("cards") == {"Style guide": script} and c.get("banner") == {"Style guide": script} and c.get("details") == script
              and drawn(s, "Style guide") == [(t, True) for t in script], f"{c} {drawn(s, 'Style guide')}")
        check("an agent waiting in its terminal has no buttons on its card: it is answered in its terminal",
              c.get("answerLine") is None and drawn(s, "Writer") == [] and (s.get("composer") or {}).get("openTerminal") == ["Writer"],
              f"{c.get('answerLine')} {(s.get('composer') or {}).get('openTerminal')}")
        both("controls-03-script-waiting")
        s = play(1, *on, "-qbPress", "allow:Style guide", also=lambda s: controls(s).get("asking"))
        check("Allow shows the whole command and asks before anything is sent",
              controls(s).get("asking") == "allow:Style guide:cat docs/style.md" and controls(s).get("waiting") == [] and needing(s) == ["Writer", "Style guide"],
              str(controls(s).get("asking")))
        both("controls-04-allow-asks")
        s = play(1, *on, "-qbDo", "allow:Style guide", steps=1, also=lambda s: needing(s) == ["Writer"])
        check("allowed, the command is let run and the card stops waiting",
              did(s) == [("allow:Style guide", None)] and needing(s) == ["Writer"] and controls(s).get("cards") == {} and controls(s).get("refusal") is None, str(did(s)))
        s = play(1, *on, "-qbDo", "dontRun:Style guide", steps=1, also=lambda s: needing(s) == ["Writer"])
        check("and so does Don't run", did(s) == [("dontRun:Style guide", None)] and needing(s) == ["Writer"], str(did(s)))
        s = play(1, *on, "-qbDo", "run", steps=1)
        check("what the Mac refuses is shown in its own words", did(s) == [("run", "A run is already going. Stop it before starting another.")]
              and controls(s).get("refusal") == did(s)[0][1], str(did(s)))
        mobile.shot("controls-05-refusal-run-going")
        s = play(1, *on, "-qbDo", "run;stop", steps=2, also=lambda s: controls(s).get("bar") == ["Run"])
        check("and goes away when the next thing works", did(s)[1:] == [("stop", None)] and controls(s).get("refusal") is None, str(controls(s)))
        check("a stopped run leaves Run on offer", controls(s).get("bar") == ["Run"] and needing(s) == ["Writer"], str(controls(s).get("bar")))
        s = play(1, *on, "-qbPress", "stop", also=lambda s: controls(s).get("asking"))
        check("Stop asks first", controls(s).get("asking") == "stop" and controls(s).get("bar") == ["Stop"], str(controls(s).get("asking")))
        mobile.shot("controls-06-stop-asks")

        approval = ["Reject", "Approve"]
        s = play(2, *on, "-qbZoomCard", "Sign off", "-qbSelect", "Sign off")
        c = controls(s)
        check("an approval holding a message has Reject and Approve on its card, in the banner and in its details",
              c.get("cards") == {"Sign off": approval} and c.get("banner") == {"Sign off": approval} and c.get("details") == approval
              and drawn(s, "Sign off") == [(t, True) for t in approval] and c.get("answerLine") is None, f"{c} {drawn(s, 'Sign off')}")
        on_screen = shown_card(s, "Sign off").get("buttons", [])
        check("the buttons are drawn inside their card", bool(on_screen) and all(b["width"] > 30 and b["height"] > 15 for b in on_screen), str(on_screen))
        both("controls-07-approval-waiting")
        s = play(2, *on, "-qbPress", "reject:Sign off", also=lambda s: controls(s).get("asking"))
        check("Reject asks for a note before anything is sent", controls(s).get("asking") == "reject:Sign off" and needing(s) == ["Sign off"], str(controls(s).get("asking")))
        both("controls-08-reject-note")
        s = play(2, *on, "-qbDo", "reject:Sign off:Too long", steps=1, also=lambda s: needing(s) == [])
        check("rejected with a note, the card stops waiting", did(s) == [("reject:Sign off:Too long", None)] and needing(s) == [], str(did(s)))
        s = play(2, *on, "-qbDo", "approve:Sign off", steps=1, also=lambda s: needing(s) == [])
        check("and so it does approved", did(s) == [("approve:Sign off", None)] and needing(s) == [] and controls(s).get("cards") == {}, str(did(s)))
        s = play(2, *on, "-qbZoom", "0.3")
        check("zoomed too far out to press, a card has no buttons, and the banner still does",
              drawn(s, "Sign off") == [] and controls(s).get("banner") == {"Sign off": approval}, f"{drawn(s, 'Sign off')} {(s.get('canvas') or {}).get('zoom')}")

        s = play(2, *on, "-qbSilent", "1", "-qbZoomCard", "Sign off", "-qbDo", "~approve:Sign off;pause;away",
                 also=lambda s: controls(s).get("waiting") == ["approve"])
        check("while a command waits for the Mac's answer, both of its card's buttons are off",
              controls(s).get("waiting") == ["approve"] and controls(s).get("disabled") == ["Approve", "Reject"]
              and drawn(s, "Sign off") == [(t, False) for t in approval] and controls(s).get("bar") == ["Stop"], f"{controls(s)} {drawn(s, 'Sign off')}")
        s = mobile.wait(lambda s: did(s), 15, "the link to drop")
        check("when the link drops, what was waiting is told so, and nothing is kept to send later",
              did(s) == [("approve:Sign off", away)] and controls(s).get("waiting") == [] and controls(s).get("refusal") == away, str(controls(s)))
        check("and with no Mac there are no controls, and no line about turning them on", nothing(s) and controls(s).get("hint") is None, str(controls(s)))

        s = play(2, *on, "-qbDo", "control:off;approve:Sign off", steps=1)
        check("when “Can control” is turned off on the Mac the controls go at once",
              nothing(s) and "Can control" in (controls(s).get("hint") or "") and did(s)[0][1] and watch_only in did(s)[0][1] and needing(s) == ["Sign off"], str(controls(s)))
        s = play(2, "-qbDo", "control:on;pause", "-qbZoomCard", "Sign off", also=lambda s: controls(s).get("canAct"))
        check("and come when it is turned on", controls(s).get("cards") == {"Sign off": approval} and controls(s).get("hint") is None, str(controls(s)))

        s = play(3, *on, "-qbSelect", "Both ready")
        c = controls(s)
        check("with no run going the bar offers Run, and a card's details offer to run from it",
              c.get("bar") == ["Run"] and c.get("barNote") is None and c.get("cards") == {} and c.get("details") == ["Run from here…"], str(c))
        both("controls-09-run-idle")
        s = play(3, *on, "-qbDo", "run", steps=1, also=lambda s: controls(s).get("bar") == ["Stop"])
        check("Run starts a run", did(s) == [("run", None)] and controls(s).get("bar") == ["Stop"], str(controls(s)))
        s = play(3, *on, "-qbDo", "runFrom:Both ready:Start again from here", steps=1, also=lambda s: controls(s).get("bar") == ["Stop"])
        check("and so does running from a card", did(s) == [("runFrom:Both ready:Start again from here", None)] and controls(s).get("bar") == ["Stop"], str(controls(s)))
        s = play(3, *on, "-qbViewRun", "0", also=lambda s: (s.get("panel") or {}).get("viewedRun") == "run00001")
        check("while an earlier run is on show there are no controls", nothing(s) and controls(s).get("hint") is None, str(controls(s)))

        s = play(4, *on, "-qbZoomCard", "Writer")
        check("a run started on the Mac turns the bar to Stop", controls(s).get("bar") == ["Stop"] and drawn(s, "Writer") == [], str(controls(s)))
        both("controls-10-running")
        s = play(4, *on, "-qbSelect", "Writer", "-qbPress", "start:Writer", also=lambda s: controls(s).get("asking"))
        check("restarting an agent that is working asks first", controls(s).get("asking") == "restart:Writer" and controls(s).get("details") == ["Restart agent"],
              str(controls(s)))
        mobile.shot("controls-11-restart-asks")

        s = play(5, *on, "-qbZoomCard", "Writer", "-qbSelect", "Writer")
        c = controls(s)
        check("an agent whose session has ended has Restart agent on its card",
              c.get("cards") == {"Writer": ["Restart agent"]} and drawn(s, "Writer") == [("Restart agent", True)]
              and c.get("details") == ["Run from here…", "Restart agent"] and c.get("bar") == ["Run"], f"{c} {drawn(s, 'Writer')}")
        both("controls-12-restart-agent")
        s = play(5, *on, "-qbSelect", "Writer", "-qbDo", "start:Writer", steps=1, also=lambda s: controls(s).get("cards") == {})
        check("pressed, the session starts and the button goes from the card", did(s) == [("start:Writer", None)] and controls(s).get("cards") == {}
              and controls(s).get("details") == ["Run from here…", "Restart agent"], str(controls(s)))

        s = play(6, *on, "-qbZoomCard", "Writer")
        c = controls(s)
        check("a flow whose sessions haven't been started offers to start them, and each agent's card to start its own",
              c.get("bar") == ["Start its agents", "Run"] and c.get("cards") == {"Writer": ["Start agent"]}, str(c))
        both("controls-13-start-agents")
        s = play(6, *on, "-qbDo", "startAgents", steps=1, also=lambda s: controls(s).get("bar") == ["Run"])
        check("asked to, the Mac starts them", did(s) == [("startAgents", None)] and controls(s).get("bar") == ["Run"] and controls(s).get("cards") == {}, str(controls(s)))
    finally:
        mobile.appearance("light")
        mobile.quit()


def scenario_typing():
    print("typing: the iPad app's message box and keys under a terminal, with a Mac made up inside the app", flush=True)
    if not os.path.exists(MOBILE_APP):
        print("  SKIP  the iPad app isn't built. Build it first: ./scripts/build-mobile.sh", flush=True)
        return
    udid = simulator()
    if udid is None:
        print("  SKIP  this Mac has no iOS 26 Simulator to run the iPad app in", flush=True)
        return
    mobile = Mobile(udid)
    print(f"        screenshots: {mobile.shots}", flush=True)
    # What `DebugCannedRun` in the app plays: at stage 1 the orchestrator is idle and Writer is waiting in its
    # terminal, at 4 Writer is working, at 5 its session has ended. The made-up Mac prints back what is typed.
    on = ("-qbControl", "1")
    writer, orchestrator = "writer01", "orchestrator"
    not_running, watch_only = "That session isn't running.", "can only watch"

    def composer(state):
        return state.get("composer") or {}

    def typing(state, name):
        return (composer(state).get("typing") or {}).get(name) or {}

    def did(state):
        return [(d["step"], d["refusal"]) for d in (state.get("controls") or {}).get("done", [])]

    def text(state, key):
        return "\n".join(((state.get("terminals") or {}).get(key) or {}).get("screen", []))

    def play(stage, *args, also=lambda s: True, steps=0):
        """Plays the made-up run to a stage, and waits for that many of the steps it was told to do."""
        mobile.launch("-qbCannedRun", str(stage), *args)
        return mobile.wait(lambda s: s.get("cannedStage") == stage and len((s.get("canvas") or {}).get("cards", [])) == 8
                           and len(did(s)) >= steps and also(s), 40, f"stage {stage} of the made-up run")

    def open_in(key, bar="viewer"):
        """True once that session's terminal is full screen with something under it."""
        return lambda s: s.get("expanded") == key and bar in composer(s).get("bars", {})

    def both(name):
        """The same screen in light and in dark."""
        mobile.shot(name + "-light")
        mobile.appearance("dark")
        mobile.shot(name + "-dark")
        mobile.appearance("light")

    def under(state, key):
        """Whether the bar is under the terminal and reaches the foot of the screen, or the top of the keyboard."""
        c = composer(state)
        bar, shown = c.get("bars", {}).get("viewer") or {}, ((state.get("terminals") or {}).get(key) or {})
        foot = (c.get("keyboard") or {}).get("y") or c.get("screen", {}).get("height", 0)
        return bool(bar) and bar["height"] >= 44 and abs(bar["y"] + bar["height"] - foot) <= 30 and shown.get("onScreen", {}).get("y", 1e9) < bar["y"]

    try:
        s = play(1, *on, "-qbExpand", "orchestrator", also=open_in(orchestrator))
        c = composer(s)
        check("allowed to control, a running session's terminal has a bar under it, with the message box first",
              typing(s, "orchestrator").get("bar") is True and c.get("mode") == "message" and c.get("drafts") == {} and typing(s, "orchestrator").get("line") is None, str(c))
        check("the bar is under the terminal, at the foot of the screen", under(s, orchestrator), f"{c.get('bars')} {c.get('keyboard')} {c.get('screen')}")
        check("nothing has the keyboard until it is asked for", c.get("catching") is False and c.get("wantsKeyboard") is False
              and not any(t["isFirstResponder"] for t in (s.get("terminals") or {}).values()), str(c))
        check("an idle session's box says nothing about waiting", typing(s, "orchestrator").get("note") is None, str(typing(s, "orchestrator")))
        check("a session waiting in its terminal says keys answer it, and one that is busy that the message will wait",
              typing(s, "Writer").get("wantsKeys") is True and "Keys" in (typing(s, "Writer").get("note") or ""), str(typing(s, "Writer")))
        both("typing-01-message-box-empty")

        lines = ["Please check the note again.", "Keep it under 100 words.", "Then tell me what you changed."]
        s = play(1, *on, "-qbExpand", "orchestrator", "-qbDo", "draft:orchestrator:" + "\\n".join(lines), steps=1, also=open_in(orchestrator))
        check("what is written is kept as the session's draft, and nothing is sent", composer(s).get("drafts") == {"orchestrator": len("\n".join(lines))} and composer(s).get("sent") == []
              and composer(s).get("commands") == 0, str(composer(s)))
        check("the bar grows with it and stays under the terminal", under(s, orchestrator) and composer(s)["bars"]["viewer"]["height"] > 130, str(composer(s).get("bars")))
        both("typing-02-message-box-draft")

        def dropped(state):
            return ((state.get("terminals") or {}).get(orchestrator) or {}).get("droppedReplies", 0)

        s = play(1, *on, "-qbExpand", "orchestrator", "-qbDo", "wait:a;say:orchestrator:Hello from the iPad", also=open_in(orchestrator))
        before = dropped(s)
        mobile.go("a")
        s = mobile.wait(lambda s: len(did(s)) >= 2 and "Hello from the iPad" in text(s, orchestrator) and dropped(s) > before, 20, "the message to be sent and printed back")
        check("Send sends the draft as one message, and the box is emptied", did(s)[1:] == [("say:orchestrator:Hello from the iPad", None)]
              and composer(s).get("sent") == ["prompt:orchestrator:19"] and composer(s).get("drafts") == {} and composer(s).get("refusals") == {}, str(composer(s)))
        check("and nothing else is sent", composer(s).get("commands") == 1 and composer(s).get("waiting") == [], str(composer(s)))
        check("what the session prints back shows in its terminal", "> Hello from the iPad" in text(s, orchestrator), text(s, orchestrator)[-200:])
        check("the terminal answered the question the program asked as it printed, and the answer went nowhere",
              dropped(s) > before and composer(s).get("commands") == 1 and not any(t["isFirstResponder"] for t in (s.get("terminals") or {}).values()),
              f"{before} answers dropped before, {dropped(s)} after; {composer(s).get('commands')} commands sent")
        mobile.shot("typing-03-message-sent")

        s = play(1, *on, "-qbStale", "1", "-qbExpand", "orchestrator", "-qbDo", "say:orchestrator:Are you there?", steps=1, also=open_in(orchestrator))
        check("a message the Mac refuses stays in the box, with the Mac's words", did(s) == [("say:orchestrator:Are you there?", not_running)]
              and composer(s).get("drafts") == {"orchestrator": 14} and composer(s).get("refusals") == {"orchestrator": not_running}, str(composer(s)))
        check("the bar is still under the terminal with the refusal in it", under(s, orchestrator), str(composer(s).get("bars")))
        both("typing-04-refusal")

        s = play(1, *on, "-qbExpand", "orchestrator", "-qbDo", "say:orchestrator:@16001", steps=1, also=open_in(orchestrator))
        check("a message over the limit is refused on the device, and never sent", "too long" in (did(s)[0][1] or "") and composer(s).get("sent") == []
              and composer(s).get("commands") == 0 and composer(s).get("drafts") == {"orchestrator": 16001}, str(composer(s))[:400])
        mobile.shot("typing-05-over-the-limit")
        s = play(1, *on, "-qbDo", "say:orchestrator:@16000", steps=1)
        check("one at the limit is sent", did(s)[0][1] is None and composer(s).get("sent") == ["prompt:orchestrator:16000"], str(composer(s))[:300])
        s = play(1, *on, "-qbDo", "say:orchestrator:  ", steps=1)
        check("and one that says nothing is not", "nothing to send" in (did(s)[0][1] or "") and composer(s).get("commands") == 0, str(did(s)))

        s = play(1, *on, "-qbDo", "draft:orchestrator:one;draft:Writer:three;open:Writer:message;close;open:orchestrator:message;away;pause", steps=5,
                 also=lambda s: typing(s, "orchestrator").get("away"))
        check("each session keeps its own draft, through closing its terminal and opening another",
              composer(s).get("drafts") == {"orchestrator": 3, "Writer": 5} and s.get("expanded") == orchestrator, str(composer(s)))
        check("and through losing the Mac: the box stays, and says it can't send now",
              typing(s, "orchestrator").get("bar") is True and typing(s, "orchestrator").get("away") is True
              and "kept" in (typing(s, "orchestrator").get("note") or ""), str(typing(s, "orchestrator")))
        mobile.shot("typing-06-away-draft-kept")

        keys = "type:Writer:1;key:Writer:ctrl;type:Writer:c;key:Writer:up;key:Writer:backtab;key:Writer:enter;type:Writer:é;key:Writer:ctrl-u;key:Writer:esc;key:Writer:backspace"
        s = play(1, *on, "-qbExpand", "Writer", "-qbKeys", "1", "-qbDo", keys, steps=10, also=open_in(writer))
        c = composer(s)
        check("opened with the keys out, the bar is in keys mode", c.get("mode") == "keys" and typing(s, "Writer").get("bar") is True, str(c))
        check("each key is sent at once as the bytes it makes: 1, Ctrl-C, up, Shift-Tab, Enter, é, Ctrl-U, Esc, Backspace",
              c.get("sent") == ["keys:Writer:" + h for h in ("31", "03", "1b5b41", "1b5b5a", "0d", "c3a9", "15", "1b", "7f")], str(c.get("sent")))
        check("and nothing else is", c.get("commands") == 9 and all(r is None for _, r in did(s)), f"{c.get('commands')} {did(s)}")
        check("the Ctrl button is let go by the key it went with", c.get("controlHeld") is False, str(c.get("controlHeld")))
        check("the app's own key catcher has the keyboard, and no terminal does", c.get("catching") is True
              and not any(t["isFirstResponder"] for t in (s.get("terminals") or {}).values()), str(c.get("catching")))
        check("the bar is under the terminal, above the keyboard if one is up", under(s, writer), f"{c.get('bars')} {c.get('keyboard')} {c.get('screen')}")
        check("what was typed shows in the terminal", "1é" in text(s, writer), text(s, writer)[-120:])
        print(f"        keyboard on screen: {c.get('keyboard')}; bar: {c.get('bars', {}).get('viewer')}; screen: {c.get('screen')}", flush=True)
        both("typing-07-keys")
        s = play(1, *on, "-qbExpand", "Writer", "-qbKeys", "1", "-qbDo", "key:Writer:ctrl", steps=1, also=open_in(writer))
        check("Ctrl waits for its letter, and sends nothing by itself", composer(s).get("controlHeld") is True and composer(s).get("commands") == 0, str(composer(s)))
        mobile.shot("typing-08-ctrl-held")

        s = play(1, *on, "-qbDo", "burst:Writer:quick brown", steps=1)
        check("keys pressed quickly go together, in the order they were pressed",
              composer(s).get("sent") == ["keys:Writer:" + "quick brown".encode().hex()], str(composer(s).get("sent")))
        s = play(1, *on, "-qbDo", "type:Writer:@5000", steps=1)
        check("more than fits one message is cut into messages that each fit", composer(s).get("sent") == ["keys:Writer:4096 bytes", "keys:Writer:904 bytes"]
              and did(s)[0][1] is None, str(composer(s).get("sent")))
        s = play(1, *on, "-qbStale", "1", "-qbExpand", "Writer", "-qbKeys", "1", "-qbDo", "type:Writer:@5000;key:Writer:enter", steps=2, also=open_in(writer))
        check("a refusal stops the keys that were waiting, and the Mac's words show once",
              composer(s).get("sent") == ["keys:Writer:4096 bytes", "keys:Writer:0d"] and [r for _, r in did(s)] == [not_running, not_running]
              and composer(s).get("refusals") == {"Writer": not_running}, str(composer(s)))
        mobile.shot("typing-09-keys-refused")

        s = play(1, *on, "-qbSelect", "Writer")
        c = (s.get("controls") or {})
        check("an agent waiting in its terminal is offered “Open its terminal”, and no longer sent to the Mac",
              composer(s).get("openTerminal") == ["Writer"] and c.get("answerLine") is None, f"{composer(s).get('openTerminal')} {c.get('answerLine')}")
        both("typing-10-open-its-terminal")
        s = play(1, *on, "-qbDo", "openWaiting:Writer", steps=1, also=open_in(writer))
        check("which opens it full screen in keys mode", s.get("expanded") == writer and composer(s).get("mode") == "keys" and composer(s).get("wantsKeyboard") is True,
              f"{s.get('expanded')} {composer(s)}")
        s = play(1, *on, "-qbDo", "openWaiting:Writer;close;open:orchestrator:message", steps=3, also=open_in(orchestrator))
        check("a terminal opened the usual way after that is back at the message box", composer(s).get("mode") == "message" and composer(s).get("wantsKeyboard") is False,
              str(composer(s)))

        s = play(1, *on, "-qbShow", "orchestrator", also=lambda s: "panel" in composer(s).get("bars", {}))
        panel = composer(s)["bars"].get("panel") or {}
        check("the orchestrator's panel has a message box of its own, beside the canvas", panel.get("height", 0) >= 44 and s.get("expanded") is None
              and panel.get("x", 0) > composer(s)["screen"]["width"] / 2, str(composer(s).get("bars")))
        both("typing-11-orchestrator-panel")
        s = play(1, *on, "-qbShow", "orchestrator", "-qbDo", "say:orchestrator:From the panel", steps=1, also=lambda s: "From the panel" in text(s, orchestrator))
        check("and a message sent from there reaches the orchestrator", did(s)[0][1] is None and composer(s).get("sent") == ["prompt:orchestrator:14"], str(composer(s)))
        check("the keyboard never comes from the canvas", composer(s).get("catching") is False, str(composer(s).get("catching")))

        s = play(4, *on, "-qbExpand", "Writer", also=open_in(writer))
        check("a session that is working says the message will be delivered when it is ready",
              typing(s, "Writer").get("bar") is True and "delivered when" in (typing(s, "Writer").get("note") or ""), str(typing(s, "Writer")))
        mobile.shot("typing-12-working")

        s = play(1, "-qbExpand", "orchestrator", also=open_in(orchestrator))
        t = typing(s, "orchestrator")
        check("a device that may only watch has no bar, and one line saying how to turn typing on",
              t.get("bar") is False and "Can control" in (t.get("line") or "") and t.get("action") is None and composer(s)["bars"]["viewer"]["height"] < 110, str(t))
        both("typing-13-cannot-control")
        s = play(1, "-qbDo", "say:orchestrator:Let me in;type:Writer:y", steps=2)
        check("typed anyway, the Mac refuses the message and the key, and the message is kept",
              all(watch_only in (r or "") for _, r in did(s)) and len(did(s)) == 2 and composer(s).get("drafts") == {"orchestrator": 9}, str(did(s)))
        s = play(1, "-qbShow", "orchestrator", also=lambda s: "panel" in composer(s).get("bars", {}))
        check("and the panel's box is gone too, with the same line", typing(s, "orchestrator").get("bar") is False, str(typing(s, "orchestrator")))
        mobile.shot("typing-14-panel-cannot-control")

        s = play(5, *on, "-qbExpand", "Writer", also=open_in(writer))
        t = typing(s, "Writer")
        check("a session that has ended has no bar: one line says so, with the way to start it again",
              t.get("bar") is False and t.get("line") == "This session isn't running." and t.get("action") == "Restart agent", str(t))
        both("typing-15-not-running")
        s = play(5, "-qbExpand", "Writer", also=open_in(writer))
        check("and no way to start it on a device that may only watch", typing(s, "Writer").get("action") is None and "Can control" in (typing(s, "Writer").get("line") or ""),
              str(typing(s, "Writer")))
        s = play(5, *on, "-qbDo", "say:Writer:Wake up;type:Writer:y", steps=2)
        check("typed anyway, both are refused in the Mac's words", [r for _, r in did(s)] == [not_running, not_running], str(did(s)))
        s = play(3, *on, "-qbViewRun", "0", "-qbExpand", "orchestrator", also=open_in(orchestrator))
        check("while an earlier run is on show there is no bar either", typing(s, "orchestrator").get("bar") is False
              and "latest run" in (typing(s, "orchestrator").get("line") or ""), str(typing(s, "orchestrator")))
        s = play(1, *on, "-qbExpand", "orchestrator", "-qbDo", "pause;control:off", also=lambda s: typing(s, "orchestrator").get("bar") is False)
        check("when “Can control” is turned off on the Mac the bar goes at once", typing(s, "orchestrator").get("bar") is False
              and "Can control" in (typing(s, "orchestrator").get("line") or ""), str(typing(s, "orchestrator")))
    finally:
        mobile.appearance("light")
        mobile.quit()


def scenario_scroll(app):
    print("scroll: wheel events pan the canvas unless a terminal has the keyboard", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    app.op(fid, "zoom", to=1.0)
    app.op(fid, "focus")
    time.sleep(0.5)

    def y():
        return app.state(fid)["canvas"]["y"]

    # A real event handed to the app is the fuller test. A window behind others may not get it,
    # and then the same events are given straight to the canvas's own scroll handling.
    y0 = y()
    app.op(fid, "scroll", dy=-160, mode="system")
    time.sleep(0.8)
    mode = "system" if abs(y() - y0) > 20 else "direct"
    print(f"        scroll events delivered by: {mode}", flush=True)
    if mode == "direct":
        app.op(fid, "scroll", dy=-160, mode=mode)
        time.sleep(0.6)
    y1 = y()
    check("scrolling over bare canvas pans it", abs(y1 - y0) > 20, f"y {y0} -> {y1}")
    app.op(fid, "scroll", card="Alice", dy=-160, mode=mode)
    time.sleep(0.6)
    y2 = y()
    check("scrolling over a terminal that isn't focused pans the canvas", abs(y2 - y1) > 20, f"y {y1} -> {y2}")
    app.op(fid, "scroll", dy=400, mode=mode)
    time.sleep(0.6)
    y3 = y()
    app.op(fid, "focus", card="Alice")
    time.sleep(0.6)
    s = app.state(fid)
    check("clicking into a terminal marks its card as focused", s["focusedCard"] == "Alice", str(s["focusedCard"]))
    app.op(fid, "scroll", card="Alice", dy=-160, mode=mode)
    time.sleep(0.6)
    y4 = y()
    check("scrolling over the focused terminal leaves the canvas where it is", abs(y4 - y3) < 1, f"y {y3} -> {y4}")
    app.op(fid, "focus")
    time.sleep(0.4)
    check("clicking empty canvas takes focus back", app.state(fid)["focusedCard"] is None)
    m0 = app.state(fid)["canvas"]["magnification"]
    app.op(fid, "zoom", to=0.5)
    time.sleep(0.3)
    m1 = app.state(fid)["canvas"]["magnification"]
    check("zoom changes the canvas's magnification", abs(m0 - 1.0) < 0.01 and abs(m1 - 0.5) < 0.01, f"{m0} -> {m1}")


def cpu_seconds(pid):
    """The processor time a process has used so far."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    total = 0.0
    for part in out.replace("-", ":").split(":"):
        total = total * 60 + float(part)
    return total


def scenario_mirror(app):
    print("mirror: a second terminal fed only what a paired device is sent shows the same as the real one", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)

    def count_to(first, last):
        """Has Alice print a long reply. Returns how long it took and how much of one processor the app used."""
        c0 = cpu_seconds(app.pid)
        seconds = globals()["count_to"](app, fid, "Alice", first, last)
        return seconds, 100 * (cpu_seconds(app.pid) - c0) / seconds

    def same(what, also=lambda c: True):
        """Checks the two screens match once the terminal has stopped changing."""
        deadline = time.time() + 12
        while True:
            c = app.op(fid, "mirror-compare", card="Alice")
            if (c["equal"] and also(c)) or time.time() > deadline:
                break
            time.sleep(0.5)
        real, mirror = c["real"], c["mirror"]
        rows = [i for i, (a, b) in enumerate(zip(real["screen"], mirror["screen"])) if a != b]
        detail = f"real {real['cols']}x{real['rows']} cursor {real['cursor']}, mirror {mirror['cols']}x{mirror['rows']} cursor {mirror['cursor']}"
        if rows:
            detail += f", {len(rows)} rows differ, first is row {rows[0]}: {real['screen'][rows[0]]!r} against {mirror['screen'][rows[0]]!r}"
        check(what, c["equal"] and also(c), detail)
        return c

    seconds, alone = count_to(1, 200)
    print(f"        no mirror: {seconds:.1f}s, app at {alone:.1f}% of a processor", flush=True)
    # The mirror joins late: the first reply is already on screen.
    app.op(fid, "mirror", card="Alice")
    time.sleep(2)
    c = same("a mirror opened part-way through shows the same screen")
    print(f"        the first chunk was {c['snapshotBytes']} bytes; history matches: {c['historyEqual']} "
          f"({c['real']['scrollback']} lines against {c['mirror']['scrollback']})", flush=True)

    seconds, mirrored = count_to(201, 400)
    c = same("it still shows the same after another long reply")
    check("the mirror can scroll back through earlier output", c["mirror"]["scrollback"] > 0 and c["mirror"]["scrollback"] == c["real"]["scrollback"],
          f"real {c['real']['scrollback']} lines, mirror {c['mirror']['scrollback']}")
    check("the earlier output is the same too", c["historyEqual"])
    print(f"        mirror open: {seconds:.1f}s, app at {mirrored:.1f}% of a processor; {c['chunks']} chunks, {c['bytes']} bytes, "
          f"{c['chunks'] / seconds:.1f} chunks a second, {c['bytes'] / max(1, c['chunks']):.0f} bytes a chunk, largest {c['largest']}", flush=True)

    cols = c["real"]["cols"]
    app.op(fid, "resize", card="Alice", width=660, height=420)
    c = same("it shows the same after the card is resized", also=lambda c: c["real"]["cols"] != cols)
    check("the resize reached the terminal and the mirror started again at the new size", c["real"]["cols"] != cols and c["resets"] >= 1,
          f"{cols} columns before, {c['real']['cols']} after, {c['resets']} fresh starts")
    print(f"        after the resize the first chunk would be {c['snapshotBytes']} bytes; history matches: {c['historyEqual']} "
          f"({c['real']['scrollback']} lines against {c['mirror']['scrollback']})", flush=True)

    # What the feed costs by itself: the chunks are counted and nothing is drawn. The kept output is
    # made small for this reply, so the mirror opened after it starts from output with its beginning gone.
    app.op(fid, "mirror", card="Alice", shown=False)
    app.op(fid, "mirror-limit", card="Alice", bytes=3000)
    seconds, counted = count_to(401, 600)
    c = app.op(fid, "mirror-compare", card="Alice")
    print(f"        chunks only counted: {seconds:.1f}s, app at {counted:.1f}% of a processor; {c['chunks'] / seconds:.1f} chunks a second, "
          f"{c['bytes'] / max(1, c['chunks']):.0f} bytes a chunk", flush=True)
    check("following the terminal costs little", counted - alone < 10, f"{alone:.1f}% without, {counted:.1f}% with")
    app.op(fid, "mirror", card="Alice")
    time.sleep(2)
    c = same("a mirror opened after the oldest output was dropped shows the same screen")
    check("only the newest output was kept", c["snapshotBytes"] < 8000, f"{c['snapshotBytes']} bytes")
    app.op(fid, "mirror-limit", card="Alice", bytes=512 * 1024)

    cols = c["real"]["cols"]
    app.op(fid, "resize", card="Alice", width=400, height=300)
    c = same("it shows the same after the card is made narrower", also=lambda c: c["real"]["cols"] < cols)
    print(f"        after narrowing the mirror has {c['mirror']['scrollback']} lines of history against {c['real']['scrollback']}", flush=True)
    app.op(fid, "mirror-close")
    # Back to the size it was written with. `mobile` runs on the same flow, and checks each card against that.
    app.op(fid, "resize", card="Alice", width=480, height=300)


def scenario_pan(app):
    print("pan: a link held at the canvas's edge pans it to a card out of view", flush=True)
    fid = PAN["id"]
    app.open_flow(PAN)
    app.op(fid, "fit", card="Near")
    time.sleep(1)
    app.op(fid, "zoom", to=1.0)
    time.sleep(0.3)
    before = app.state(fid)["canvas"]
    check("the far card starts out of view", before["x"] + before["width"] < 4000, str(before))
    app.op(fid, "edgeLink", card="Near", to="Far", edge="right")
    s = app.state(fid)
    after = s["canvas"]
    check("holding a link at the right edge pans the canvas", after["x"] > before["x"] + 1000, f"x {before['x']} -> {after['x']}")
    check("it pans along the edge's axis only", abs(after["y"] - before["y"]) < 1, f"y {before['y']} -> {after['y']}")
    check("the link lands on the card that panned into view", s["links"] == 1, str(s["links"]))
    app.op(fid, "edgeLink", card="Far", to="Far", edge="top")
    top = app.state(fid)["canvas"]["y"]
    check("panning stops at the canvas's limit", abs(top + 3000) < 1, str(top))
    # The two cards are further apart than the usual 20% floor can show between the panels.
    app.op(fid, "fit")
    time.sleep(1.5)
    c = app.state(fid)["canvas"]
    check("zoom to fit shows a wide flow whole, clear of the panels", c["clearFrom"] <= 300 and c["clearTo"] >= 4240, str(c))
    wide = c["magnification"]
    for dy in (-40, 40):
        app.op(fid, "scroll", dy=dy, mode="direct", command=True)
    check("the wheel doesn't zoom further out than the fit", app.state(fid)["canvas"]["magnification"] >= wide - 0.001, str(app.state(fid)["canvas"]))
    app.op(fid, "zoom", to=1.0)
    time.sleep(0.3)
    app.op(fid, "zoom", to=0.05)
    time.sleep(0.3)
    check("zooming by hand still stops at 20%", abs(app.state(fid)["canvas"]["magnification"] - 0.2) < 0.01, str(app.state(fid)["canvas"]))


def scenario_fanout(app):
    print("fanout: eight agents at once, And waits for all, Or takes the first", flush=True)
    fid = FANOUT["id"]
    started = time.time()
    app.open_flow(FANOUT, timeout=240)
    check("nine sessions (eight agents and the orchestrator) all came up", True, f"{time.time() - started:.0f}s")
    print(f"        sessions ready in {time.time() - started:.0f}s", flush=True)
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and "All" in s["results"], 240, "the fan-out run to finish")
    everything = s["results"].get("All", "")
    check("And passed on all eight answers together", all(w in everything for w in WORDS), everything[:300])
    first = s["results"].get("First", "")
    check("Or passed on exactly one answer", sum(w in first for w in WORDS) == 1, first[:200])
    dropped = sum("dropped a later reply" in line for line in s["log"])
    check("Or dropped the seven later answers", dropped == 7, f"dropped {dropped}")
    check("the run ended on its own", not s["isRunning"])
    marks = s["marks"]
    check("the And card shows one pass and nothing held", marks.get("Everyone", {}).get("passes") == 1 and marks["Everyone"]["holding"] == 0,
          str(marks.get("Everyone")))
    check("the Or card shows one passed on and seven dropped", marks.get("Fastest", {}).get("passes") == 1 and marks["Fastest"]["holding"] == 7,
          str(marks.get("Fastest")))
    check("every worker shows one reply", all(marks.get(f"W{i + 1}", {}).get("passes") == 1 for i in range(8)))
    check("no link is still marked live after the run", s["liveLinks"] == 0, str(s["liveLinks"]))


def scenario_switch(app):
    print("switch: Claude picks the branch a message belongs to", flush=True)
    fid = SWITCH["id"]
    app.open_flow(SWITCH)
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and "Out" in s["results"], 180, "the bug run to finish")
    check("a crash report went out the bug branch", any('Switch "Triage" → bug' in line for line in s["log"]), str(s["log"][-5:]))
    check("the bug agent's answer reached End", "BUG-HANDLED" in s["results"]["Out"], s["results"]["Out"][:200])
    check("the other branch's agent was left alone", s["sessions"]["Planner"]["lastReply"] is None)
    check("the Switch card shows the branch it took", s["marks"].get("Triage", {}).get("lastPort") == "bug", str(s["marks"].get("Triage")))
    check("the untaken branch's agent has no run mark", "Planner" not in s["marks"], str(s["marks"].get("Planner")))
    before = len(s["log"])
    app.op(fid, "run", command="Please add a dark mode option to the settings screen.")
    s = app.wait(fid, lambda s: not s["isRunning"] and "FEATURE" in s["results"].get("Out", ""), 180, "the feature run to finish")
    check("a feature request went out the feature branch", any('Switch "Triage" → feature' in line for line in s["log"][before:]), str(s["log"][before:]))


def scenario_loop(app):
    print("loop: goes round until its condition holds", flush=True)
    fid = LOOP["id"]
    app.open_flow(LOOP)
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and "Out" in s["results"], 240, "the loop run to finish")
    log = s["log"]
    check("the loop sent the agent round twice", sum("→ Again" in line for line in log) == 2, str([l for l in log if "Loop" in l]))
    check("the loop left by Done once the condition held", any('Loop "Enough?" → Done' == line for line in log), str([l for l in log if "Loop" in l]))
    check("the final answer is the third reply", s["results"]["Out"].strip().endswith("XXX") and "XXXX" not in s["results"]["Out"], s["results"]["Out"][:100])
    marks = s["marks"]
    check("the agent's card counts three replies", marks.get("Counter", {}).get("passes") == 3, str(marks.get("Counter")))
    check("the Loop card counts each output", marks.get("Enough?", {}).get("ports") == {"again": 2, "done": 1}
          and marks["Enough?"]["lastPort"] == "done", str(marks.get("Enough?")))
    check("the End card counts one arrival", marks.get("Out", {}).get("arrivals") == 1, str(marks.get("Out")))
    check("link pass counts match the route taken", sorted(s["linkPasses"]) == [1, 1, 2, 3], str(s["linkPasses"]))


def scenario_exit(app):
    print("exit: a session dying mid-run stops the run and says why", flush=True)
    fid = EXIT["id"]
    app.open_flow(EXIT)
    app.op(fid, "run")
    app.wait(fid, lambda s: s["sessions"]["Sleeper"]["state"] in ("working", "needsYou"), 60, "Sleeper to start working")
    time.sleep(4)
    app.op(fid, "kill", card="Sleeper")
    try:
        s = app.wait(fid, lambda s: not s["isRunning"], 30, "the run to stop after the session died")
    except TimeoutError as e:
        check("the run stopped when the session died", False, str(e)[:300])
        return
    check("the run stopped when the session died", True)
    check("the log says which agent failed", any("Sleeper failed" in line for line in s["log"]), str(s["log"][-4:]))
    check("the card shows the session as exited", s["sessions"]["Sleeper"]["state"] == "exited", s["sessions"]["Sleeper"]["state"])
    check("the card where the run stopped is marked failed", s["marks"].get("Sleeper", {}).get("failed") is True and s["activity"] == "failed",
          f"{s['marks'].get('Sleeper')} {s['activity']}")
    app.op(fid, "restart", card="Sleeper")
    try:
        app.wait(fid, lambda s: s["sessions"]["Sleeper"]["state"] == "idle", 90, "Sleeper to come back")
        check("Restart brings the session back", True)
    except TimeoutError as e:
        check("Restart brings the session back", False, str(e)[:300])


def scenario_ask(app):
    print("ask: a turn that ends on a question to the orchestrator isn't passed on as the answer", flush=True)
    fid = ASK["id"]
    app.open_flow(ASK)
    app.wait(fid, lambda s: s["orchestrator"]["state"] == "idle", 90, "the orchestrator to be ready")
    app.op(fid, "run")
    try:
        s = app.wait(fid, lambda s: any("asked a question" in line for line in s["log"]), 120, "Asker to ask its question")
    except TimeoutError as e:
        check("the question turn is held back", False, str(e)[:400])
        return
    check("the question turn is held back", s["isRunning"] and not s["results"], f"{s['isRunning']} {s['results']}")
    check("the log says the run hangs on the question", any("waiting on Asker" in line for line in s["log"]), str(s["log"][-4:]))
    try:
        s = app.wait(fid, lambda s: not s["isRunning"], 180, "the run to end once the orchestrator answered")
    except TimeoutError as e:
        check("the reply after the answer is what goes on", False, str(e)[:400])
        app.op(fid, "stop")
        return
    # The link out of Asker allows one pass, so this only holds if the question turn didn't spend it.
    check("the reply after the answer is what goes on", "BANANA" in s["results"].get("Out", ""), str(s["results"]))
    check("nothing is left marked as waiting for an answer", s["awaitingAnswer"] == [], str(s["awaitingAnswer"]))


def scenario_apifail(app):
    print("apifail: a turn that ends in an API error stops the run", flush=True)
    fid = APIFAIL["id"]
    app.wait(fid, lambda s: "sessions" in s, 30, "the flow to load")
    app.op(fid, "select")
    s = app.wait(fid, lambda s: s["sessions"]["Broken"]["state"] in ("idle", "exited", "failed"), 90, "Broken's session to settle")
    print(f"        a session with an unknown model starts as: {s['sessions']['Broken']['state']}", flush=True)
    app.op(fid, "run")
    try:
        s = app.wait(fid, lambda s: not s["isRunning"] and any("failed" in line for line in s["log"]), 120, "the run to stop")
    except TimeoutError as e:
        check("the run stopped when the turn failed", False, str(e)[:400])
        return
    check("the run stopped when the turn failed", True)
    check("the log says which agent failed and why", any("Broken failed" in line for line in s["log"]), str(s["log"][-4:]))
    print(f"        card state afterwards: {s['sessions']['Broken']['state']}; log: {s['log'][-2:]}", flush=True)
    check("the card shows failed or exited", s["sessions"]["Broken"]["state"] in ("failed", "exited"), s["sessions"]["Broken"]["state"])


GATES = flow("Gates", [
    card("start", "Start", 0, 0, command="hello from the start card"),
    card("script", "Shout", 312, 0, command="tr a-z A-Z"),
    card("approval", "Check it", 624, 0, text="Is this loud enough?"),
    card("end", "Done", 936, 0),
    card("end", "Binned", 936, 192),
    card("start", "Start 2", 0, 384, command="second start"),
    card("end", "Other", 312, 384),
], [("Start", "out", "Shout", 9), ("Shout", "pass", "Check it", 9), ("Check it", "approved", "Done", 9),
    ("Check it", "rejected", "Binned", 9), ("Shout", "fail", "Binned", 9), ("Start 2", "out", "Other", 9)])

INNER = flow("Inner", [
    card("start", "Input", 0, 0, command="try me"),
    card("script", "Loud", 312, 0, command="tr a-z A-Z"),
    card("end", "Output", 624, 0),
], [("Input", "out", "Loud", 9), ("Loud", "pass", "Output", 9)])
INNER["isSubflow"] = True

OUTER = flow("Outer", [
    card("start", "Start", 0, 0, command="make this loud"),
    card("flow", "Shouter", 312, 0, flowRef="Inner"),
    card("end", "Done", 624, 0),
    card("end", "Failed", 624, 192),
    card("flow", "Empty", 0, 384),
], [("Start", "out", "Shouter", 9), ("Shouter", "done", "Done", 9), ("Shouter", "fail", "Failed", 9)])

TIMED = flow("Timed", [
    card("start", "Clock", 0, 0, command="tick"),
    card("end", "Rang", 312, 0),
    card("start", "Shipped", 0, 240, command="came with the file"),
    card("end", "Never", 312, 240),
], [("Clock", "out", "Rang", 9), ("Shipped", "out", "Never", 9)])
# A schedule that arrives in the file. Nobody on this Mac agreed to it, so it must stay off.
TIMED["cards"][2]["trigger"] = {"kind": "interval", "minutes": 1, "hour": 9, "minute": 0, "weekdays": [2], "path": ""}


FLOWS.update({"gates": GATES, "inner": INNER, "subflow": OUTER, "timed": TIMED})


def held(app, fid, card=None, timeout=20):
    """Waits until a message is held, at `card` if one is named: a script that is still running holds one too."""
    return app.wait(fid, lambda s: s["holds"] and (card is None or s["holds"][0]["card"] == card), timeout,
                    f"a message to be held at {card or 'a card'}")["holds"]


def scenario_gates(app):
    print("gates: Script and Approval cards, run history, run from here, several Start cards", flush=True)
    fid = GATES["id"]
    app.op(fid, "select")
    time.sleep(2)
    app.op(fid, "run")
    h = held(app, fid)
    check("a command that came in the file waits to be allowed", h[0]["card"] == "Shout" and h[0]["needsAllow"], str(h))
    app.op(fid, "hold", answer="allow")
    h = app.wait(fid, lambda s: s["holds"] and s["holds"][0]["card"] == "Check it", 20, "the approval")["holds"]
    check("the script's output reaches the approval", h[0]["text"] == "HELLO FROM THE START CARD", str(h))
    app.op(fid, "hold", answer="approve", text="HELLO, EDITED")
    answered = time.time()
    while not any("→ Approved" in line for line in app.state(fid)["log"]) and time.time() - answered < 20:
        time.sleep(0.1)
    check("an approval takes effect at once", time.time() - answered < 2, f"{time.time() - answered:.1f}s")
    s = app.wait(fid, lambda s: not s["isRunning"], 20, "the run to end")
    check("an approved, edited message goes on to Done", s["results"] == {"Done": "HELLO, EDITED"}, str(s["results"]))
    check("the links recorded what they carried", s["messages"] == 3, str(s["messages"]))

    app.op(fid, "run")
    h = held(app, fid, "Check it")
    check("an allowed command runs without asking again", h[0]["card"] == "Check it" and not h[0]["needsAllow"], str(h))
    app.op(fid, "hold", answer="reject", text="Too loud")
    s = app.wait(fid, lambda s: not s["isRunning"], 20, "the run to end")
    binned = s["results"].get("Binned", "")
    check("a rejected message goes out Rejected with the reason ahead of it",
          list(s["results"]) == ["Binned"] and binned.startswith("Too loud\n") and binned.endswith("\nHELLO FROM THE START CARD"), str(s["results"]))
    check("both runs are kept", [r["outcome"] for r in s["runs"]] == ["finished", "finished"], str(s["runs"]))

    first = s["runs"][0]["id"]
    app.op(fid, "viewRun", run=first)
    s = app.state(fid)
    check("an earlier run can be put back on the canvas", s["viewedRun"] == first and s["results"] == {"Done": "HELLO, EDITED"}, str(s["results"]))
    app.op(fid, "viewRun")
    check("and the latest brought back", app.state(fid)["results"] == {"Binned": binned})

    app.op(fid, "runFrom", card="Check it", message="straight to the gate")
    h = held(app, fid, "Check it")
    check("a run can start at any card", h[0]["card"] == "Check it" and h[0]["text"] == "straight to the gate", str(h))
    app.op(fid, "stop")
    s = app.wait(fid, lambda s: not s["isRunning"], 20, "the run to stop")
    check("stopping a run lets go of what was held", not s["holds"] and s["runs"][-1]["outcome"] == "stopped", f"{s['holds']} {s['runs'][-1]}")

    app.op(fid, "pick", card="Start 2")
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and s["results"], 20, "the second start's run")
    check("Run starts from the selected Start card", s["results"] == {"Other": "second start"}, str(s["results"]))
    app.op(fid, "pick")

    app.op(fid, "script", card="Shout", command="echo typed")
    app.op(fid, "run")
    h = held(app, fid, "Check it")
    check("a command typed in the settings runs without asking", h[0]["card"] == "Check it" and h[0]["text"] == "typed", str(h))
    app.op(fid, "pick", card="Check it")
    app.op(fid, "delete")
    s = app.wait(fid, lambda s: not s["isRunning"], 20, "the run to end when its card is deleted")
    check("deleting a card that holds a message ends the run", not s["holds"] and "Check it" not in [c["name"] for c in s["cards"]], str(s["holds"]))
    app.op(fid, "undo")
    check("undo brings the card and its links back", "Check it" in [c["name"] for c in app.state(fid)["cards"]] and app.state(fid)["links"] == 6)

    app.op(fid, "script", card="Shout", command="exit 3")
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and s["results"], 20, "the failing command's run")
    check("a command that fails goes out Fail", "Binned" in s["results"], str(s["results"]))

    before = {c["name"]: (c["x"], c["y"]) for c in s["cards"]}
    app.op(fid, "tidy")
    s = app.state(fid)
    xs = {c["name"]: c["x"] for c in s["cards"]}
    check("Tidy Up lays cards out in the order the links run", xs["Start"] < xs["Shout"] < xs["Check it"] < xs["Done"], str(xs))
    app.op(fid, "undo")
    check("and undo puts them back", {c["name"]: (c["x"], c["y"]) for c in app.state(fid)["cards"]} == before)

    app.op(fid, "pickMany", cards=["Shout", "Check it"])
    app.op(fid, "group")
    s = app.state(fid)
    check("selected cards can be grouped", s["groups"] == [{"name": "Group 1", "cards": 2, "folded": False}], str(s["groups"]))
    app.op(fid, "fold", folded=True)
    check("a group can be folded", app.state(fid)["groups"][0]["folded"] is True)
    app.op(fid, "pick", card="Shout")
    app.op(fid, "delete")
    check("a group left with one card is no longer a group", app.state(fid)["groups"] == [], str(app.state(fid)["groups"]))
    app.op(fid, "undo")
    check("undo restores the group", len(app.state(fid)["groups"]) == 1)


def scenario_subflow(app):
    print("subflow: a Flow card runs another flow, and opening one makes or enters a sub-flow", flush=True)
    fid, inner = OUTER["id"], INNER["id"]
    app.op(fid, "select")
    time.sleep(2)
    check("a flow set by name is found", app.state(fid)["canRun"])
    app.op(fid, "run")
    h = held(app, inner)
    check("the message reaches the inner flow", h[0]["card"] == "Loud" and h[0]["text"] == "make this loud", str(h))
    app.op(inner, "hold", answer="allow")
    s = app.wait(fid, lambda s: not s["isRunning"], 30, "the outer run to end")
    check("the inner flow's answer comes back out Done", s["results"] == {"Done": "MAKE THIS LOUD"}, str(s["results"]))
    check("the inner flow kept its own run", len(app.state(inner)["runs"]) == 1)

    app.op(inner, "script", card="Loud", command="exit 1")
    app.op(fid, "run")
    s = app.wait(fid, lambda s: not s["isRunning"] and s["results"], 30, "the outer run to end")
    check("an inner flow that never reaches its Output comes out Fail", list(s["results"]) == ["Failed"], str(s["results"]))

    r = app.op(fid, "tool", name="create_subflow", arguments={"name": "Made"})
    s = app.state(fid)
    check("the orchestrator can make a sub-flow below its flow", not r["isError"] and "Made" in s["flows"] and "Made" in [c["name"] for c in s["cards"]], str(r))
    r = app.op(fid, "tool", name="add_card", arguments={"in_flow": "Made", "kind": "script", "name": "Step", "command": "echo hi"})
    check("and build inside it", not r["isError"], str(r))
    r = app.op(fid, "tool", name="get_flow", arguments={"in_flow": "Made"})
    check("its cards are the sub-flow's", not r["isError"] and '"Step"' in r["text"] and '"Input"' in r["text"], r["text"][:200])
    r = app.op(fid, "tool", name="create_subflow", arguments={"in_flow": "Made", "name": "Deeper"})
    check("and make a sub-flow a level further down", not r["isError"] and "Deeper" in app.state(fid)["flows"], str(r))
    r = app.op(fid, "tool", name="get_flow", arguments={})
    check("it is told what sits below it", '"Deeper"' in r["text"] and '"levels_down":2' in r["text"].replace(" ", ""), r["text"][-300:])
    r = app.op(inner, "tool", name="add_card", arguments={"in_flow": "Outer", "kind": "note"})
    check("a sub-flow's orchestrator can't reach the flow above it", r["isError"] and "above or beside" in r["text"], str(r))
    r = app.op(inner, "tool", name="get_flow", arguments={"in_flow": "Made"})
    check("or a flow beside it", r["isError"], str(r))

    app.op(fid, "pick")
    moved_from = [c for c in app.state(fid)["cards"] if c["name"] == "Done"][0]
    app.op(fid, "drag", card="Done", dx=120, dy=96)
    s = app.state(fid)
    moved_to = [c for c in s["cards"] if c["name"] == "Done"][0]
    check("dragging a card moves it", (moved_to["x"], moved_to["y"]) != (moved_from["x"], moved_from["y"]), f"{moved_from} {moved_to}")
    check("without selecting it, so its settings stay shut", s["selected"] == [] and s["undo"] == "Move", f"{s['selected']} {s['undo']}")

    r = app.op(fid, "openSub", card="Shouter")
    check("opening a Flow card goes into its flow", r == {"now": "Inner", "trail": 2}, str(r))
    r = app.op(inner, "back")
    check("and the trail leads back", r == {"now": "Outer"}, str(r))
    r = app.op(fid, "openSub", card="Empty")
    check("a Flow card with no flow gets a new sub-flow", r == {"now": "Empty", "trail": 2}, str(r))
    s = app.state(fid)
    check("the new sub-flow joins the project", "Empty" in s["flows"], str(s["flows"]))
    app.op(fid, "select")


def scenario_timed(app):
    print("timed: schedules and file triggers start runs, and one that came in a file stays off", flush=True)
    fid = TIMED["id"]
    app.op(fid, "select")
    time.sleep(2)
    s = app.state(fid)
    check("a schedule that arrived in the flow's file is off", s["armed"] == [] and s["scheduled"] == 0, f"{s['armed']} {s['scheduled']}")
    folder = os.path.join(app.project, "inbox")
    os.makedirs(folder, exist_ok=True)
    app.op(fid, "trigger", card="Clock", path="inbox")
    time.sleep(2)
    with open(os.path.join(folder, "new.txt"), "w") as out:
        out.write("x")
    s = app.wait(fid, lambda s: s["results"].get("Rang"), 30, "the file trigger to start a run")
    check("a changed file starts a run and names the file", "inbox" in s["results"]["Rang"], s["results"]["Rang"])
    now = time.localtime(time.time() + 60)
    app.op(fid, "trigger", card="Clock", hour=now.tm_hour, minute=now.tm_min)
    check("a daily schedule set here is on", app.state(fid)["armed"] == ["Clock"] and app.state(fid)["scheduled"] == 1)
    runs = len(app.state(fid)["runs"])
    s = app.wait(fid, lambda s: len(s["runs"]) > runs, 75, "the daily schedule to fire")
    check("the schedule starts a run at its time", s["results"].get("Rang") == "tick", str(s["results"]))
    check("the schedule that came in the file never ran", "Never" not in s["results"])
    app.op(fid, "trigger", card="Clock")


def level(n, last=4):
    """One link in a chain of flows that each run the next. The last just passes its message to its Output."""
    if n == last:
        return flow(f"Level{n}", [card("start", "Input", 0, 0, command="alone"), card("end", "Output", 312, 0)], [("Input", "out", "Output", 9)])
    cards = [card("start", "Input", 0, 0, command="go"), card("flow", "Next", 312, 0, flowRef=f"Level{n + 1}"), card("end", "Output", 624, 0)]
    links = [("Input", "out", "Next", 9), ("Next", "done", "Output", 9)]
    if n == 0:
        cards.append(card("end", "Failed", 624, 192))
        links.append(("Next", "fail", "Failed", 9))
    return flow(f"Level{n}", cards, links)


LEVELS = [level(n) for n in range(5)]
FLOWS.update({f"level{n}": f for n, f in enumerate(LEVELS)})


def scenario_deep(app):
    print("deep: sub-flows nest as far as the limit and no further", flush=True)
    ids = [f["id"] for f in LEVELS]
    app.op(ids[1], "select")
    time.sleep(2)
    s = app.state(ids[4])
    check("each flow knows how far down it sits", s["levelsLeft"] == -1 and app.state(ids[1])["levelsLeft"] == 2, str(s["levelsLeft"]))
    app.op(ids[0], "select")
    app.op(ids[0], "run")
    s = app.wait(ids[0], lambda s: not s["isRunning"] and s["runs"], 40, "the run to end")
    check("with the usual limit of three, a fourth level is not run", list(s["results"]) == ["Failed"] and not app.state(ids[4])["runs"], str(s["results"]))
    check("the flow at the limit took the Fail output", any("Fail" in line for line in app.state(ids[3])["log"]), str(app.state(ids[3])["log"][-3:]))

    app.op(ids[0], "limit", levels=4)
    check("raising the top flow's limit gives every level below one more", app.state(ids[4])["levelsLeft"] == 0)
    app.op(ids[0], "run")
    s = app.wait(ids[0], lambda s: not s["isRunning"] and len(s["runs"]) == 2, 40, "the four-level run to end")
    check("and the run then goes four levels down", s["results"] == {"Output": "go"}, str(s["results"]))

    app.op(ids[0], "limit", levels=1)
    check("lowering it below what is built deletes nothing", app.state(ids[1])["levelsLeft"] == 0 and len(app.state(ids[0])["flows"]) >= 5)
    app.op(ids[0], "run")
    s = app.wait(ids[0], lambda s: not s["isRunning"] and len(s["runs"]) == 3, 40, "the one-level run to end")
    check("but a run stops at the new limit", list(s["results"]) == ["Failed"] and len(app.state(ids[2])["runs"]) == 2, f"{s['results']} {len(app.state(ids[2])['runs'])}")
    app.op(ids[1], "run")
    s = app.wait(ids[1], lambda s: not s["isRunning"] and len(s["runs"]) >= 3, 40, "the sub-flow's own run to end")
    check("a sub-flow run by itself is held to the top flow's limit too", not s["results"], str(s["results"]))
    app.op(ids[0], "limit", levels=3)

    r = app.op(ids[4], "tool", name="create_subflow", arguments={"name": "Too far"})
    check("at the limit the orchestrator is told no more sub-flows can be added", r["isError"] and "no more sub-flows can be added" in r["text"]
          and "Too far" not in app.state(ids[4])["flows"], str(r))
    r = app.op(ids[4], "tool", name="add_card", arguments={"kind": "flow", "name": "Deeper"})
    check("the orchestrator can't add a Flow card below the limit", r["isError"] and "deeper" in r["text"], str(r))
    r = app.op(ids[3], "tool", name="update_card", arguments={"card": "Next", "flow": "Level0"})
    check("or point a Flow card at a flow that isn't below it", r["isError"] and "below" in r["text"], str(r))
    r = app.op(ids[2], "tool", name="get_flow", arguments={})
    check("and is told how many levels it has left", '"sub_flow_levels_left":1' in r["text"].replace(" ", ""), r["text"][-160:])
    # Mouse navigation, on a canvas with no terminals to get in the way.
    app.op(ids[1], "select")
    time.sleep(1)
    app.op(ids[1], "zoom", to=1.0)
    app.op(ids[1], "scroll", dy=40, mode="direct", command=True)
    zoomed = app.state(ids[1])["canvas"]["magnification"]
    check("Command and the scroll wheel zoom in", zoomed > 1.05, str(zoomed))
    app.op(ids[1], "scroll", dy=-80, mode="direct", command=True)
    check("and out", app.state(ids[1])["canvas"]["magnification"] < zoomed, str(app.state(ids[1])["canvas"]["magnification"]))
    before = app.state(ids[1])["canvas"]
    app.op(ids[1], "scroll", dy=-60, mode="direct")
    after = app.state(ids[1])["canvas"]
    check("the wheel alone still pans", abs(after["y"] - before["y"]) > 1 and abs(after["magnification"] - before["magnification"]) < 0.001, f"{before} {after}")

    app.op(ids[4], "select")
    app.op(ids[4], "add", kind="flow")
    r = app.op(ids[4], "openSub", card="Flow")
    check("double-clicking a Flow card at the limit makes no sub-flow", r["now"] == "Level4" and "deeper" in (app.state(ids[4])["banner"] or ""), str(r))
    for i in ids:
        app.op(i, "close")


def scenario_noclaude(project):
    print("noclaude: the app says so when Claude Code isn't installed", flush=True)
    empty = tempfile.mkdtemp(prefix="qb-nohome-")
    support = SUPPORT + "-nc"
    app = App(project, support=support, env={"HOME": empty, "CFFIXED_USER_HOME": empty, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
    try:
        deadline = time.time() + 40
        s = {}
        while time.time() < deadline:
            s = call(support, "*", {"op": "app"})
            if s.get("environmentReady"):
                break
            time.sleep(0.5)
        check("the app finished looking for claude", s.get("environmentReady") is True, str(s))
        check("it reports that Claude Code isn't installed", "can't find Claude Code" in (s.get("problem") or ""), str(s))
    finally:
        app.quit()


def main():
    wanted = sys.argv[1:] or ["guard", "settings", "remote", "scroll", "pan", "fanout", "switch", "loop", "exit", "apifail", "ask", "gates", "subflow", "timed", "deep", "noclaude"]
    if not os.path.exists(APP):
        sys.exit("Build the app first: ./scripts/build.sh")
    sweep()
    project = tempfile.mkdtemp(prefix="qb-e2e-")
    # Guard is written first so it is the flow the app opens on, and the others wait their turn.
    for i, name in enumerate(["guard", "pan", "fanout", "switch", "loop", "exit", "apifail", "ask", "gates", "inner", "subflow", "timed"]
                             + [f"level{n}" for n in range(5)] + ["doors"]):
        write(project, i, FLOWS[name])
    print(f"project: {project}", flush=True)

    in_app = [w for w in wanted if w not in ("noclaude", "terminals", "panels", "controls", "typing")]
    if in_app:
        app = App(project)
        try:
            for name in in_app:
                try:
                    globals()[f"scenario_{name}"](app)
                except Exception as e:  # one scenario failing shouldn't hide the others
                    check(f"{name} ran to the end", False, f"{type(e).__name__}: {e}"[:500])
                if name == "deep":
                    continue
                flow_id = (GUARD if name in ("scroll", "settings", "remote", "mirror", "mobile") else FLOWS[name])["id"]
                if name == "subflow":
                    app.op(INNER["id"], "close")
                # Guard's sessions are shared by the scenarios that follow it on the same flow.
                later = in_app[in_app.index(name) + 1:]
                if not (name in ("guard", "settings", "remote") and any(n in later for n in ("settings", "remote", "scroll", "mobile"))):
                    app.op(flow_id, "close")
        finally:
            app.quit()
    if "terminals" in wanted:
        try:
            scenario_terminals()
        except Exception as e:
            check("terminals ran to the end", False, f"{type(e).__name__}: {e}"[:500])
    if "panels" in wanted:
        try:
            scenario_panels()
        except Exception as e:
            check("panels ran to the end", False, f"{type(e).__name__}: {e}"[:500])
    if "controls" in wanted:
        try:
            scenario_controls()
        except Exception as e:
            check("controls ran to the end", False, f"{type(e).__name__}: {e}"[:500])
    if "typing" in wanted:
        try:
            scenario_typing()
        except Exception as e:
            check("typing ran to the end", False, f"{type(e).__name__}: {e}"[:500])
    if "noclaude" in wanted:
        try:
            scenario_noclaude(project)
        except Exception as e:
            check("noclaude ran to the end", False, f"{type(e).__name__}: {e}"[:500])

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    for name, _, detail in failed:
        print(f"  FAIL {name}: {detail}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
