#!/bin/bash
# Runs the `tempo` settings commands against a throwaway copy of the store: a SQLite file with the layout
# Safari uses for an extension's storage.local, in a temporary folder. The container app's sources are
# compiled as a plain executable and pointed at that file (TEMPO_STORE) and at the extension's shared.js
# (TEMPO_RESOURCES). Safari's real settings are never opened, and no window appears: TEMPO_NO_WINDOW makes
# the one path that would open the window exit 70 instead.
#
# `tempo page` and `tempo do` are run against a mailbox in the same temporary folder (TEMPO_REMOTE_DIR, with
# a notification name of its own, TEMPO_REMOTE_TAG). Safari's side of it is Tests/standin.swift: the app
# extension's real relay with the background page played from a table of answers. "Is Safari running" is
# asked about an app that always is, or one that never is (TEMPO_SAFARI_BUNDLE). The real Safari and the
# installed extension's mailbox are never touched; every command below runs with these variables set.
set -euo pipefail
cd "$(dirname "$0")/.."

CLI=build/tests/tempo-cli
RELAY=build/tests/tempo-relay
mkdir -p build/tests
newer() { local out="$1"; shift; [ ! -x "$out" ] && return 0; for f in "$@"; do [ "$f" -nt "$out" ] && return 0; done; return 1; }
if newer "$CLI" App/TempoApp.swift App/TempoCLI.swift App/TempoRemote.swift Shared/Mailbox.swift; then
  swiftc -O -parse-as-library -o "$CLI" App/TempoApp.swift App/TempoCLI.swift App/TempoRemote.swift Shared/Mailbox.swift
fi
if newer "$RELAY" Tests/standin.swift Extension/Relay.swift Shared/Mailbox.swift; then
  swiftc -O -parse-as-library -o "$RELAY" Tests/standin.swift Extension/Relay.swift Shared/Mailbox.swift
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tempo-cli.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TEMPO_CLI="$PWD/$CLI" TEMPO_RELAY="$PWD/$RELAY" TEMPO_RESOURCES="$PWD/Extension/Resources" TEMPO_WORK="$WORK" /usr/bin/python3 - <<'PY'
import json, os, sqlite3, subprocess, sys, time

cli, relay, work = os.environ["TEMPO_CLI"], os.environ["TEMPO_RELAY"], os.environ["TEMPO_WORK"]
store = os.path.join(work, "LocalStorage.db")
mailbox = os.path.join(work, "remote")
REMOTE = {"TEMPO_REMOTE_DIR": mailbox, "TEMPO_REMOTE_TAG": f".test.{os.getpid()}", "TEMPO_SAFARI_BUNDLE": "com.apple.finder"}
failed = 0


def seed(rows, version=2, table="CREATE TABLE extension_storage (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"):
    if os.path.exists(store):
        os.remove(store)
    db = sqlite3.connect(store)
    db.execute(table)
    db.execute(f"PRAGMA user_version = {version}")
    if "extension_storage" in table:
        db.executemany("INSERT INTO extension_storage VALUES (?, ?)", [(k, json.dumps(v)) for k, v in rows.items()])
    db.commit()
    db.close()


def stored():
    db = sqlite3.connect(store)
    rows = dict(db.execute("SELECT key, value FROM extension_storage"))
    db.close()
    return {k: json.loads(v) for k, v in rows.items()}


def run(*args, stdin=None, env=None):
    full = {**os.environ, "TEMPO_STORE": store, "TEMPO_REEXEC": "1", "TEMPO_NO_WINDOW": "1", **REMOTE, **(env or {})}
    p = subprocess.run([cli, *args], input=stdin, capture_output=True, text=True, env=full, timeout=30)
    body = None
    if "--json" in args:
        try:
            body = json.loads(p.stdout)
        except ValueError:
            body = {"unparsed": p.stdout}
    return p.returncode, body, p.stdout, p.stderr


