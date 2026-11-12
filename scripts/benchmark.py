"""Wall-clock benchmark for a roblox-sky-render job, from the first request to the images being sent.

Usage (run from any directory):
  python benchmark.py start                 # first call of the request; records T0
  python benchmark.py mark <phase>          # e.g. setup, render, export, assemble (each mark ends the previous phase)
  python benchmark.py stop [--images N]     # images sent; records T1 and prints the report

A phase's time is the gap from the previous mark (or T0 for the first) up to its own mark, so
`mark render` after the setup marks reports how long the render phase took. Anything after the last
mark, up to stop, is reported as "after last mark". The state lives in a JSON file in the system
temp folder so separate tool calls can share it; `start` overwrites any previous run.
"""

import json
import os
import sys
import tempfile
import time

STATE = os.path.join(tempfile.gettempdir(), "sky_render_benchmark.json")


def load():
    if not os.path.exists(STATE):
        sys.exit("No benchmark running. Run `python benchmark.py start` first.")
    with open(STATE, encoding="utf-8") as f:
        return json.load(f)


def save(state):
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


def report(state):
    t0 = state["t0"]
    end = state.get("t1", time.time())
    marks = state["marks"]
    lines = ["phase                 seconds"]
    # Each phase is the time between consecutive stamps, starting at T0.
    rows = []
    prev = t0
    for name, stamp in marks:
        rows.append((name, stamp - prev))
        prev = stamp
    rows.append(("after last mark", end - prev))
    for name, secs in rows:
        lines.append(f"{name:<21} {secs:8.2f}")
    total = end - t0
    lines.append(f"{'total (T0 to T1)':<21} {total:8.2f}")
    images = state.get("images")
    if images:
        lines.append(f"{'images':<21} {images:8d}")
        lines.append(f"{'seconds per image':<21} {total / images:8.2f}")
    return "\n".join(lines)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "start":
        save({"t0": time.time(), "marks": []})
        print("benchmark started")
    elif cmd == "mark":
        if len(argv) < 3:
            sys.exit("usage: benchmark.py mark <phase>")
        state = load()
        state["marks"].append([argv[2], time.time()])
        save(state)
        print(f"marked {argv[2]}")
    elif cmd == "stop":
        state = load()
        state["t1"] = time.time()
        if "--images" in argv:
            state["images"] = int(argv[argv.index("--images") + 1])
        save(state)
        print(report(state))
    elif cmd == "report":
        print(report(load()))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
