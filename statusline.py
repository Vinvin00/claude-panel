#!/usr/bin/env python3
"""Claude Code status line: prints a short line for the terminal and saves what the panel needs.

Claude Code gives status-line scripts the model, effort and (for subscribers) the 5-hour and
weekly usage limits. The panel can't get those any other way, so this script writes them to
~/.claude-panel/status/<session>.json and ~/.claude-panel/limits/<account>.json.
"""
import json, os, sys, time

BASE = os.path.expanduser("~/.claude-panel")


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def main():
    d = json.load(sys.stdin)
    model = (d.get("model") or {}).get("display_name") or ""
    effort = (d.get("effort") or {}).get("level") or ""
    ctx = (d.get("context_window") or {}).get("used_percentage")
    if d.get("session_id"):
        save(os.path.join(BASE, "status", d["session_id"] + ".json"),
             {"model": model, "effort": effort, "context": ctx, "updated": time.time()})

    # limits belong to the account, which is the settings folder this Claude runs on
    limits = d.get("rate_limits") or {}
    account = os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"))
    windows = {k: limits[k] for k in ("five_hour", "seven_day") if isinstance(limits.get(k), dict)}
    if windows:
        save(os.path.join(BASE, "limits", os.path.basename(account) + ".json"),
             {**windows, "updated": time.time()})

    parts = [model, effort]
    if ctx is not None:
        parts.append(f"ctx {round(ctx)}%")
    if "five_hour" in windows:
        parts.append(f"5h {round(windows['five_hour'].get('used_percentage', 0))}%")
    if "seven_day" in windows:
        parts.append(f"week {round(windows['seven_day'].get('used_percentage', 0))}%")
    print(" · ".join(p for p in parts if p))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("")  # never break the terminal over a status line
