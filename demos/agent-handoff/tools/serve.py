#!/usr/bin/env python3
"""Serves a folder on 127.0.0.1 so the browser in an agent's card can open it.

    python3 tools/serve.py prototype 8765

Prints the address and exits as soon as the page answers. The server keeps running in the
background on its own and stops by itself after 45 minutes. If something already answers on
the port, it is left alone and its address is printed.
"""
import functools
import http.server
import os
import socket
import sys
import threading
import time

LIFETIME = 45 * 60


def answering(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


class NoCache(http.server.SimpleHTTPRequestHandler):
    # Every revision of the prototype shows on reload.
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *args):
        pass


def serve(folder, port):
    handler = functools.partial(NoCache, directory=folder)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Timer(LIFETIME, server.shutdown).start()
    server.serve_forever()


def main():
    folder = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "prototype")
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    url = f"http://127.0.0.1:{port}/"
    if not os.path.isfile(os.path.join(folder, "index.html")):
        print(f"There is no index.html in {folder} to serve.")
        return 1
    if answering(port):
        print(f"Already serving at {url}")
        return 0
    if os.fork() == 0:
        # The server lets go of the Script card's terminal, so the card sees the command finish.
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        serve(folder, port)
        os._exit(0)
    for _ in range(50):
        if answering(port):
            print(f"Serving the prototype at {url}")
            return 0
        time.sleep(0.1)
    print(f"The server didn't start on port {port}.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