def check(name, ok, detail=""):
    global failed
    if not ok:
        failed += 1
    print(f"{'ok   ' if ok else 'FAIL '} cli: {name}" + ("" if ok else f"  [{detail}]"))


def fails(name, args, exit_code, code, **kw):
    before = stored() if os.path.exists(store) and kw.pop("compare", True) else None
    rc, body, _, err = run(*args, "--json", **kw)
    same = before is None or stored() == before
    check(name, rc == exit_code and body and body.get("ok") is False and body["error"]["code"] == code
          and body["error"]["message"] and err.strip() and same, f"exit {rc} {body}")


custom = {"slower": "Ctrl+Shift+Meta+BracketLeft", "faster": "Ctrl+Shift+Meta+BracketRight"}
seed({"speed": 2.5, "last": 2.5, "step": 0.5, "keys": custom})

rc, body, _, _ = run("show", "--json")
s = (body or {}).get("settings", {})
check("show reads what the panel stored", rc == 0 and body["ok"] and s["speed"] == 2.5 and s["step"] == 0.5 and s["seek"] == 10
      and s["enabled"] is True and s["keys"]["slower"] == custom["slower"] and s["keys"]["reset"] == "KeyS"
      and body["site"] is None and body["store"] == store, body)
check("reading leaves the store as it was", stored() == {"speed": 2.5, "last": 2.5, "step": 0.5, "keys": custom})
rc, _, out, _ = run("show")
check("show prints a summary without --json", rc == 0 and "2.5×" in out and "0.5" in out, out)

rc, body, _, _ = run("speed", "1.75", "--json")
check("speed sets the global speed and remembers it as last", rc == 0 and body["changed"] == {"speed": 1.75, "last": 1.75}
      and body["live"] is False and stored()["speed"] == 1.75 and stored()["last"] == 1.75, body)
rc, body, _, _ = run("speed", "up", "--json")
check("speed up adds one step", rc == 0 and stored()["speed"] == 2.25, body)
rc, body, _, _ = run("speed", "down", "--json")
check("speed down takes one step off", rc == 0 and stored()["speed"] == 1.75, body)
run("speed", "toggle", "--json")
first = stored()["speed"]
run("speed", "toggle", "--json")
check("speed toggle switches between 1x and the last speed", first == 1 and stored()["speed"] == 1.75 and stored()["last"] == 1.75, stored())

rc, body, _, _ = run("site", "https://www.bilibili.com/video/x", "rule", "2", "--json")
check("site rule keeps a speed for the site", rc == 0 and stored()["rules"] == {"bilibili.com": 2}
      and body["site"] == {"host": "bilibili.com", "speed": 2, "off": False, "site_off": False, "rule": {"host": "bilibili.com", "speed": 2}}, body)
rc, body, _, _ = run("speed", "3", "--site", "live.bilibili.com", "--json")
check("speed on a ruled site edits the rule, not the global speed", rc == 0 and stored()["rules"] == {"bilibili.com": 3}
      and stored()["speed"] == 1.75 and body["site"]["speed"] == 3, body)
rc, body, _, _ = run("show", "--site", "other.com", "--json")
check("show --site reports the speed a site plays at", rc == 0 and body["site"]["speed"] == 1.75 and body["site"]["rule"] is None, body)
run("site", "live.bilibili.com", "rule", "--json")
check("a rule that already covers the site is kept, not doubled", stored()["rules"] == {"bilibili.com": 3}, stored())
rc, body, _, _ = run("site", "bilibili.com", "follow", "--json")
check("site follow removes the rule", rc == 0 and stored()["rules"] == {} and body["site"]["speed"] == 1.75, body)
rc, body, _, _ = run("site", "example.com", "disable", "--json")
check("site disable switches Tempo off for the site", rc == 0 and stored()["off"] == {"example.com": True}
      and body["site"]["off"] and body["site"]["site_off"], body)
