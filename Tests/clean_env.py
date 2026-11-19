#!/usr/bin/env python3
"""Tempo 干净环境走一遍（交得出去，本人 2026-11-18）：别人的 Mac 上，包里的主程序从空到能用。

用共享原版 ~/Dev/tools/dev/lib/tools/macapp/clean_env.py 的 CleanEnv：空家目录、PATH 只有系统目录、没有本人的密钥与缓存，
沙箱拦住读写本人家目录（包本身和临时目录除外）。Tempo 没有包内服务、也不带 Python，所以不起服务、不查随包 uv，
直接跑包里的主程序（CFFIXED_USER_HOME 指向空家目录，Safari 存储与偏好都落在那里；TEMPO_NO_WINDOW 让任何该开窗口的路退出 70）：

  · 帮助能出；
  · Safari 还没给扩展建存储（刚装、没启用）时，命令说清楚“先在 Safari 的 Tempo 面板里改一项设置”，退出 4，不崩、不去读本人目录；
  · 等 Safari 建好存储（照 Safari 的表结构造一份在空家目录里），改速度、读回、默认快捷键都对；
  · 更新源是登记的 HTTPS 地址（公开仓 tempo-oss 最新 Release 的 release-manifest.json，不是本人的 iCloud），
    发行记录按 App 自己的规则解析，并真的去读一次线上那份（跟随 GitHub 的跳转，核版本、sha256、下载地址）；
  · 走完后空家目录里没有 Personal/、.personal_env，沙箱没拦到读本人家目录；
  · 系统里没有多登记一份 Tempo 扩展：离屏自检的 NSApplication 会向 LaunchServices 报到，不拦的话 build/Tempo.app 连同里面的
    扩展会被登记成第二份（2026-11-18 实测；CLAUDE.md：第二份登记压在装机那份前面，10-06 同一分钟 Safari 删过扩展存储）。
    所以每步沙箱都挡 com.apple.lsd.modifydb（共享 NativeEnv 同一做法），跑完再核 pluginkit，多出来的当场注销并判失败。

    python3 Tests/clean_env.py [--app build/Tempo.app] [--keep]     → build/clean-env/report.json；有一步不对退出 1
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path.home() / "Dev/tools/dev/lib/tools/macapp"))
from clean_env import CleanEnv  # noqa: E402  共享原版

FEED_PREFIX = "https://github.com/zengtianli/tempo-oss/releases/latest/download/"
FEED_URL = FEED_PREFIX + "release-manifest.json"
INSTALLED_APPEX = "/Applications/Tempo.app/Contents/PlugIns/TempoExtension.appex"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
NO_REGISTRATION = '(deny mach-lookup (global-name "com.apple.lsd.modifydb"))'  # 不登记进 LaunchServices，也就不登记扩展
STORE_DIR = "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebExtensions/Default/cyou.tianli.tempo.extension (B9LJH93LA4)"


def isolated_domains(root: Path) -> list[str]:
    """同 AppLifecycle.swift AppUpdatePreferences.isolatedDomain：FNV-1a 64 摘要；/private/var 与 /var 两种写法都算上，收尾时删。"""
    names = []
    for text in {str(root.resolve()), str(root.resolve()).removeprefix("/private")}:
        h = 0xcbf29ce484222325
        for b in text.encode():
            h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
        names.append("test.tianli.shared-update." + format(h, "x"))
    return names


def registered_copies() -> set[str]:
    """pluginkit 里 Tempo 扩展除装机那份以外的登记（路径）。"""
    out = subprocess.run(["pluginkit", "-m", "-A", "-D", "-v", "-i", "cyou.tianli.tempo.extension"],
                         capture_output=True, text=True, timeout=15).stdout
    found = {line.rsplit("\t", 1)[-1].strip() for line in out.splitlines() if "\t" in line}
    return {p for p in found if p and os.path.realpath(p) != os.path.realpath(INSTALLED_APPEX)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", default=str(ROOT / "build/Tempo.app"))
    ap.add_argument("--keep", action="store_true", help="留下临时的“别人的家目录”")
    ap.add_argument("--report", default=str(ROOT / "build/clean-env/report.json"))
    a = ap.parse_args(argv)
    app = Path(a.app).expanduser().resolve()
    if not (app / "Contents/MacOS/Tempo").is_file():
        print(json.dumps({"ok": False, "error": f"没有构建好的 App：{app}"}, ensure_ascii=False))
        return 1
    copies_before = registered_copies()
    with CleanEnv(app, name="Tempo", keep=a.keep) as ce:
        ce.checks.pop("package.uv_bundled", None)
        ce.notes["runtime"] = "原生容器 App + 网页扩展脚本，不带也不需要 Python/uv"
        # 偏好经 cfprefsd 读写，不受 CFFIXED_USER_HOME 和沙箱管：用 App 自带的隔离偏好域（APP_LIFECYCLE_SUPPORT_DIR、
        # TEMPO_BASICS_SUITE），TEMPO_BASICS_LIVE_UPDATES=1 保留正式更新源，否则会读到本人这台的更新记录与快捷键。
        suite = "test.tianli.tempo.cleanenv." + uuid.uuid4().hex
        support = ce.work / "support"
        env = ce.environment({"CFFIXED_USER_HOME": "{home}", "TEMPO_REEXEC": "1", "TEMPO_NO_WINDOW": "1",
                              "APP_LIFECYCLE_SUPPORT_DIR": str(support), "TEMPO_BASICS_LIVE_UPDATES": "1", "TEMPO_BASICS_SUITE": suite})
        domains = [suite, *isolated_domains(support)]
        exe = app / "Contents/MacOS/Tempo"
        runs = ce.notes.setdefault("runs", [])

        def run(*words, timeout=30):
            cmd = [str(exe), *words]
            if ce.sandbox:
                cmd = ["/usr/bin/sandbox-exec", "-p", ce.profile() + NO_REGISTRATION, *cmd]
            done = subprocess.run(cmd, env=env, cwd=ce.home, capture_output=True, text=True, timeout=timeout)
            for line in (done.stdout + done.stderr).splitlines():
                if "Operation not permitted" in line or "store_unreadable" in line:
                    ce.denied.append(line.strip()[:300])
            try:
                body = json.loads(done.stdout)
            except ValueError:
                body = None
            runs.append({"argv": list(words), "exit": done.returncode, "stdout": done.stdout[-1500:], "stderr": done.stderr[-800:]})
            return done.returncode, body, done.stdout

        code, _, out = run("--help")
        ce.check("cli.help", code == 0 and "tempo show" in out)

        code, body, _ = run("show", "--json")
        error = (body or {}).get("error") or {}
        ce.check("first_run.no_store_guidance", code == 4 and error.get("code") == "store_missing" and "Safari" in error.get("message", ""),
                 error.get("message", ""))

        # Safari 启用扩展、第一次写设置时建的那份存储（表结构与版本号同 Safari）
        store = ce.home / STORE_DIR / "LocalStorage.db"
        store.parent.mkdir(parents=True)
        with sqlite3.connect(store) as db:
            db.execute("CREATE TABLE extension_storage (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            db.execute("PRAGMA user_version=2")
        code, body, _ = run("speed", "1.5", "--json")
        ce.check("settings.write_into_safari_store", code == 0 and (body or {}).get("ok") is True)
        code, body, _ = run("show", "--json")
        ce.check("settings.readback", code == 0 and ((body or {}).get("settings") or {}).get("speed") == 1.5
                 and os.path.realpath(str((body or {}).get("store", ""))).startswith(str(ce.home.resolve())), str((body or {}).get("store", "")))
        code, body, _ = run("keys", "--json")
        keys = {k.get("action"): k.get("combo") for k in (body or {}).get("keys", [])}
        ce.check("settings.default_shortcuts", code == 0 and keys.get("faster") == "KeyD" and keys.get("slower") == "KeyA",
                 json.dumps(keys)[:300])

        latest = ce.work / "feed/latest.json"
        latest.parent.mkdir()
        latest.write_text(json.dumps({"version": "99.0.0", "build": "1", "bundle_id": "cyou.tianli.tempo",
                                      "download_url": "Tempo-99.0.0-1.zip", "sha256": "a" * 64, "size_bytes": 1}))
        code, body, _ = run("feed", str(latest), "--json")
        body = body or {}
        ce.notes["feed"] = body.get("feed")
        ce.check("update.feed_is_registered_https", code == 0 and body.get("feed") == FEED_URL
                 and body.get("download_url", "").startswith(FEED_PREFIX) and body.get("newer_than_this_app") is True)
        code, body, _ = run("update", "options", "--json")
        source = str((body or {}).get("source", ""))
        ce.check("update.source_is_public_release", code == 0 and source == "github.com", source[:300])  # 不是本人的“iCloud 私有渠道”
        # 真的读一次线上发行清单：HTTPS、跟随 GitHub 到附件存储的跳转、App 自己的解析（不记进更新记录）
        code, body, _ = run("update", "check", "--json", timeout=45)
        latest = (body or {}).get("latest") or {}
        ce.notes["live_feed"] = {"exit": code, "state": (body or {}).get("state"), "version": latest.get("version"), "build": latest.get("build")}
        ce.check("update.live_feed_readable", code == 0 and bool(latest.get("version")) and len(str(latest.get("sha256") or "")) == 64
                 and str(latest.get("download_url") or "").startswith("https://github.com/zengtianli/tempo-oss/releases/")
                 and (body or {}).get("state") in ("up_to_date", "ahead_of_channel", "update_available"),
                 json.dumps(body, ensure_ascii=False)[:400])
        ce.check("update.fresh_history", code == 0 and not (body or {}).get("history"), json.dumps((body or {}).get("history"))[:300])

        # 第一次打开容器 App：真实设置窗口离屏走一遍（不上屏、不抢焦点），之后默认每天查更新
        ui = dict(env, TEMPO_STORE=str(store), SOP_OUT_DIR=str(ce.work / "ui"))
        cmd = [str(exe), "--ui-self-test"]
        if ce.sandbox:
            cmd = ["/usr/bin/sandbox-exec", "-p", ce.profile() + NO_REGISTRATION, *cmd]
        done = subprocess.run(cmd, env=ui, cwd=ce.home, capture_output=True, text=True, timeout=60)
        try:
            checks = json.loads((ce.work / "ui/ui-self-test.json").read_text())["checks"]
        except (OSError, ValueError, KeyError):
            checks = {}
        failed = sorted(k for k, v in checks.items() if not v)
        runs.append({"argv": ["--ui-self-test"], "exit": done.returncode, "failed": failed, "stderr": done.stderr[-800:]})
        # 自检只等 0.4 秒看“检查更新”留下记录：隔离源是本地文件，这里是真的去读 HTTPS 地址（GitHub 跳转一次，常常超过 0.4 秒）。
        # 没赶上就照实记在 notes，不算这里的结论；线上读通由上面 update.live_feed_readable 证明，按钮到检查的路径由
        # scripts/accept/product_basics.py 用隔离源测。
        pending = {"updates.actual_check_action"} & set(failed)
        if pending:
            ce.notes["first_open_not_concluded"] = sorted(pending)
        ce.check("first_open.offscreen_window", checks and not (set(failed) - pending) and (done.returncode == 0 or pending),
                 "、".join(failed))
        code, body, _ = run("update", "options", "--json")
        options = (body or {}).get("options") or {}
        ce.check("first_open.daily_update_check", code == 0 and options.get("automaticCheck") is True and options.get("intervalHours") == 24,
                 json.dumps(options))
        added = sorted(registered_copies() - copies_before)
        for appex in added:  # 不留第二份：注销扩展和它所在的 App
            subprocess.run(["pluginkit", "-r", appex], capture_output=True, timeout=15)
            subprocess.run([LSREGISTER, "-u", appex.split("/Contents/PlugIns/")[0]], capture_output=True, timeout=30)
        ce.check("system.no_second_extension", not added, "、".join(added))
        ce.finish_checks(["{home}/Personal", "{home}/.personal_env"])
        for name in domains:
            subprocess.run(["defaults", "delete", name], capture_output=True)
    out = Path(a.report)
    out.parent.mkdir(parents=True, exist_ok=True)
    result = ce.report
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1, default=str), encoding="utf-8")
    print(json.dumps({"ok": result["ok"], "failed": [k for k, v in result["checks"].items() if not v], "report": str(out)}, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
