#!/usr/bin/env bash
# Build the Phase 1 fixture, install it on a simulator, and assert the round trip.
#
# Deliberately no Xcode project. `xcodegen` is an extra dependency for a
# four-file app, and a hand-written .pbxproj is worse. clang can build an app
# bundle directly, and doing it here keeps every step visible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ZIG="${CRAFT_ZIG:-$HOME/.cache/craft-ci-local/zig-aarch64-macos-0.17.0-dev.1509+bb296ab9b/zig}"
FIXTURE="$ROOT/packages/ios/fixtures/zig-slice"
OUT="${1:-$FIXTURE/build}"
BUNDLE_ID="app.craft.slice"

ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then LIB="libcraft-ios-simulator-arm64.a"; TRIPLE="arm64-apple-ios15.0-simulator"
else LIB="libcraft-ios-simulator-x64.a"; TRIPLE="x86_64-apple-ios15.0-simulator"; fi

echo "==> building the craft iOS simulator library"
(cd "$ROOT/packages/zig" && "$ZIG" build build-ios-simulator -Doptimize=ReleaseSafe)

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
APP="$OUT/CraftSlice.app"
rm -rf "$OUT"; mkdir -p "$APP"

echo "==> linking CraftSlice"
clang -isysroot "$SDK" -target "$TRIPLE" \
    -fobjc-arc -O1 \
    "$FIXTURE/main.m" "$FIXTURE/page.m" \
    "$ROOT/packages/zig/zig-out/lib/$LIB" \
    -framework UIKit -framework WebKit -framework Foundation \
    -o "$APP/CraftSlice"

cp "$FIXTURE/Info.plist" "$APP/Info.plist"

echo "==> booting a simulator"
UDID="$(xcrun simctl list devices available -j \
    | python3 -c 'import json,sys;d=json.load(sys.stdin)["devices"];print(next(x["udid"] for k in d for x in d[k] if "iPhone" in x["name"]))')"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b

echo "==> installing and launching"
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

LOG="$OUT/console.log"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" > "$LOG" 2>&1 &
LAUNCH_PID=$!

# The round trip is fast, but a cold simulator is not. Poll rather than sleep a
# fixed amount, so a slow boot does not read as a failure.
for _ in $(seq 1 60); do
    if grep -q 'i=2' "$LOG" 2>/dev/null && grep -q 'i=3' "$LOG" 2>/dev/null; then sleep 1; break; fi
    sleep 1
done
kill "$LAUNCH_PID" 2>/dev/null || true

echo "==> console"
cat "$LOG" || true

echo
echo "==> assertions"

# Strip the log colouring before matching, so a grep failure means the line is
# absent rather than differently decorated.
PLAIN="$OUT/console.plain"
sed -e $'s/\x1b\[[0-9;]*m//g' -e 's/\r$//' "$LOG" > "$PLAIN"

count() { grep -c "craft-bridge dispatch t=mobile a=getDeviceInfo i=$1" "$PLAIN" || true; }

C1="$(count 1)"; C2="$(count 2)"; C3="$(count 3)"

[ "$C1" -ge 1 ] || { echo "FAIL: the page's call never reached the dispatcher"; exit 1; }
echo "ok: page -> native (i=1 seen ${C1}x)"

[ "$C2" -ge 1 ] || { echo "FAIL: the page never got a usable reply back"; exit 1; }
echo "ok: native -> page, round trip closed (i=2 seen ${C2}x)"

# The round-trip confirmation is sent once, from a guarded branch. More than one
# means the reply re-entered the handler that sent it — which would make the
# assertion above pass on its first iteration no matter what followed.
[ "$C2" -eq 1 ] || { echo "FAIL: round-trip confirmation fired $C2 times; the fixture is looping"; exit 1; }
echo "ok: no feedback loop"

[ "$C3" -ge 1 ] || { echo "FAIL: the user script had not run when the page executed"; exit 1; }
echo "ok: user script ran at document start"

echo "PASS"
