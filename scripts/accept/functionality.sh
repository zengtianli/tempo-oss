#!/bin/bash
# Functionality: the extension's behaviour suite against a real WebKit page, offscreen (the shipped
# Extension/Resources files, once with the page engine and once with the standby engine only), then the
# installed container app's command line. Nothing opens on screen; Safari is not driven.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(bash Tests/run.sh 2>&1)" || { echo "$out" | tail -n 20; echo "functionality: FAIL —— 行为测试没过"; exit 1; }
passed="$(echo "$out" | grep -c '^ok' || true)"
grep -q 'all checks passed (page engine)' <<<"$out" || { echo "functionality: FAIL —— 网页世界引擎那一轮没有全过"; exit 1; }
grep -q 'all checks passed (standby engine only)' <<<"$out" || { echo "functionality: FAIL —— 待命引擎那一轮没有全过"; exit 1; }
want="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
cli=/Applications/Tempo.app/Contents/MacOS/Tempo
[ -x "$HOME/.local/bin/tempo" ] && cli="$HOME/.local/bin/tempo"
status="$("$cli" status --json)" || { echo "functionality: FAIL —— tempo status 退出 $?（3 = 未公证，2 = Safari 还没认到扩展）：$status"; exit 1; }
grep -qF "\"version\":\"$want\"" <<<"$status" || { echo "functionality: FAIL —— 装机版本与源码 $want 不一致：$status"; exit 1; }
grep -q '"enabled":true' <<<"$status" || { echo "functionality: FAIL —— 扩展在 Safari 里没有启用：$status"; exit 1; }
echo "functionality: PASS (${passed} 条行为与规则检查，两种引擎各一轮；装机 $status)"
