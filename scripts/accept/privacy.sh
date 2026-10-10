#!/bin/bash
# Privacy: the extension keeps its settings in Safari's extension storage and talks to nobody outside this
# Mac. Static checks on what ships: the API permissions are storage and nativeMessaging (the second reaches
# only the extension's own containing app, for the `tempo` command), no script or page makes a network
# request or loads remote code, the installed extension is sandboxed without a network entitlement, and the
# native sources (container app, extension handler, the mailbox between them) make no network calls.
set -euo pipefail
cd "$(dirname "$0")/../.."
res=Extension/Resources
perms="$("${PYTHON:-$HOME/Dev/.venv/bin/python}" -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("permissions", [])))' "$res/manifest.json")"
[ "$perms" = "storage,nativeMessaging" ] || { echo "privacy: FAIL —— manifest 权限不是 storage 加 nativeMessaging：$perms"; exit 1; }
hits="$(grep -nE 'fetch\(|XMLHttpRequest|WebSocket|sendBeacon|EventSource|importScripts|https?://' "$res"/*.js "$res"/*.html 2>/dev/null | grep -vE '^\S+:[0-9]+:\s*(//|\*)' || true)"
[ -z "$hits" ] || { echo "privacy: FAIL —— 扩展里出现联网或远程地址："; echo "$hits" | head -n 10; exit 1; }
# The part that runs inside Safari is the extension: it must be sandboxed and carry no network entitlement.
# (The container app shows status, opens Safari's settings and reads or writes that same store from the
# command line; it talks to nobody either, and its sources are scanned below.)
appex=/Applications/Tempo.app/Contents/PlugIns/TempoExtension.appex
ent="$(codesign -d --entitlements :- "$appex" 2>/dev/null || true)"
grep -q 'com.apple.security.app-sandbox' <<<"$ent" || { echo "privacy: FAIL —— 装机扩展没有沙盒"; exit 1; }
if grep -q 'com.apple.security.network' <<<"$ent"; then echo "privacy: FAIL —— 装机扩展带网络权限"; exit 1; fi
native="$(grep -nE 'URLSession|NSURLConnection|URLRequest|NWConnection|CFSocket|NSXPCConnection|DistributedNotificationCenter' App/*.swift Extension/*.swift Shared/*.swift 2>/dev/null || true)"
[ -z "$native" ] || { echo "privacy: FAIL —— 原生代码里出现联网调用："; echo "$native" | head -n 10; exit 1; }
echo "privacy: PASS (manifest 权限是 storage 与 nativeMessaging，后者只通到本机的容器扩展；扩展脚本与页面没有联网调用或远程地址；装机扩展沙盒且无网络权限；容器 App、扩展原生代码与两者之间的收件目录无联网调用)"
