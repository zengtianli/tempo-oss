#!/bin/bash
# Installs a built Tempo.app to /Applications, registers its Safari extension and adds the `tempo` command.
#
#   bash scripts/install.sh [--unnotarized] [path/to/Tempo.app]
#
# A build that is not notarized is refused: Safari does not list its extension, so the install would look
# like it did nothing. --unnotarized installs it anyway, for use with Safari's "Allow unsigned extensions".
# ~/.local/bin/tempo is a symlink to the app's executable (the app restarts itself at its real path, so
# it still finds its bundle). An existing entry that is not ours is left alone.
# An installed copy is moved to ~/.Trash/tempo-<old version>-<time>/ first. Nothing is launched and Safari
# is not restarted: a new install shows up under Safari Settings > Extensions, and an upgrade is picked up
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

if pgrep -f "^$DEST/Contents/MacOS/Tempo" >/dev/null; then
  echo 'Tempo.app is open. Close its window and run this again.' >&2
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
  mv "$DEST" "$BACKUP/"
  echo "previous copy moved to $BACKUP"
fi

ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST"
"$LSREGISTER" -f -R -trusted "$DEST"
pluginkit -a "$DEST/$APPEX"

LINK="$HOME/.local/bin/tempo"
CLI_TARGET="$DEST/Contents/MacOS/Tempo"
# 0.1.0 installed a two-line wrapper script here; it is ours and is replaced by the symlink.
OLD_WRAPPER='#!/bin/sh
exec /Applications/Tempo.app/Contents/MacOS/Tempo "$@"'
if [ -f "$LINK" ] && [ ! -L "$LINK" ] && [ "$(cat "$LINK")" = "$OLD_WRAPPER" ]; then rm "$LINK"; fi
if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
  mkdir -p "$(dirname "$LINK")"
  ln -s "$CLI_TARGET" "$LINK"
elif [ "$(readlink "$LINK" || true)" != "$CLI_TARGET" ]; then
  echo "Existing CLI entry left as it is; inspect it before replacing: $LINK" >&2
fi

if [ -f keys.json ]; then
  mkdir -p "$HOME/.config/mackit/keys.d"
  ln -sfn "$PWD/keys.json" "$HOME/.config/mackit/keys.d/tempo.json"
fi
echo "installed $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString) to $DEST"
pluginkit -m -v -i cyou.tianli.tempo.extension || true
if [ "$SAVED" = 1 ] && ! "$DEST/Contents/MacOS/Tempo" show >/dev/null 2>&1; then
  echo "Safari dropped Tempo's stored settings during this install. They were saved to $SETTINGS." >&2
  echo "Put them back in Safari: Tempo 面板 > 快捷键与设置 > 导入配置, paste the file's text, click 导入配置 again." >&2
fi
