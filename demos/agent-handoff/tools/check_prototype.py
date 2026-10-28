#!/usr/bin/env python3
"""Checks a one-file HTML prototype before anyone spends time looking at it.

    python3 tools/check_prototype.py prototype/index.html

Prints each check with PASS or FAIL and exits 1 if any failed.
"""
import html.parser
import os
import re
import sys


class Page(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.tags = []
        self.lang = None
        self.title = ""
        self.in_title = False
        self.buttons = []
        self.button = None
        self.images_without_alt = 0
        self.external = []
        self.viewport = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append(tag)
        if tag == "html":
            self.lang = a.get("lang")
        if tag == "title":
            self.in_title = True
        if tag == "meta" and a.get("name") == "viewport":
            self.viewport = True
        if tag == "button":
            self.button = {"label": a.get("aria-label") or "", "text": ""}
        if tag == "img" and "alt" not in a:
            self.images_without_alt += 1
        for key in ("src", "href"):
            value = a.get(key) or ""
            if re.match(r"(https?:)?//", value):
                self.external.append(value)

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag == "button" and self.button is not None:
            self.buttons.append(self.button)
            self.button = None

    def handle_data(self, data):
        if self.in_title:
            self.title += data
        if self.button is not None:
            self.button["text"] += data


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "prototype/index.html"
    if not os.path.isfile(path):
        print(f"FAIL  {path} doesn't exist yet.")
        return 1
    text = open(path, encoding="utf-8").read()
    page = Page()
    page.feed(text)
    unlabelled = [b for b in page.buttons if not (b["label"].strip() or b["text"].strip())]
    checks = [
        ("It is one file under 300 KB", len(text.encode()) < 300_000),
        ("It loads nothing from the internet", not page.external),
        ("The page says what language it is in", bool(page.lang)),
        ("It has a title", bool(page.title.strip())),
        ("It fits small screens (a viewport tag)", page.viewport),
        ("It has a main landmark", "main" in page.tags),
        ("It has a heading", any(t in page.tags for t in ("h1", "h2"))),
        ("Every button says what it does", not unlabelled),
        ("Every image has alt text", page.images_without_alt == 0),
        ("Focus is visible (a :focus-visible style)", ":focus-visible" in text),
        ("No placeholder text", not re.search(r"lorem ipsum|TODO|John Doe", text, re.I)),
    ]
    failed = 0
    for name, ok in checks:
        print(("PASS  " if ok else "FAIL  ") + name)
        failed += not ok
    if page.external:
        print("  Loads: " + ", ".join(page.external[:5]))
    if unlabelled:
        print(f"  {len(unlabelled)} button(s) with no text or aria-label")
    print(f"\n{len(checks) - failed} of {len(checks)} checks passed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
