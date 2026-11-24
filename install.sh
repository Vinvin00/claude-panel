#!/bin/sh
# Builds Claude Panel and hooks it into Claude Code.
#   ./install.sh           install (or update)
#   ./install.sh --remove  take the hooks out again
set -e
cd "$(dirname "$0")"
HOOK="/usr/bin/python3 $(pwd)/hook.py"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"  # override only for testing

/usr/bin/python3 - "$SETTINGS" "$HOOK" "$1" <<'EOF'
import json, os, shutil, sys
path, cmd, mode = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(path), exist_ok=True)
d = json.load(open(path)) if os.path.exists(path) else {}
if os.path.exists(path):
    shutil.copy(path, path + ".before-claude-panel")
hooks = d.setdefault("hooks", {})
# drop any earlier copy of our hook, keep everything else
for ev in list(hooks):
    hooks[ev] = [e for e in hooks[ev] if not any(h.get("command", "").endswith("/hook.py") and "claude-panel" in h.get("command", "") for h in e.get("hooks", []))]
    if not hooks[ev]:
        del hooks[ev]
if mode != "--remove":
    # 600s: these may wait for your answer in the panel
    waits = {"PreToolUse", "PermissionRequest", "Stop"}
    for ev in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
               "Notification", "Stop", "SubagentStop", "SessionEnd"]:
        h = {"type": "command", "command": cmd}
        if ev in waits:
            h["timeout"] = 600
        entry = {"hooks": [h]}
        if ev in ("PreToolUse", "PostToolUse", "PermissionRequest"):
            entry["matcher"] = "*"
        hooks.setdefault(ev, []).append(entry)
json.dump(d, open(path, "w"), indent=2)
EOF

if [ "$1" = "--remove" ]; then
    pkill -x ClaudePanel 2>/dev/null || true
    echo "Hooks removed. Delete ~/Applications/Claude Panel.app if you want it gone too."
    exit 0
fi

./build.sh
pkill -x ClaudePanel 2>/dev/null || true
open "$HOME/Applications/Claude Panel.app"
echo "Done. Look for the little tab on the right edge of your screen."
