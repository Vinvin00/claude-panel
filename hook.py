#!/usr/bin/env python3
"""Claude Code hook: records each session's status for the floating panel.
Writes ~/.claude-panel/sessions/<session_id>.json. Never blocks Claude: always exits 0."""
import glob, json, os, re, subprocess, sys, time

BASE = os.path.expanduser("~/.claude-panel")
STATE = os.path.join(BASE, "sessions")
REQS = os.path.join(BASE, "requests")
WAIT_SECS = 590  # keep under the hook timeout in settings.json (600)
REPLY_SECS = 300  # end-of-turn hold: the app's own input waits while this runs


def short(s, n=80):
    s = re.sub(r"<[^>]+>", " ", str(s or ""))  # drop tags like <pasted_content ...>
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def tool_detail(name, inp):
    inp = inp or {}
    for k in ("description", "command", "file_path", "pattern", "url", "prompt"):
        if inp.get(k):
            v = inp[k]
            if k == "file_path":
                v = os.path.basename(v)
            return f"{name}: {short(v, 60)}"
    return name


def save(path, s):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, path)


def clear_requests(sid):
    """Claude moved on (answered in the app, or the turn ended): drop pending panel requests."""
    for f in os.listdir(REQS):
        if f.startswith(sid + "~"):
            try:
                os.remove(os.path.join(REQS, f))
            except FileNotFoundError:
                pass


def panel_alive():
    try:  # the panel touches this file every second
        return time.time() - os.path.getmtime(os.path.join(BASE, "alive")) < 5
    except OSError:
        return False


def front_app():
    try:
        front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=2).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "name", front],
                             capture_output=True, text=True, timeout=2).stdout
        return out.split("=")[-1].strip().strip('"')
    except Exception:
        return ""


def in_own_app(s):
    """Is the user looking at the app this session lives in? Then they answer there, not in the panel."""
    return front_app() == ("Claude" if s.get("tty") in ("??", "", None) else "Terminal")


def ask_panel(sid, kind, payload, off_flag, wait=WAIT_SECS, s=None):
    """Put a request in the panel and wait for the answer text.
    None = no answer (timeout, turned off, panel closed).
    "__app__" = the user is in (or went to) the session's own app: let them answer there.
    Holding while they are in the app would leave the app waiting on the panel (it looks frozen)."""
    if os.path.exists(os.path.join(BASE, off_flag)) or not panel_alive():
        return None
    if s is not None and in_own_app(s):
        return "__app__"
    rid = f"{sid}~{time.time_ns()}"
    req = os.path.join(REQS, rid + ".json")
    ans = os.path.join(REQS, rid + ".answer")
    save(req, {"rid": rid, "session": sid, "kind": kind, **payload})
    end = time.time() + wait
    n = 0
    try:
        while time.time() < end and os.path.exists(req):
            if os.path.exists(ans):
                return open(ans).read().strip()
            n += 1
            if s is not None and n % 3 == 0 and in_own_app(s):
                return "__app__"
            time.sleep(0.3)
    finally:
        for p in (req, ans):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
    return None


def emit(obj):
    print(json.dumps(obj))


def last_assistant_text(transcript):
    """Last assistant text in the session transcript (to spot a question in terminal sessions)."""
    try:
        with open(transcript, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 200_000))
            lines = f.read().decode("utf-8", "ignore").splitlines()
    except Exception:
        return ""
    for line in reversed(lines):
        try:
            m = json.loads(line)
        except Exception:
            continue
        if m.get("type") != "assistant":
            continue
        parts = (m.get("message") or {}).get("content") or []
        text = "".join(p.get("text", "") for p in parts if isinstance(p, dict) and p.get("type") == "text")
        if text.strip():
            return text.strip()
    return ""


