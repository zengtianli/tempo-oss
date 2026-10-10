#!/bin/bash
# Runs the extension's scripts against a real WebKit page, offscreen: once as shipped, once with the
# page-world engine removed (the standby engine must carry ordinary media, and the checks that need the
# page world must notice). Fixtures are silent and generated on first use.
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURES=Tests/fixtures
mkdir -p "$FIXTURES" build/tests
[ -f "$FIXTURES/clip.mp4" ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc=duration=40:size=160x90:rate=30" \
  -an -c:v libx264 -pix_fmt yuv420p -preset veryfast -movflags +faststart "$FIXTURES/clip.mp4"
[ -f "$FIXTURES/silence.wav" ] || ffmpeg -loglevel error -y -f lavfi -i "anullsrc=r=8000:cl=mono" -t 40 \
  -c:a pcm_u8 "$FIXTURES/silence.wav"

HARNESS=build/tests/harness
if [ ! -x "$HARNESS" ] || [ Tests/harness.swift -nt "$HARNESS" ]; then
  swiftc -O -o "$HARNESS" Tests/harness.swift
fi

"$HARNESS" "$PWD/Extension/Resources" "$PWD/Tests"
"$HARNESS" "$PWD/Extension/Resources" "$PWD/Tests" --no-page-engine

# The settings commands, against a throwaway store.
bash Tests/cli.sh