rc, body, _, _ = run("site", "a.example.com", "enable", "--json")
check("site enable brings it back", rc == 0 and stored()["off"] == {} and not body["site"]["off"], body)

rc, body, _, _ = run("off", "--json")
check("off switches Tempo off", rc == 0 and stored()["enabled"] is False and body["settings"]["enabled"] is False, body)
rc, body, _, _ = run("on", "--json")
check("on switches it back on", rc == 0 and stored()["enabled"] is True, body)
run("set", "step", "0.25", "--json"); run("set", "seek", "5", "--json"); run("set", "indicator", "off", "--json")
check("set changes step, seek and the indicator", stored()["step"] == 0.25 and stored()["seek"] == 5 and stored()["indicator"] is False, stored())

rc, body, _, _ = run("bind", "pause", "Shift+KeyW", "--json")
keys = stored()["keys"]
check("bind takes the combination from the action that had it", rc == 0 and keys["pause"] == "Shift+KeyW" and keys["mark"] == ""
      and body["freed"] == "mark" and keys["slower"] == custom["slower"], body)
run("bind", "mute", "cmd+shift+m", "--json")
run("bind", "pause", "none", "--json")
check("bind normalises the combination and none clears it", stored()["keys"]["mute"] == "Shift+Meta+KeyM" and stored()["keys"]["pause"] == "", stored()["keys"])
rc, body, _, _ = run("keys", "--json")
by = {k["action"]: k for k in (body or {}).get("keys", [])}
check("keys lists every action with its label", rc == 0 and len(by) == 13 and by["mute"]["label"] == "⇧⌘M" and by["pause"]["label"] == "—", body)

rc, body, exported, _ = run("export")
config = json.loads(exported)
check("export prints the configuration", rc == 0 and config["speed"] == 1.75 and config["step"] == 0.25 and config["keys"]["mute"] == "Shift+Meta+KeyM", exported)
rc, body, _, _ = run("defaults", "--yes", "--json")
check("defaults --yes clears the store", rc == 0 and stored() == {} and body["settings"]["speed"] == 1 and body["settings"]["keys"]["faster"] == "KeyD", body)
rc, body, _, _ = run("import", "-", "--json", stdin=exported)
check("import from stdin restores an export", rc == 0 and run("export")[2] == exported and stored()["keys"]["mute"] == "Shift+Meta+KeyM", body)
path = os.path.join(work, "config.json")
with open(path, "w") as f:
    json.dump({"speed": 99, "step": "x"}, f)
rc, body, _, _ = run("import", path, "--json")
check("import from a file goes through the same validation", rc == 0 and stored()["speed"] == 16 and stored()["step"] == 0.1, body)

fails("a speed that is not a number is a usage error", ["speed", "fast"], 2, "bad_value")
fails("a speed out of range is a usage error", ["speed", "99"], 2, "out_of_range")
fails("an unknown command is a usage error", ["frobnicate"], 2, "unknown_command")
fails("an unknown option is a usage error", ["show", "--bogus"], 2, "unknown_option")
fails("an unknown action is a usage error", ["bind", "fly", "KeyF"], 2, "unknown_action")
fails("a modifier alone is not a key", ["bind", "pause", "Shift+ShiftLeft"], 2, "bad_combo")
fails("a bad site is a usage error", ["site", "not a host", "disable"], 2, "bad_site")
fails("defaults without --yes changes nothing", ["defaults"], 2, "confirmation_required")
fails("an import that is not a configuration changes nothing", ["import", "-"], 1, "bad_config", stdin="[1, 2]")
fails("a missing import file changes nothing", ["import", os.path.join(work, "nope.json")], 1, "unreadable_file")

before = stored()
rc, _, out, err = run("speed", "fast")
check("without --json the reason goes to stderr only", rc == 2 and out == "" and "速度" in err and stored() == before, out + err)

