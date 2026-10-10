#!/bin/bash
# Recovery: what the extension does when something is wrong or switched off. Read from the same offscreen
# suite: bad or partial settings fall back to defaults, a page that resets the speed is put back, switching
# off restores 1x and lets the keys through, and with the page-world engine removed the standby engine
# still carries ordinary media.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(bash Tests/run.sh 2>&1)" || { echo "$out" | tail -n 20; echo "recovery: FAIL —— 测试没过"; exit 1; }
need=("bad shapes fall back" "a cleared key stays cleared, missing keys get defaults" "speed is clamped"
      "a reset by the page is undone" "switching off restores 1x" "keys pass through while off")
for name in "${need[@]}"; do
  grep -q "^ok  *$name" <<<"$out" || { echo "recovery: FAIL —— 缺少或未通过：$name"; exit 1; }
done
grep -q 'all checks passed (standby engine only)' <<<"$out" || { echo "recovery: FAIL —— 去掉网页世界引擎后待命引擎没有接住"; exit 1; }
echo "recovery: PASS (${#need[@]} 条回退与关闭恢复检查；去掉网页世界引擎后待命引擎一轮全过)"