def claude_process():
    """Walk up from this hook to the claude process: its pid and terminal (tty, '??' for the app)."""
    pid = os.getppid()
    for _ in range(5):
        out = subprocess.run(["ps", "-o", "ppid=,tty=,comm=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        if not out:
            break
        ppid, tty, comm = out.split(None, 2)
        if "claude" in os.path.basename(comm).lower():
            return pid, tty
        pid = int(ppid)
    return None, None


def desktop_record(sid, known=None):
    """The desktop app's own record of this session: its local_ id, title and which copy (profile)."""
    paths = [known] if known else glob.glob(os.path.expanduser(
        "~/Library/Application Support/Claude*/claude-code-sessions/*/*/local_*.json"))
    for f in paths:
        try:
            txt = open(f).read()
        except OSError:
            continue
        if sid in txt:
            d = json.loads(txt)
            prof = f.split("/Application Support/")[1].split("/")[0]
            return {"desktopId": d.get("sessionId"), "dtitle": d.get("title") or "",
                    "profile": prof, "record": f, "model": d.get("model") or "", "effort": d.get("effort") or ""}
    return None


def locate(s, sid, ev):
    if "tty" not in s:
        pid, tty = claude_process()
        s.update(pid=pid, tty=tty or "")
    desktop = s.get("tty") in ("??", "")
    # look the record up once; refresh at the start and end of each turn (title, model, effort can change)
    if desktop and (not s.get("desktopId") or ev in ("Stop", "UserPromptSubmit")):
        rec = desktop_record(sid, s.get("record"))
        if rec:
            s.update(rec)


def permission(data, sid, path, s):
    name, inp = data.get("tool_name", ""), data.get("tool_input") or {}
    if name == "AskUserQuestion":  # handled in PreToolUse (this event doesn't fire for it in the app)
        return None
    s.update(status="waiting", detail="Allow? " + tool_detail(name, inp))
    save(path, s)
    a = ask_panel(sid, "permission", {"detail": tool_detail(name, inp)}, "no-approve", s=s)
    if a and a != "__app__":
        emit({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision":
              {"behavior": "allow"} if a == "allow" else
              {"behavior": "deny", "message": "Denied from Claude Panel"}}})
        return "approved from panel" if a == "allow" else "denied from panel"
    return None


def main():
    data = json.load(sys.stdin)
    sid = data.get("session_id")
    if not sid:
        return
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(REQS, exist_ok=True)
    path = os.path.join(STATE, f"{sid}.json")
    ev = data.get("hook_event_name", "")

    # subagents share session_id, so only clear when the whole turn is over
    if ev in ("Stop", "UserPromptSubmit", "SessionEnd"):
        clear_requests(sid)

    if ev == "SessionEnd":
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return

    try:
        s = json.load(open(path))
    except Exception:
        s = {"started": time.time(), "agents": 0, "title": ""}

    try:
        locate(s, sid, ev)
    except Exception:
        pass
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    s.update(
        id=sid,
        cwd=s.get("cwd") or data.get("cwd", ""),  # keep the folder the session started in
        account="work" if "work" in cfg or s.get("profile") == "Claude-Work" else "personal",
        cfg=cfg,  # terminal sessions: which settings folder (= which account) they run on
        updated=time.time(),
    )

    if ev == "SessionStart":
        s.update(status="idle", detail="started")
    elif ev == "UserPromptSubmit":
        s.update(status="working", detail="thinking…", turnStart=time.time(), question="", options=[])
        if not s.get("title"):
            s["title"] = short(data.get("prompt"), 70)
    elif ev == "PreToolUse":
        name = data.get("tool_name", "")
        inp = data.get("tool_input") or {}
        if name in ("Task", "Agent"):
            s["agents"] = s.get("agents", 0) + 1
        if name == "AskUserQuestion":  # question card: offer the options in the panel first
            qs = [{"question": q.get("question", ""),
                   "options": [o.get("label", "") for o in q.get("options") or []],
                   "multiSelect": bool(q.get("multiSelect"))} for q in inp.get("questions") or []]
            first = qs[0]["question"] if qs else ""
            s.update(status="waiting", detail=short(first, 140))
            save(path, s)
            a = ask_panel(sid, "question", {"questions": qs}, "no-reply", wait=REPLY_SECS, s=s)
            if a and a != "__app__":
                emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow",
                      "updatedInput": {**inp, "answers": json.loads(a)}}})
                s.update(status="working", detail="answered from panel", updated=time.time())
            # no answer / "__app__": the card shows in Claude as usual
        else:
            s.update(status="working", detail=tool_detail(name, inp))
            if inp.get("ask"):  # end-of-turn question in the desktop app (wrap_up), shown at Stop
                s["question"] = inp["ask"]
                s["options"] = [a.get("label") for a in inp.get("actions") or [] if a.get("label")]
    elif ev == "PostToolUse":
        s["status"] = "working"
        if data.get("tool_name") == "AskUserQuestion":
            s["question"] = ""
    elif ev == "SubagentStop":
        s["agents"] = max(0, s.get("agents", 0) - 1)
    elif ev == "Notification":
        s.update(status="waiting", detail=short(data.get("message") or "needs you"))
    elif ev == "Stop":
        q = s.get("question")
        if not q:  # terminal sessions: treat a reply ending in "?" as a question
            # the final message comes with the event; the transcript can lag one message behind
            text = (data.get("last_assistant_message") or "").strip() \
                if "last_assistant_message" in data else last_assistant_text(data.get("transcript_path", ""))
            if text.endswith("?"):
                q = text.split("\n")[-1]
                s["options"] = []  # buttons only come with a real end-of-turn question
        if not q:
            last = (data.get("last_assistant_message") or "").strip()
            first = next((l for l in last.splitlines() if l.strip()), "")
            s.update(status="done", detail="finished", agents=0, result=short(first.lstrip("#*- "), 140),
                     finishedAt=time.time(), turnSecs=time.time() - s.get("turnStart", time.time()))
        else:
            s.update(status="waiting", detail=short(q, 140), agents=0, question=q)
            save(path, s)
            # Holding the turn open lets a panel reply continue it; "__app__" releases it for the app.
            a = ask_panel(sid, "reply", {"question": q, "options": s.get("options") or []}, "no-reply", wait=REPLY_SECS, s=s)
            if a and a != "__app__":
                emit({"decision": "block",
                      "reason": f"The user replied from Claude Panel (treat it as their next message): {a}"})
                s.update(status="working", detail="reply sent from panel", question="", options=[],
                         turnStart=time.time(), updated=time.time())
            elif a == "__app__":  # answering in the app: keep it orange until they reply there
                s.update(status="waiting", detail=short(q, 140), question="", options=[], updated=time.time())
            else:  # hold timed out or panel off: stop nagging, keep it visible in grey
                s.update(status="done", detail="asked: " + short(q, 140), question="", options=[], updated=time.time())
    elif ev == "PermissionRequest":
        save(path, s)
        result = permission(data, sid, path, s)
        if result:
            s.update(status="working", detail=result, question="", updated=time.time())
            save(path, s)
        return

    save(path, s)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # a broken panel must never break Claude
    sys.exit(0)