fails("a wrong argument is reported even when the store is missing", ["speed", "fast"], 2, "bad_value",
      env={"TEMPO_STORE": os.path.join(work, "missing.db")}, compare=False)
fails("a missing store is exit 4", ["show"], 4, "store_missing", env={"TEMPO_STORE": os.path.join(work, "missing.db")}, compare=False)
check("a missing store is not created", not os.path.exists(os.path.join(work, "missing.db")))
seed({"speed": 2}, version=3)
rc, body, _, _ = run("show", "--json")
check("an unknown store version can still be read", rc == 0 and body["settings"]["speed"] == 2, body)
fails("an unknown store version is not written", ["speed", "3"], 4, "store_unsupported")
seed({}, table="CREATE TABLE other (k TEXT)")
fails("an unknown store layout is refused", ["show"], 4, "store_unsupported", compare=False)

# The top level. The window is for a start with no arguments (or only the flags the system adds when it
# launches an app); anything typed that the command does not know is a usage error and never a window.
WINDOW = 70
fails("an unknown option in first place is a usage error, not a window", ["--definitely-not-a-flag"], 2, "unknown_option", compare=False)
rc, _, out, err = run("--version")
check("the same without --json: exit 2, reason on stderr only", rc == 2 and out == "" and "--version" in err, f"exit {rc} {out}{err}")
rc, body, _, _ = run("--json", "status")
check("an option before the command is a usage error that says where it goes",
      rc == 2 and body.get("ok") is False and body["error"]["code"] == "unknown_option" and "status" not in body and "命令之后" in body["error"]["message"], f"exit {rc} {body}")
check("a single-dash word nobody knows is a usage error too", run("-x")[0] == 2)
check("no arguments at all is the one way to the window", run()[0] == WINDOW)
check("flags the system adds on launch still lead to the window",
      run("-NSDocumentRevisionsDebugMode", "YES")[0] == WINDOW and run("-psn_0_12345")[0] == WINDOW and run("-AppleLanguages", "(zh)")[0] == WINDOW)
fails("status refuses an option it does not know", ["status", "--definitely-not-a-flag"], 2, "unknown_option", compare=False)
fails("status takes no other argument", ["status", "now"], 2, "bad_arguments", compare=False)
rc, body, _, _ = run("status", "--json")
check("status keeps its own shape (this test build is not notarized: exit 3)",
      rc == 3 and set(body) == {"version", "enabled", "notarized"} and body["enabled"] is None and body["notarized"] is False, f"exit {rc} {body}")
rc, _, out, _ = run("--help")
listed = [line.split()[1] for line in out.splitlines() if line.strip().startswith("tempo ")]
check("--help lists every command at the start of a line, and the four things an agent needs",
      rc == 0 and set(listed) == {"status", "show", "page", "keys", "export", "speed", "on", "site", "set", "bind", "import", "defaults", "do"}
      and "tempo on | off" in out and all(word in out for word in ("读命令", "写命令", "--json 输出", "退出码", "仅在窗口中", "命令通道")), listed)

# The page in Safari's current tab: `page`, `do`, and write commands telling open pages to read again.
# Nobody is listening yet: the mailbox folder does not even exist.
seed({"speed": 2})
fails("page with the channel switched off says so, exit 5", ["page"], 5, "channel_off")
fails("do with the channel switched off says so, exit 5", ["do", "forward"], 5, "channel_off")
check("asking a channel that is off creates nothing", not os.path.exists(mailbox))
fails("with no store at all the channel is at its default, off", ["page"], 5, "channel_off",
      env={"TEMPO_STORE": os.path.join(work, "missing.db")}, compare=False)
rc, body, _, _ = run("set", "remote", "on", "--json")
check("set remote on stores the switch; nobody is listening yet, so it is not live", rc == 0 and stored()["remote"] is True
      and body["changed"] == {"remote": True} and body["settings"]["remote"] is True and body["live"] is False, body)
