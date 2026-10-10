#!/bin/bash
# Builds build/Tempo.app: the container app with the Safari web extension inside.
#
#   bash build.sh              run the tests, then build and sign
#   bash build.sh --test-only  run the tests only
#
# Signing uses the Developer ID identity named in project.yml; override with CODE_SIGN_IDENTITY.
#
# No copy of the extension is registered with the system by this script. xcodebuild registers every macOS
# app product with LaunchServices (lsregister -f -R -trusted; no build setting turns that off), and until
# 0.1.2 the app product had the extension inside: for the length of a build Safari was shown a second,
# un-notarized, newer copy of the extension in front of the installed one, and it dropped the settings the
# installed one had stored (2026-10-06, Safari open). Now the app product is built without the extension
# (see project.yml) and the extension is put into build/Tempo.app afterwards, a place nothing registers.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd -P)"

bash Tests/run.sh
[ "${1:-}" = "--test-only" ] && exit 0

# The app and the extension manifest carry the same version.
APP_VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)"
EXT_VERSION="$(sed -n 's/^ *"version": *"\(.*\)",*/\1/p' Extension/Resources/manifest.json)"
[ -n "$APP_VERSION" ] && [ "$APP_VERSION" = "$EXT_VERSION" ] || {
  echo "version mismatch: project.yml $APP_VERSION, manifest.json $EXT_VERSION" >&2; exit 1; }

EXTENSION=cyou.tianli.tempo.extension
PRODUCTS=build/DerivedData/Build/Products/Release
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Copies of the extension under build/ that the system knows about (a read-only query). There should be none.
registered_build_copies() { pluginkit -m -A -D -v -i "$EXTENSION" 2>/dev/null | grep -F "$ROOT/build/" || true; }

# The settings are read out before anything else (read-only, with the command the tests just compiled), one
# file per build so that an earlier copy is never overwritten. The end of this script checks they survived.
mkdir -p build/settings
SETTINGS="build/settings/before-build-$(date +%Y%m%d-%H%M%S).json"
SETTINGS_CLI=(env TEMPO_REEXEC=1 TEMPO_RESOURCES="$ROOT/Extension/Resources" build/tests/tempo-cli)
SAVED=0
if "${SETTINGS_CLI[@]}" export > "$SETTINGS" 2>/dev/null; then
  SAVED=1
else
  rm -f "$SETTINGS"
  WHY="$("${SETTINGS_CLI[@]}" export --json 2>/dev/null || true)"
  case "$WHY" in
    *store_missing*) ;;   # Safari keeps no settings for Tempo right now: nothing to lose
    *) echo "warning: Tempo's stored settings could not be read, so this build keeps no copy of them: ${WHY:-no answer}" >&2 ;;
  esac
fi

STALE="$(registered_build_copies)"
if [ -n "$STALE" ]; then
  echo "A build copy of the extension is already registered with the system, so nothing was built:" >&2
  echo "$STALE" >&2
  echo "Safari may have dropped Tempo's settings because of it. Take the copy out by hand" >&2
  echo "(pluginkit -r <that .appex>, then lsregister -u <its .app>) and run this again." >&2
  exit 1
fi

"${PYTHON:-python3}" scripts/make-icons.py
xcodegen generate --quiet
# The app target must not embed the extension, or xcodebuild registers a copy of it (see the top).
if grep -q 'appex in ' Tempo.xcodeproj/project.pbxproj; then
  echo "project.yml puts the extension into the app target again; xcodebuild would register that copy. Not building." >&2
  exit 1
fi
# An app product left by an earlier build can still have the extension inside, and xcodebuild would register
# it as it stands. Neither copy is registered at this point (checked above), so both are simply removed.
rm -rf "$PRODUCTS/Tempo.app" build/Tempo.app
xcodebuild -project Tempo.xcodeproj -scheme Tempo -configuration Release \
  -derivedDataPath build/DerivedData ${CODE_SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"} ${DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"} -quiet build
if [ -e "$PRODUCTS/Tempo.app/Contents/PlugIns" ]; then
  echo "the app product has plug-ins inside, so xcodebuild registered them; see the check at the end" >&2
fi

# Put the two products together. Adding the extension changes what the app's signature covers, so the app is
# sealed again with the identity xcodebuild used. The extension keeps the signature and the sandbox
# entitlement its own target gave it; the app has no entitlements.
ditto "$PRODUCTS/Tempo.app" build/Tempo.app
mkdir -p build/Tempo.app/Contents/PlugIns
ditto "$PRODUCTS/TempoExtension.appex" build/Tempo.app/Contents/PlugIns/TempoExtension.appex
SIGNATURE="$(codesign -dvv "$PRODUCTS/Tempo.app" 2>&1)"
IDENTITY="${CODE_SIGN_IDENTITY:-$(sed -n 's/^Authority=//p' <<<"$SIGNATURE" | sed -n 1p)}"
[ -n "$IDENTITY" ] || { echo "could not read the signing identity from $PRODUCTS/Tempo.app" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --options runtime --timestamp build/Tempo.app
codesign --verify --deep --strict build/Tempo.app
test -f build/Tempo.app/Contents/PlugIns/TempoExtension.appex/Contents/Resources/manifest.json

# xcodebuild registered the app product, which has no extension in it. That record is dropped so that
# LaunchServices knows one Tempo.app, the installed one; build/Tempo.app was never registered.
"$LSREGISTER" -u "$ROOT/$PRODUCTS/Tempo.app" >/dev/null 2>&1 || true

FAILED=0
LEFT="$(registered_build_copies)"
if [ -n "$LEFT" ]; then
  FAILED=1
  echo "A build copy of the extension got registered during this build. That is the thing this script is" >&2
  echo "written to prevent, so find out what registered it before building again:" >&2
  echo "$LEFT" >&2
  # Left registered, the un-notarized copy stays in front of the installed one, so it is taken out again.
  while IFS= read -r line; do
    appex="$ROOT/build/${line#*"$ROOT/build/"}"
    pluginkit -r "$appex" >/dev/null 2>&1 || true
    case "$appex" in */Contents/PlugIns/*) "$LSREGISTER" -u "${appex%/Contents/PlugIns/*}" >/dev/null 2>&1 || true ;; esac
  done <<<"$LEFT"
fi

echo "built build/Tempo.app"
if [ "$SAVED" = 1 ] && ! "${SETTINGS_CLI[@]}" show >/dev/null 2>&1; then
  FAILED=1
  echo "Safari dropped Tempo's stored settings during this build. They were saved to $ROOT/$SETTINGS." >&2
  echo "Put them back in Safari: Tempo 面板 > 快捷键与设置 > 导入配置, paste the file's text, click 导入配置 again." >&2
  echo "(tempo import works only once Safari has made the store again, which the import in the panel does.)" >&2
fi
[ "$FAILED" = 0 ] || echo "build/Tempo.app itself is complete; the exit code is for the problem reported above." >&2
exit "$FAILED"
