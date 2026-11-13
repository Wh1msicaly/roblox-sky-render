"""Time a roblox-sky-render job from the Claude Code session transcript. No calls during the run.

Claude Code writes every prompt, tool call and tool result to
~/.claude/projects/<project>/<session>.jsonl with a timestamp. This reads them after the fact and
reports how long the request took, from the user's prompt to the agent's last message of that turn.

Usage (run from any directory, after the run has finished):
  python benchmark.py                       # newest session that ran the skill, its last render request
  python benchmark.py <session.jsonl | id>  # a specific session (a path or the session id)
  python benchmark.py --list                # list the render requests in that session
  python benchmark.py --turn 2              # pick one request from --list
  python benchmark.py --calls               # also print every tool call
  python benchmark.py --images 6            # override the image count (default: PNGs assembled)

The wall-clock time is split into phases by what each tool call does (find, setup, render, export,
assemble, cleanup, bookkeeping, reply) and, inside each phase, into "model" time (the agent thinking
and writing the call, including the large script pastes) and "tools" time (waiting on results).
Parallel calls are counted once, so the phases add up exactly to the total. Standard library only.
"""

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime

PROJECTS = os.path.join(os.path.expanduser("~"), ".claude", "projects")
INSTALL = re.compile(r"shared\.Sky\w+\s*=(?!=)")
PHASES = ["find", "setup", "render", "export", "assemble", "cleanup", "benchmark", "bookkeeping", "other", "reply"]


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def classify(name, inp):
    """Phase of one tool call, from the tool name and its input."""
    short = name.split("__")[-1]
    code = inp.get("code", "") if isinstance(inp, dict) else ""
    cmd = inp.get("command", "") if isinstance(inp, dict) else ""
    if short == "execute_luau":
        if INSTALL.search(code):
            return "setup"
        if "SkyExportClear(" in code or "SkyRenderClear(" in code:
            return "cleanup"
        if "SkyExportPrepare(" in code or "SkyExportPart(" in code:
            return "export"
        if "SkyRender(" in code or "SkyRenderBoard(" in code:
            return "render"
        return "find"  # includes the status check, which only reads shared.Sky*Version
    if short == "screen_capture":
        return "render"
    if short == "Read" and str(inp.get("file_path", "")).endswith(".luau"):
        return "setup"
    if short in ("Bash", "PowerShell"):
        if "assemble_png" in cmd:
            return "assemble"
        if "benchmark.py" in cmd:
            return "benchmark"
    if short in ("list_roblox_studios", "search_game_tree", "inspect_instance", "get_studio_state", "ToolSearch", "Skill"):
        return "find"
    if short in ("update_plan", "wrap_up"):
        return "bookkeeping"
    return "other"


def is_sky(name, inp):
    short = name.split("__")[-1]
    if short == "Skill":
        return "roblox-sky-render" in json.dumps(inp)
    return short == "execute_luau" and "Sky" in str(inp.get("code", ""))


def result_text(block):
    c = block.get("content")
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c if isinstance(b, dict))
    return c if isinstance(c, str) else ""


def load_turns(path):
    """Split a session into turns: one per real user prompt, with its events in time order."""
    turns = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            kind = d.get("type")
            if kind not in ("user", "assistant") or d.get("isSidechain") or "timestamp" not in d:
                continue
            t = ts(d["timestamp"])
            content = d.get("message", {}).get("content")
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
            if kind == "user":
                results = [b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result"]
                if not results and not d.get("isMeta"):
                    text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict))
                    turns.append({"prompt": text.strip(), "start": t, "events": [], "calls": {}, "sky": False})
                    continue
                if not turns:
                    continue
                for b in results:
                    turns[-1]["events"].append((t, "result", b.get("tool_use_id"), result_text(b)))
            elif turns:
                for b in blocks:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        name, inp = b.get("name", "?"), b.get("input") or {}
                        turns[-1]["calls"][b.get("id")] = {"name": name, "input": inp, "phase": classify(name, inp)}
                        turns[-1]["sky"] |= is_sky(name, inp)
                        turns[-1]["events"].append((t, "use", b.get("id"), None))
                    else:
                        turns[-1]["events"].append((t, "model", None, None))
    for turn in turns:
        turn["events"].sort(key=lambda e: e[0])
    return turns