fails("the switch is on but no page is listening: channel_asleep", ["page"], 5, "channel_asleep")
fails("Safari not running is its own reason, and Safari is not started", ["do", "forward"], 5, "safari_not_running",
      env={"TEMPO_SAFARI_BUNDLE": "cyou.tianli.tempo.no-such-app"})
fails("an action nobody knows is a usage error before anything is sent", ["do", "fly"], 2, "unknown_action")
fails("do needs exactly one action", ["do"], 2, "bad_arguments")
fails("page takes no argument", ["page", "now"], 2, "bad_arguments")
fails("page does not take --site", ["page", "--site", "a.com"], 2, "unexpected_option")

PAGE = {"host": "bilibili.com", "speed": 2, "off": False, "site_off": False, "rule": None, "has_media": True}
MEDIA = {"kind": "video", "paused": False, "muted": False, "time": 75.5, "duration": 600, "rate": 2, "pip": False, "mark": None}
answers = {
    "page": {"page": PAGE, "media": MEDIA},
    "forward": {"action": "forward", "page": PAGE, "before": MEDIA, "result": {"time": 85.5}, "media": {**MEDIA, "time": 85.5}},
    "faster": {"action": "faster", "page": {**PAGE, "speed": 2.1}, "before": None, "result": None, "media": None},
    "pause": {"action": "pause", "page": PAGE, "before": {**MEDIA, "paused": True}, "result": {"paused": False},
              "media": {**MEDIA, "paused": True}, "error": "not_allowed"},
    "pip": {"action": "pip", "page": PAGE, "before": MEDIA, "result": {"pip": True}, "media": MEDIA, "error": "not_allowed"},
    "mute": {"error": "no_media", "page": {**PAGE, "has_media": False}},
    "jump": {"action": "jump", "page": PAGE, "before": MEDIA, "result": {"time": None}, "media": MEDIA, "error": "no_mark"},
    "mark": {"error": "site_off", "page": {**PAGE, "off": True, "site_off": True}},
    "rewind": {"error": "no_page"},
    "reread": {"reread": 3},
    # frameNext is left out: a request nobody answers
}
os.makedirs(mailbox)
with open(os.path.join(mailbox, "answers.json"), "w") as f:
    json.dump(answers, f)
