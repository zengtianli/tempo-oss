#!/bin/bash
# Installs a built Tempo.app to /Applications, registers its Safari extension and adds the `tempo` command.
#
#   bash scripts/install.sh [--unnotarized] [path/to/Tempo.app]
#
# A build that is not notarized is refused: Safari does not list its extension, so the install would look
# like it did nothing. --unnotarized installs it anyway, for use with Safari's "Allow unsigned extensions".
# ~/.local/bin/tempo execs the app's real executable path: lifecycle commands run before the app's
# symlink reexec and would otherwise see bundle version 0. An entry that is not ours is left alone.
# An installed copy is moved to ~/.Trash/tempo-<old version>-<time>/ first. An open Tempo.app is quit first and
# reopened in the background afterwards; otherwise nothing is launched. Safari is not restarted: a new install shows up under Safari Settings > Extensions, and an upgrade is picked up
# the next time Safari starts.
set -euo pipefail
cd "$(dirname "$0")/.."
usage() { echo 'Usage: bash scripts/install.sh [--unnotarized] [path/to/Tempo.app]' >&2; exit 2; }
UNNOTARIZED=0
APP=''
for arg in "$@"; do
  case "$arg" in
    --unnotarized) UNNOTARIZED=1 ;;
    -*) usage ;;
    *) [ -z "$APP" ] || usage; APP="$arg" ;;
  esac
done
# Chapter's install-channel guard runs where Chapter is (the development Mac; there a missing `chapter` command still
# stops the install). A public checkout has no Chapter and skips it.
CHAPTER_GUARD=0
[ -d "$HOME/Apps/chapter" ] && CHAPTER_GUARD=1
[ "$CHAPTER_GUARD" = 0 ] || chapter local-install check --app tempo --direct --json
APP="${APP:-$PWD/build/Tempo.app}"
DEST=/Applications/Tempo.app
APPEX="Contents/PlugIns/TempoExtension.appex"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ ! -f "$APP/$APPEX/Contents/Resources/manifest.json" ]; then
  echo 'App not found. Run bash build.sh first, or pass a built Tempo.app.' >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"
if [ "$UNNOTARIZED" != 1 ] && ! codesign --verify --test-requirement='=notarized' "$APP" 2>/dev/null; then
  echo 'This build is not notarized, and Safari does not list an extension from an un-notarized app.' >&2
  echo 'Run bash scripts/notarize.sh first. Nothing was installed.' >&2
  exit 1
fi

# 装前强退、装完后台重开，走共享 app_replace（本人 2026-10-23；Chapter 装机已在外层套上，直接运行本脚本时这里接上）。
# Without it (a public checkout) an open Tempo.app is refused, as before.
REPLACE="$HOME/Dev/tools/dev/lib/tools/macapp/app_replace.py"
REPLACE_STATE="$(mktemp -t tempo-replace)"
if [ -f "$REPLACE" ]; then
  python3 "$REPLACE" stop "$DEST" --state "$REPLACE_STATE" || { echo 'Tempo.app did not quit; nothing was installed.' >&2; exit 1; }
elif pgrep -f "^$DEST/Contents/MacOS/Tempo" >/dev/null; then
  echo 'Tempo.app is open. Quit it and run this again.' >&2
  exit 1
fi

# What an upgrade does to the settings Safari keeps for the extension has not been watched yet, so they are
# read out first (read-only, with the build being installed; 0.1.2 and later can) and checked at the end.
SETTINGS="$PWD/build/settings/before-install-$(date +%Y%m%d-%H%M%S).json"
SAVED=0
mkdir -p "$PWD/build/settings"
if "$APP/Contents/MacOS/Tempo" export > "$SETTINGS" 2>/dev/null; then SAVED=1; else rm -f "$SETTINGS"; fi

if [ -e "$DEST" ]; then
  OLD="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  BACKUP="$HOME/.Trash/tempo-$OLD-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP"
  if [ -O "$DEST" ]; then
    mv "$DEST" "$BACKUP/"
  else
    # Apple's TestFlight installer owns its app as root. Reuse the authorized exact sudo entry.
    "$HOME/.local/bin/mac-admin" run -- /bin/mv "$DEST" "$BACKUP/"
  fi
  echo "previous copy moved to $BACKUP"
fi

ditto "$APP" "$DEST"
[ "$CHAPTER_GUARD" = 0 ] || chapter local-install check --app tempo --direct --require-installed --json
codesign --verify --deep --strict "$DEST"
"$LSREGISTER" -f -R -trusted "$DEST"
pluginkit -a "$DEST/$APPEX"

LINK="$HOME/.local/bin/tempo"
CLI_TARGET="$DEST/Contents/MacOS/Tempo"
# Use the same minimal real-path wrapper as 0.1.0; no copied product logic lives here.
OLD_WRAPPER='#!/bin/sh
exec /Applications/Tempo.app/Contents/MacOS/Tempo "$@"'
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$CLI_TARGET" ]; then rm "$LINK"; fi
if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
  mkdir -p "$(dirname "$LINK")"
  printf '%s\n' "$OLD_WRAPPER" > "$LINK"
  chmod 755 "$LINK"
elif [ -L "$LINK" ] || [ ! -f "$LINK" ] || [ "$(cat "$LINK")" != "$OLD_WRAPPER" ]; then
  echo "Existing CLI entry left as it is; inspect it before replacing: $LINK" >&2
fi

if [ -f keys.json ]; then
  mkdir -p "$HOME/.config/mackit/keys.d"
  ln -sfn "$PWD/keys.json" "$HOME/.config/mackit/keys.d/tempo.json"
fi
echo "installed $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) to $DEST"
[ -f "$REPLACE" ] && python3 "$REPLACE" reopen "$DEST" --state "$REPLACE_STATE"
rm -f "$REPLACE_STATE"
pluginkit -m -v -i cyou.tianli.tempo.extension || true
if [ "$SAVED" = 1 ] && ! "$DEST/Contents/MacOS/Tempo" show >/dev/null 2>&1; then
  echo "Safari dropped Tempo's stored settings during this install. They were saved to $SETTINGS." >&2
  echo "Put them back in Safari: Tempo 面板 > 快捷键与设置 > 导入配置, paste the file's text, click 导入配置 again." >&2
fi
