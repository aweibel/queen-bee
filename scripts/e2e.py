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
"""
import atexit
import glob
import json
import os
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
MOBILE_ID = "dev.queenbee.mobile"
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

FLOWS = {"guard": GUARD, "pan": PAN, "fanout": FANOUT, "switch": SWITCH, "loop": LOOP, "exit": EXIT, "apifail": APIFAIL, "ask": ASK}


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


def scenario_remote(app):
    print("remote: a paired device gets the flow, its changes and its terminals, and nobody else gets anything", flush=True)
    fid = GUARD["id"]
    app.open_flow(GUARD)
    if app.op("app", "remote-state")["on"] is False:
        check("nothing is put on offer while Remote is off", "error" in app.op("app", "remote-pair"))
    check("Remote turns on", app.op("app", "remote-on").get("on") is True)
    offer = app.op("app", "remote-pair")
    check("pairing puts a one-time code on offer", str(offer.get("code", "")).startswith("queenbee-pair:1:"), str(offer.keys()))

    device = Device("--code", offer["code"], "--pair-port", str(int(offer["port"])), "--flow", fid, "--seconds", "150")
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
        self.shots = os.environ.get("QB_E2E_SHOTS") or tempfile.mkdtemp(prefix="qb-shots-")
        os.makedirs(self.shots, exist_ok=True)
        # A copy left by an earlier run would still be paired with a Mac that is gone.
        simctl("uninstall", udid, MOBILE_ID)
        installed = simctl("install", udid, MOBILE_APP)
        if installed.returncode != 0:
            raise RuntimeError("the iPad app couldn't be installed: " + installed.stderr.strip()[:300])

    def _state_file(self):
        folder = simctl("get_app_container", self.udid, MOBILE_ID, "data").stdout.strip()
        return os.path.join(folder, "Library/Caches/qb-state.json")

    def launch(self, *args):
        """Starts the app afresh. What the last run wrote is thrown away first, so it can't be read as this run's."""
        self.quit()
        try:
            os.remove(self._state_file())
        except OSError:
            pass
        started = simctl("launch", self.udid, MOBILE_ID, *args)
        if started.returncode != 0:
            raise RuntimeError("the iPad app couldn't be launched: " + started.stderr.strip()[:300])

    def quit(self):
        simctl("terminate", self.udid, MOBILE_ID)

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
        mobile.wait(lambda s: (s.get("canvas") or {}).get("flow") == gid and len(frames(s)) == len(GATES["cards"]), 40, "the canvas to draw another flow")
        app.op(gid, "run")
        held(app, gid)
        waiting = "Waiting for you to let its command run"
        s = mobile.wait(lambda s: shown(s, "Shout").get("text") == waiting, 10, "the canvas to show the run waiting")
        check("a card holding a message says what it is waiting for", shown(s, "Shout").get("text") == waiting, str(shown(s, "Shout")))
        check("the link the run came along shows its count, and the card it left its tick",
              s.get("canvas", {}).get("passes") == {"l0": 1} and shown(s, "Start").get("badges") == ["✓"], str(s.get("canvas", {}).get("passes")))
        mobile.shot("mobile-4a-run-waiting")
        app.op(gid, "hold", answer="allow")
        held(app, gid, "Check it")
        app.op(gid, "hold", answer="approve")
        app.wait(gid, lambda s: not s["isRunning"], 20, "the run to end")
        s = mobile.wait(lambda s: shown(s, "Done").get("badges") == ["✓"], 10, "the canvas to show where the run went")
        check("when the run ends the canvas shows where it went and what came out",
              shown(s, "Done").get("badges") == ["✓"] and shown(s, "Done").get("text") == "HELLO FROM THE START CARD"
              and shown(s, "Binned").get("badges") == [] and s["canvas"].get("passes") == {"l0": 1, "l1": 1, "l2": 1} and s["canvas"].get("live") == [],
              f"{shown(s, 'Done')} {s.get('canvas', {}).get('passes')}")
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
        mobile.shot("terminals-1-card")

        s = play(3, "-qbZoom", "0.6", also=lambda s: abs((s.get("canvas") or {}).get("zoom", 1) - 0.6) < 0.01)
        t, place, zoom = terminal(s), shown_card(s, "Agent").get("terminalPlace") or {}, s.get("canvas", {}).get("zoom", 1)
        on = t.get("onScreen", {})
        check("zoomed out, the terminal shrinks with its card", abs(zoom - 0.6) < 0.01 and bool(place) and inside(on, place)
              and abs(on["width"] - t["natural"]["width"] * 0.6) < 1, f"{on} in {place} at zoom {zoom}")
        mobile.shot("terminals-2-card-zoomed-out")

        s = play(3, "-qbZoom", "2", also=lambda s: (s.get("canvas") or {}).get("zoom", 1) > 1.9)
        t, place, zoom = terminal(s), shown_card(s, "Agent").get("terminalPlace") or {}, s.get("canvas", {}).get("zoom", 1)
        on = t.get("onScreen", {})
        check("zoomed in, it grows with its card", zoom > 1.2 and bool(place) and inside(on, place) and abs(on["width"] - t["natural"]["width"] * zoom) < 1.5,
              f"{on} in {place} at zoom {zoom}")
        mobile.shot("terminals-3-card-zoomed-in")
        mobile.appearance("dark")
        mobile.shot("terminals-4-card-zoomed-in-dark")
        mobile.appearance("light")

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
        check("at least as large as on the Mac, and within the screen", t.get("onScreen", {}).get("width", 0) >= t.get("natural", {}).get("width", 1) - 1
              and t.get("onScreen", {}).get("x", -1) >= 0, str(t.get("onScreen")))
        check("and still takes no typing", t.get("isFirstResponder") is False)
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
                             + [f"level{n}" for n in range(5)]):
        write(project, i, FLOWS[name])
    print(f"project: {project}", flush=True)

    in_app = [w for w in wanted if w not in ("noclaude", "terminals")]
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
