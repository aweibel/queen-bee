#!/usr/bin/env python3
"""Turns the Risk analyst's entries into a spreadsheet.

    python3 tools/risk_log.py output/experience-risk-log.csv < answers

Reads every JSON object with an "item" key from standard input, in whatever text surrounds
them, writes them to the CSV file, and prints a short summary in markdown. Exits 1 if it
found no entries.
"""
import csv
import json
import os
import sys

COLUMNS = ["item", "original_intent", "what_shipped", "why", "quality_dimension",
           "customer_consequence", "severity", "evidence", "owner_question"]
ORDER = {"High": 0, "Medium": 1, "Low": 2}


def entries(text):
    decoder = json.JSONDecoder()
    found, at = [], 0
    while (at := text.find("{", at)) != -1:
        try:
            value, end = decoder.raw_decode(text, at)
        except ValueError:
            at += 1
            continue
        if isinstance(value, dict) and "item" in value:
            found.append(value)
        at = end
    return found


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "output/experience-risk-log.csv"
    rows = entries(sys.stdin.read())
    if not rows:
        print("No risk log entries came back, so there is nothing to write.")
        return 1
    for row in rows:
        row["severity"] = str(row.get("severity", "")).strip().title()
    rows.sort(key=lambda r: ORDER.get(r["severity"], 3))
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    with open(target, "w", newline="", encoding="utf-8") as out:
        writer = csv.DictWriter(out, fieldnames=COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in COLUMNS})

    counts = {s: sum(1 for r in rows if str(r.get("severity", "")).title() == s) for s in ORDER}
    print("# Experience risk log: agent handoff release\n")
    print(f"{len(rows)} cuts logged in `{target}`: "
          + ", ".join(f"{n} {s.lower()}" for s, n in counts.items()) + ".\n")
    print("| Severity | Cut | Quality given up | What the customer feels |")
    print("| --- | --- | --- | --- |")
    for r in rows:
        cells = [str(r.get(k, "")).replace("|", "/").replace("\n", " ")
                 for k in ("severity", "item", "quality_dimension", "customer_consequence")]
        print("| " + " | ".join(cells) + " |")
    high = [r for r in rows if str(r.get("severity", "")).title() == "High"]
    if high:
        print("\n## Questions for the owners of the high-severity cuts\n")
        for r in high:
            print(f"- **{r.get('item', '')}:** {r.get('owner_question', '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
