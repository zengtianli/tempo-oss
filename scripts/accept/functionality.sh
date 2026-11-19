#!/bin/bash
# Functionality: the extension's behaviour suite against a real WebKit page, offscreen (the shipped
# Extension/Resources files, once with the page engine and once with the standby engine only), then the
# installed container app's command line. Nothing opens on screen; Safari is not driven.
# The app under test is the one Chapter hands over in SOP_INSTALLED_APP (the current-source candidate,
# PRD-foundation R1); run by hand it is still /Applications/Tempo.app. "Enabled in Safari" only means
# something for the installed copy, so that check runs only when SOP_ACCEPTANCE_TARGET scope is installed.
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${SOP_INSTALLED_APP:-/Applications/Tempo.app}"
scope="$("${PYTHON:-$HOME/Dev/.venv/bin/python}" -c 'import json,os; print((json.loads(os.environ.get("SOP_ACCEPTANCE_TARGET") or "{}").get("scope")) or ("installed" if not os.environ.get("SOP_INSTALLED_APP") else "candidate"))')"
# Fail before compiling/running fixtures when a different distribution occupies the installed bundle.
python3 scripts/accept/product_basics.py --binding-only
out="$(bash Tests/run.sh 2>&1)" || { code=$?; echo "$out" | tail -n 20; if [ "$code" -eq 75 ]; then echo "functionality: DEFERRED —— 离屏测试环境暂不可用"; exit 75; fi; echo "functionality: FAIL —— 行为测试没过"; exit 1; }
passed="$(echo "$out" | grep -c '^ok' || true)"
grep -q 'all checks passed (page engine)' <<<"$out" || { echo "functionality: FAIL —— 网页世界引擎那一轮没有全过"; exit 1; }
grep -q 'all checks passed (standby engine only)' <<<"$out" || { echo "functionality: FAIL —— 待命引擎那一轮没有全过"; exit 1; }
want="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
cli="$app/Contents/MacOS/Tempo"
if [ "$scope" = installed ]; then
  status="$("$cli" status --json 2>&1)" || { code=$?; echo "functionality: FAIL —— tempo status 退出 ${code}（1 = 未启用，2 = 用法错误或 Safari 未应答，3 = 未公证）：$status"; exit 1; }
  grep -qF "\"version\":\"$want\"" <<<"$status" || { echo "functionality: FAIL —— 装机版本与源码 $want 不一致：$status"; exit 1; }
  grep -q '"enabled":true' <<<"$status" || { echo "functionality: FAIL —— 扩展在 Safari 里没有启用：$status"; exit 1; }
  echo "functionality: PASS (${passed} 条行为与规则检查，两种引擎各一轮；装机 $status)"
else
  # A candidate is ad-hoc signed and never registered with Safari: status answers 3 (未公证) by design and its
  # "enabled" describes the installed extension, so only the candidate's own version and command line count here.
  code=0; status="$("$cli" status --json 2>&1)" || code=$?
  [ "$code" -eq 0 ] || [ "$code" -eq 3 ] || { echo "functionality: FAIL —— 候选包 tempo status 退出 ${code}：$status"; exit 1; }
  grep -qF "\"version\":\"$want\"" <<<"$status" || { echo "functionality: FAIL —— 候选包版本与源码 $want 不一致：$status"; exit 1; }
  # Read commands against a disposable Safari-shaped store (same shape product_basics.py uses), never Safari's own.
  store_dir="$(mktemp -d)"; trap 'rm -rf "$store_dir"' EXIT
  "${PYTHON:-$HOME/Dev/.venv/bin/python}" -c 'import sqlite3,sys; db=sqlite3.connect(sys.argv[1]); db.execute("CREATE TABLE extension_storage (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)"); db.execute("PRAGMA user_version=2"); db.execute("INSERT INTO extension_storage VALUES (?,?)", ("remote", "false")); db.commit()' "$store_dir/LocalStorage.db"
  for command in keys show; do
    reply="$(TEMPO_REEXEC=1 TEMPO_STORE="$store_dir/LocalStorage.db" "$cli" "$command" --json 2>&1)" || { echo "functionality: FAIL —— 候选包 tempo $command 失败：$reply"; exit 1; }
    grep -q '"ok":true' <<<"$reply" || { echo "functionality: FAIL —— 候选包 tempo $command 没有返回 ok：$reply"; exit 1; }
  done
  echo "functionality: PASS (${passed} 条行为与规则检查，两种引擎各一轮；候选包 $app 版本 ${want}，命令行 status/keys/show 可用)"
fi