def find_session(arg):
    if arg:
        if os.path.isfile(arg):
            return arg
        hits = glob.glob(os.path.join(PROJECTS, "*", arg + "*.jsonl"))
        if not hits:
            sys.exit(f"No session file matches {arg!r} under {PROJECTS}")
        return hits[0]
    files = sorted(glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")), key=os.path.getmtime, reverse=True)
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            if "Sky" not in f.read():
                continue
        if any(t["sky"] for t in load_turns(path)):
            return path
    sys.exit(f"No session under {PROJECTS} has run roblox-sky-render.")


def label(call):
    inp = call["input"]
    if "code" in inp:
        lines = [l.strip() for l in inp["code"].splitlines() if l.strip() and not l.strip().startswith("--")]
        text = f"[{len(inp['code'].splitlines())}-line paste]" if INSTALL.search(inp["code"]) else " ".join(lines)
    elif "command" in inp:
        text = inp["command"]
    elif "file_path" in inp:
        text = os.path.basename(inp["file_path"])
    else:
        text = json.dumps(inp)
    return text[:70]


def report(turn, show_calls, images):
    calls, events = turn["calls"], turn["events"]
    start = turn["start"]
    end = events[-1][0] if events else start
    # Phase of each event: a call's own phase; for model output, the phase of the next call it leads to.
    phase_of, upcoming = [None] * len(events), "reply"
    for i in range(len(events) - 1, -1, -1):
        t, kind, cid, _ = events[i]
        if kind in ("use", "result"):
            phase_of[i] = calls.get(cid, {}).get("phase", "other")
            if kind == "use":
                upcoming = phase_of[i]
        else:
            phase_of[i] = upcoming
    # While several calls run in parallel, the wait belongs to whichever pending call returns last.
    finished = {cid: t for t, kind, cid, _ in events if kind == "result"}
    pending = set()
    for i, (t, kind, cid, _) in enumerate(events):
        if kind == "use":
            pending.add(cid)
        elif kind == "result":
            slowest = max(pending | {cid}, key=lambda c: finished.get(c, float("inf")))
            phase_of[i] = calls.get(slowest, {}).get("phase", "other")
            pending.discard(cid)
    totals = {}
    prev = start
    for i, (t, kind, cid, _) in enumerate(events):
        bucket = "tools" if kind == "result" else "model"
        row = totals.setdefault(phase_of[i], {"model": 0.0, "tools": 0.0})
        row[bucket] += max(0.0, t - prev)
        prev = max(prev, t)

    if images is None:
        images = sum(text.count("checksum ok") for _, kind, _, text in events if kind == "result" and text)

    print(f"prompt: {turn['prompt'][:90]!r}")
    print(f"started {datetime.fromtimestamp(start).strftime('%Y-%m-%d %H:%M:%S')}, {len(calls)} tool call(s)\n")
    if show_calls:
        used, last = {}, start
        print(f"{'#':>3} {'at':>7} {'model':>6} {'tool':>6}  {'phase':<11} call")
        for t, kind, cid, _ in events:
            if kind == "use":
                used[cid] = (t, t - last)
            if kind in ("use", "result"):
                last = t
        done = {cid: t for t, kind, cid, _ in events if kind == "result"}
        for n, (cid, (t, gap)) in enumerate(used.items(), 1):
            c = calls[cid]
            dur = f"{done[cid] - t:6.2f}" if cid in done else "     -"
            print(f"{n:>3} {t - start:7.2f} {gap:6.2f} {dur}  {c['phase']:<11} {c['name'].split('__')[-1]}: {label(c)}")
        print()
    print(f"{'phase':<12} {'model':>8} {'tools':>8} {'total':>8}")
    sm = st = 0.0
    for name in PHASES:
        if name in totals:
            m, k = totals[name]["model"], totals[name]["tools"]
            sm, st = sm + m, st + k
            print(f"{name:<12} {m:8.2f} {k:8.2f} {m + k:8.2f}")
    print(f"{'total':<12} {sm:8.2f} {st:8.2f} {end - start:8.2f}")
    if images:
        print(f"\nimages {images}, {(end - start) / images:.2f} s per image")
    print("\nmodel = the agent thinking and writing (including script pastes); tools = waiting on results.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("session", nargs="?", help="session .jsonl path or session id (default: newest with a render)")
    ap.add_argument("--list", action="store_true", help="list the render requests in the session")
    ap.add_argument("--turn", type=int, help="which render request from --list (default: the last)")
    ap.add_argument("--calls", action="store_true", help="print every tool call with its timing")
    ap.add_argument("--images", type=int, help="image count for seconds per image")
    args = ap.parse_args()

    path = find_session(args.session)
    sky = [t for t in load_turns(path) if t["sky"]]
    if not sky:
        sys.exit(f"{path} has no roblox-sky-render request.")
    print(f"session {os.path.basename(path)}")
    if args.list:
        for n, t in enumerate(sky, 1):
            print(f"{n:>3}  {datetime.fromtimestamp(t['start']).strftime('%Y-%m-%d %H:%M:%S')}  {t['prompt'][:70]!r}")
        return
    idx = (args.turn or len(sky)) - 1
    if not 0 <= idx < len(sky):
        sys.exit(f"--turn must be 1 to {len(sky)}")
    report(sky[idx], args.calls, args.images)


if __name__ == "__main__":
    main()
