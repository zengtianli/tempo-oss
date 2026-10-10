#!/bin/bash
# The interface people touch is the toolbar popup. Rendered offscreen from the shipped popup.html in four
# states (light, dark, each with settings open); every frame must be a real, non-blank picture, the dark
# frames darker than the light ones and the settings frames taller than the closed ones. Nothing appears
# on screen and Safari is not driven.
set -euo pipefail
cd "$(dirname "$0")/../.."
tool=build/tests/snapshot
if [ ! -x "$tool" ] || [ Tests/snapshot.swift -nt "$tool" ]; then mkdir -p build/tests; swiftc -O -o "$tool" Tests/snapshot.swift; fi
out="${SOP_OUT_DIR:-build/accept/native-ui}"; mkdir -p "$out"
res="$PWD/Extension/Resources"; tests="$PWD/Tests"
"$tool" "$res" "$tests" "$out/popup.png"
"$tool" "$res" "$tests" "$out/popup-dark.png" --dark
"$tool" "$res" "$tests" "$out/popup-settings.png" --open-settings
"$tool" "$res" "$tests" "$out/popup-settings-dark.png" --dark --open-settings
"${PYTHON:-python3}" - "$out" <<'PY'
import sys
from pathlib import Path
from PIL import Image, ImageStat
out = Path(sys.argv[1]); seen = {}
for name in ("popup", "popup-dark", "popup-settings", "popup-settings-dark"):
    im = Image.open(out / f"{name}.png").convert("RGB")
    stat = ImageStat.Stat(im)
    if im.width < 200 or im.height < 150 or max(stat.stddev) < 8:
        sys.exit(f"native_ui: FAIL —— {name}.png 是空白或尺寸不对：{im.size}，对比度 {max(stat.stddev):.1f}")
    seen[name] = (im.size, sum(stat.mean) / 3)
if not (seen["popup-dark"][1] < seen["popup"][1] and seen["popup-settings-dark"][1] < seen["popup-settings"][1]):
    sys.exit("native_ui: FAIL —— 深色画面不比浅色暗")
if not (seen["popup-settings"][0][1] > seen["popup"][0][1] and seen["popup-settings-dark"][0][1] > seen["popup-dark"][0][1]):
    sys.exit("native_ui: FAIL —— 展开设置后的面板没有变高")
print("native_ui: PASS (工具栏面板离屏渲染 4 帧：浅色 %dx%d、深色、展开设置 %dx%d、深色展开设置；均非空白)" % (*seen["popup"][0], *seen["popup-settings"][0]))
PY
