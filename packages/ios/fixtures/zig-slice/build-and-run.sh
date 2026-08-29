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

echo "==> compiling the fixture"
# The ObjC translation units first, then swiftc drives the link. swiftc is the
# linker rather than clang because Swift auto-links compatibility shims
# (swiftCompatibility56 and friends) that live in the toolchain, not the SDK —
# clang cannot find them and the link fails on undefined symbols.
clang -isysroot "$SDK" -target "$TRIPLE" -fobjc-arc -O1 -c \
    "$FIXTURE/main.m" -o "$OUT/main.o"
clang -isysroot "$SDK" -target "$TRIPLE" -fobjc-arc -O1 -c \
    "$FIXTURE/page.m" -o "$OUT/page.o"

# Simulator keychain identity. On the simulator, application-identifier and
# keychain-access-groups are NOT signed in — a signature carrying them is
# refused at launch (POSIX 163 from RunningBoard, bisected: the same signature
# without them launches). Xcode instead embeds them as a __TEXT,__entitlements
# section and the simulator's security layer reads them from there. Without
# any identity, SecItemAdd fails with errSecMissingEntitlement (-34018).
cat > "$OUT/sim.entitlements" <<'ENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key><string>SLICE00000.app.craft.slice</string>
    <key>keychain-access-groups</key>
    <array><string>SLICE00000.app.craft.slice</string></array>
</dict>
</plist>
ENTS

echo "==> linking CraftSlice"
# The shim class has to survive into the binary for
# `objc_getClass("CraftSwiftShim")` to find it at runtime. Compiling it into
# the executable directly (rather than through an archive) is what guarantees
# that: a linker is free to drop an archive member nothing references
# statically, and a class reached only by name is exactly that.
swiftc -target "$TRIPLE" -sdk "$SDK" \
    -parse-as-library -O \
    "$FIXTURE/shim.swift" \
    "$OUT/main.o" "$OUT/page.o" \
    "$ROOT/packages/zig/zig-out/lib/$LIB" \
    -framework UIKit -framework WebKit -framework Foundation -framework Security \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$OUT/sim.entitlements" \
    -o "$APP/CraftSlice"

cp "$FIXTURE/Info.plist" "$APP/Info.plist"

# Ad-hoc signature. The identity entitlements live in the __entitlements
# section above; signing them in instead makes the launch be denied.
codesign --force --sign - "$APP"


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
    if grep -q 'i=7' "$LOG" 2>/dev/null && grep -q 'i=10' "$LOG" 2>/dev/null; then sleep 1; break; fi
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

count() { grep -cE "craft-bridge dispatch t=mobile a=[A-Za-z]+ i=$1\$" "$PLAIN" || true; }

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

C4="$(count 4)"; C5="$(count 5)"

[ "$C4" -ge 1 ] || { echo "FAIL: the host-only action never reached the dispatcher"; exit 1; }
echo "ok: unserved action reached the dispatcher (i=4 seen ${C4}x)"

# servedBy is a string only the shim writes, and it came back through Zig's own
# reply path. Neither side could have produced this alone.
[ "$C5" -ge 1 ] || { echo "FAIL: the host shim never answered, or its answer never reached the page"; exit 1; }
echo "ok: hand-off to host shim closed (i=5 seen ${C5}x)"

C6="$(count 6)"; C7="$(count 7)"

[ "$C6" -ge 1 ] || { echo "FAIL: the rejecting action never reached the dispatcher"; exit 1; }
echo "ok: rejecting action reached the dispatcher (i=6 seen ${C6}x)"

# i=7 requires the page's __craftBridgeError handler to have seen error:true,
# the HOST_DECLINED code, id 6, and a message whose backslash, quote and
# newline survived Zig's escaping. Any of those wrong and this never fires.
[ "$C7" -ge 1 ] || { echo "FAIL: the shim's rejection never reached the page intact"; exit 1; }
echo "ok: error route closed with escaping intact (i=7 seen ${C7}x)"

C8="$(count 8)"
[ "$C8" -ge 1 ] || { echo "FAIL: the Tier-0 action's reply never carried a real app state"; exit 1; }
echo "ok: Tier-0 action served by Zig with a live UIKit value (i=8 seen ${C8}x)"

C10="$(count 10)"
[ "$C10" -ge 1 ] || { echo "FAIL: the Keychain round trip never completed byte-identical"; exit 1; }
echo "ok: secureSet/secureGet round-tripped a secret through the Keychain (i=10 seen ${C10}x)"

echo "PASS"