safari = subprocess.Popen([relay], env={**os.environ, **REMOTE})
try:
    deadline = time.time() + 10
    while not os.path.exists(os.path.join(mailbox, "armed.json")) and time.time() < deadline:
        time.sleep(0.05)
    check("the stand-in for Safari is listening", os.path.exists(os.path.join(mailbox, "armed.json")))

    rc, body, _, _ = run("page", "--json")
    check("page reports the site of the current tab and the state of its player", rc == 0 and body == {"ok": True, "page": PAGE, "media": MEDIA}, body)
    rc, _, out, _ = run("page")
    check("page prints one line for the site and one for the player", rc == 0 and "bilibili.com：2×" in out and "播放中 1:15 / 10:00" in out, out)
    check("reading the page leaves the store as it was", stored() == {"speed": 2, "remote": True}, stored())
    rc, body, _, _ = run("do", "forward", "--json")
    check("do runs the action on the page and reports what the player did", rc == 0 and body["ok"] and body["action"] == "forward"
          and body["result"] == {"time": 85.5} and body["media"]["time"] == 85.5 and body["page"] == PAGE and set(body) == {"ok", "action", "page", "result", "media"}, body)
    rc, body, _, _ = run("do", "faster", "--json")
    check("do with a settings action reports the page's new speed", rc == 0 and body["page"]["speed"] == 2.1 and body["result"] is None and body["media"] is None, body)
    rc, _, out, _ = run("do", "forward")
    check("do prints what it did", rc == 0 and "已执行：快进" in out and "1:25" in out, out)
    fails("the page would not start playing: exit 1, not_allowed", ["do", "pause"], 1, "not_allowed")
    fails("Safari would not go into picture in picture: exit 1, not_allowed", ["do", "pip"], 1, "not_allowed")
    fails("no video or audio in the current tab: exit 1, no_media", ["do", "mute"], 1, "no_media")
    fails("no remembered position: exit 1, no_mark", ["do", "jump"], 1, "no_mark")
    fails("Tempo is off for the site: exit 1, site_off", ["do", "mark"], 1, "site_off")
    fails("the current tab is not a web page: exit 5, no_page", ["do", "rewind"], 5, "no_page")
    started = time.time()
    fails("a request nobody answers: exit 5, no_answer", ["do", "frameNext"], 5, "no_answer")
    check("and it is withdrawn after the wait, so it cannot run later",
          not os.path.exists(os.path.join(mailbox, "request.json")) and 2.5 < time.time() - started < 6, time.time() - started)
    check("no reply files are left behind", sorted(os.listdir(mailbox)) == ["answers.json", "armed.json"], os.listdir(mailbox))
    stale = os.path.join(mailbox, "reply-GONE.json")
    with open(stale, "w") as f:
        f.write("{}")
    os.utime(stale, (time.time() - 300, time.time() - 300))
    run("page", "--json")
    check("a reply nobody collected is cleared away later", not os.path.exists(stale), os.listdir(mailbox))

    rc, body, _, _ = run("speed", "1.5", "--json")
    check("a write tells open pages to read it at once: live", rc == 0 and stored()["speed"] == 1.5 and body["live"] is True, body)
    rc, _, out, _ = run("speed", "2")
    check("and says so without --json", rc == 0 and "立即生效" in out and "切回时生效" not in out, out)
    rc, body, _, _ = run("page", "--json", "--profile", "Default")
    check("--profile Default is the default profile", rc == 0 and body["page"] == PAGE, body)
    started = time.time()
    fails("in a profile where nobody is listening the request is not sent, and no other profile answers it",
          ["page", "--profile", "0AB1"], 5, "channel_asleep")
    check("and that is known without waiting", time.time() - started < 1.5 and not os.path.exists(os.path.join(mailbox, "request.json")), time.time() - started)
finally:
    safari.kill()
    safari.wait()

check("the mark of a listener that is gone stays behind", os.path.exists(os.path.join(mailbox, "armed.json")))
fails("but a listener that is gone does not count: channel_asleep", ["page"], 5, "channel_asleep")
# A mark that looks alive (this test's own process, just now) with nobody behind it: the request is left,
# nobody takes it, and the command takes it back.
with open(os.path.join(mailbox, "armed.json"), "w") as f:
    json.dump({"pid": os.getpid(), "at": time.time(), "profiles": [""]}, f)
fails("nobody takes the request: exit 5, no_answer", ["do", "forward"], 5, "no_answer")
check("and the command takes its request back", not os.path.exists(os.path.join(mailbox, "request.json")), os.listdir(mailbox))
with open(os.path.join(mailbox, "armed.json"), "w") as f:
    json.dump({"pid": os.getpid(), "at": time.time() - 120, "profiles": [""]}, f)
fails("a mark that has not been refreshed for long does not count either", ["page"], 5, "channel_asleep")
os.remove(os.path.join(mailbox, "armed.json"))

started = time.time()
rc, body, _, _ = run("speed", "3", "--json")
check("a write with nobody listening is not live and does not wait", rc == 0 and stored()["speed"] == 3 and body["live"] is False
      and time.time() - started < 1.5, (body, time.time() - started))
rc, body, _, _ = run("set", "remote", "off", "--json")
check("set remote off", rc == 0 and stored()["remote"] is False and body["settings"]["remote"] is False, body)
fails("an unknown setting names the ones there are", ["set", "volume", "3"], 2, "unknown_setting")

print("all cli checks passed" if not failed else f"{failed} cli check(s) failed")
sys.exit(1 if failed else 0)
PY
