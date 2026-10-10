#!/bin/bash
# Sends build/Tempo.app to Apple's notary service and staples the ticket to it.
#
#   bash scripts/notarize.sh [path/to/Tempo.app]
#
# Safari lists an extension from outside the App Store only when its app is notarized (or the Develop
# menu's "Allow unsigned extensions" is on, which resets every time Safari quits). Credentials come from
# NOTARY_PROFILE (a notarytool keychain profile), or ASC_KEY_ID + ASC_ISSUER_ID with the key file at
# NOTARY_KEY_FILE (default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8).
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -le 1 ] || { echo 'Usage: bash scripts/notarize.sh [path/to/Tempo.app]' >&2; exit 2; }
APP="${1:-$PWD/build/Tempo.app}"
[ -d "$APP" ] || { echo 'App not found. Run bash build.sh first.' >&2; exit 1; }

if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  KEY_FILE="${NOTARY_KEY_FILE:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [ -f "$KEY_FILE" ] || { echo 'Notary API private key file is missing.' >&2; exit 1; }
  AUTH=(--key "$KEY_FILE" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  echo 'Set NOTARY_PROFILE, or ASC_KEY_ID / ASC_ISSUER_ID / NOTARY_KEY_FILE.' >&2
  exit 1
fi

OUT="$PWD/build/notarize"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/Tempo.zip"
xcrun notarytool submit "$OUT/Tempo.zip" "${AUTH[@]}" --wait --timeout 20m --output-format json > "$OUT/result.json"
STATUS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$OUT/result.json")"
ID="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$OUT/result.json")"
if [ "$STATUS" != "Accepted" ]; then
  echo "notarization $STATUS (id $ID); log follows" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
# `stapler validate` above leaves a LaunchServices record for the app it was shown (2026-10-07: run on its
# own, the record was there right after it, marked launch-disabled and not listing the extension inside).
# A build copy's record is dropped so that LaunchServices knows one Tempo.app, the installed one, as at the
# end of build.sh. Dropping a record that lists no extension was watched with Safari open: the extension
# stayed enabled and its stored settings stayed as they were.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
case "$(cd "$APP" && pwd -P)" in
  /Applications/*) ;;
  *) "$LSREGISTER" -u "$(cd "$APP" && pwd -P)" >/dev/null 2>&1 || true ;;
esac
echo "notarized $APP (id $ID)"
