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
    -framework Vision -framework LocalAuthentication -framework PDFKit \
    -framework WatchConnectivity -framework CoreBluetooth \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$OUT/sim.entitlements" \
    -o "$APP/CraftSlice"

cp "$FIXTURE/Info.plist" "$APP/Info.plist"

# The capability configuration, bundled exactly where a generated app puts it:
# `project.yml.template` copies craft.config.json into the app as a resource,
# and both runtimes read it from `[NSBundle mainBundle]`. Without it every
# capability is off — which is Swift's own fallback, and would take the
# Keychain, SQLite and notification assertions below down with it.
cp "$FIXTURE/craft.config.json" "$APP/craft.config.json"

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
    if grep -q 'i=26' "$LOG" 2>/dev/null && grep -q 'i=28' "$LOG" 2>/dev/null \
       && grep -q 'i=32' "$LOG" 2>/dev/null && grep -q 'i=22' "$LOG" 2>/dev/null \
       && grep -q 'i=34' "$LOG" 2>/dev/null && grep -q 'i=38' "$LOG" 2>/dev/null \
       && grep -q 'i=46' "$LOG" 2>/dev/null && grep -q 'i=44' "$LOG" 2>/dev/null \
       && grep -q 'i=24' "$LOG" 2>/dev/null && grep -q 'i=20' "$LOG" 2>/dev/null; then sleep 1; break; fi
    sleep 1
done
kill "$LAUNCH_PID" 2>/dev/null || true

echo "==> console"
cat "$LOG" || true


# Every id this file asserts on must be posted by exactly one action in
# page.m. `count` matches `a=<anything> i=<n>`, so an id shared between a
# marker and a real call makes the assertion pass on the wrong dispatch — which
# is how i=30 briefly "proved" detectObjects answered while it was really
# seeing secureSet. Checked here rather than trusted, because the failure is
# silent and looks like a pass.
echo "==> marker ids"
python3 - "$FIXTURE/page.m" "${BASH_SOURCE[0]}" <<'COLLIDE'
import re, sys, collections
page, harness = open(sys.argv[1]).read(), open(sys.argv[2]).read()
uses = collections.defaultdict(set)
for line in page.split("\n"):
    if "postMessage" not in line: continue
    a, i = re.search(r"a:'(\w+)'", line), re.search(r"i:(\d+)", line)
    if a and i: uses[int(i.group(1))].add(a.group(1))
bad = [(i, sorted(uses[i])) for i in set(int(x) for x in re.findall(r'count (\d+)', harness))
       if len(uses.get(i, ())) > 1]
for i, acts in bad:
    print(f"FAIL: asserted id {i} is posted by {len(acts)} actions: {' '.join(acts)}")
sys.exit(1 if bad else 0)
COLLIDE
echo "ok: every asserted id belongs to exactly one action"

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

C12="$(count 12)"
[ "$C12" -ge 1 ] || { echo "FAIL: the SQLite round trip never returned the bound value"; exit 1; }
echo "ok: dbExecute/dbQuery round-tripped through in-process SQLite (i=12 seen ${C12}x)"

C14="$(count 14)"
[ "$C14" -ge 1 ] || { echo "FAIL: the async array reply never reached the page"; exit 1; }
echo "ok: async NSArray completion delivered via ios_async (i=14 seen ${C14}x)"

C16="$(count 16)"
# The simulator has no device motion. A module that fabricated a stream would
# fire craftMotionUpdate and trip i=16; an honest one refuses and never does.
[ "$C16" -eq 0 ] || { echo "FAIL: motion emitted on a simulator that has no motion sensor"; exit 1; }
echo "ok: unavailable sensor refused rather than faking a stream (i=16 absent)"

C60="$(count 60)"
[ "$C60" -ge 1 ] || { echo "FAIL: startMotionUpdates never reached the dispatcher"; exit 1; }
echo "ok: event-driven action dispatched to Zig (i=60 seen ${C60}x)"

C18="$(count 18)"
# The fixture has no NSCameraUsageDescription, and presenting a camera picker
# without one TERMINATES the process — so the module refuses before it ever
# asks whether hardware exists, with PERMISSION_DENIED. What is asserted
# is that the code is specific: the generic NATIVE_CALL_FAILED would send
# whoever reads it looking for a bug that is not there.
[ "$C18" -ge 1 ] || { echo "FAIL: the refusal did not name its own cause"; exit 1; }
echo "ok: unavailable hardware refused with a specific code (i=18 seen ${C18}x)"

C80="$(count 80)"
[ "$C80" -ge 1 ] || { echo "FAIL: the disabled-capability call never reached the dispatcher"; exit 1; }
echo "ok: gated action reached the dispatcher (i=80 seen ${C80}x)"

C20="$(count 20)"
# The whole point of the capability gate. clipboardRead is served by Zig and
# gated on enableClipboard, which this fixture's config sets to false. The
# Swift spec drops the callback on 60 of its 65 gated cases, so the page would
# wait out its timeout with nothing to show for it; here an answer comes back,
# and its code names the configuration rather than a permission a user could
# grant by answering a prompt.
[ "$C20" -ge 1 ] || { echo "FAIL: a disabled capability hung instead of replying CAPABILITY_DISABLED"; exit 1; }
echo "ok: disabled capability refused with CAPABILITY_DISABLED (i=20 seen ${C20}x)"

# And the gate is not simply refusing everything: the Keychain, SQLite and
# notification assertions above all ran through actions the same config
# *enables*, so i=10, i=12 and i=14 passing is the other half of this check.
echo "ok: enabled capabilities still served (i=10, i=12, i=14 above)"

C22="$(count 22)"
# i=22 requires the reply to have been a bare JSON string, carried the data URL
# prefix, base64-decoded to the PNG signature, and exceeded a size floor. Only
# a real render of the window layer satisfies all four.
[ "$C22" -ge 1 ] || { echo "FAIL: takeScreenshot did not return a decodable PNG data URL"; exit 1; }
echo "ok: screenshot rendered the live window to a real PNG (i=22 seen ${C22}x)"

C24="$(count 24)"
[ "$C24" -ge 1 ] || { echo "FAIL: the deep-link handshake did not reply Swift's bare true"; exit 1; }
echo "ok: deep-link handshake replied true behind its own gate (i=24 seen ${C24}x)"

C26="$(count 26)"
# The strongest assertion in this file. Vision read back the exact word the
# page drew, through base64 -> NSData -> UIImage -> CGImage -> Vision, off the
# main queue, with the request id carried across the hop by an ios_async
# ticket. Nothing short of the whole path produces 'CRAFT'.
[ "$C26" -ge 1 ] || { echo "FAIL: recognizeText did not read back the word the page drew"; exit 1; }
echo "ok: OCR round-tripped a page-drawn word off the main queue (i=26 seen ${C26}x)"

# classifyImage and detectObjects are Core ML backed. The simulator cannot
# create an inference context for either ("Failed to create espresso context"),
# while Vision's text recogniser above uses a different path and works. So what
# is asserted here is the property this phase actually establishes: the call is
# ANSWERED. Both were gated in Swift with no else, which left the page's
# promise pending until its timeout; a real result and a named failure both
# settle it, and the page accepts either.
C28="$(count 28)"
[ "$C28" -ge 1 ] || { echo "FAIL: classifyImage neither answered nor failed — it hung"; exit 1; }
echo "ok: classifyImage answered rather than hanging (i=28 seen ${C28}x)"

C32="$(count 32)"
[ "$C32" -ge 1 ] || { echo "FAIL: detectObjects neither answered nor failed — it hung"; exit 1; }
echo "ok: detectObjects answered rather than hanging (i=32 seen ${C32}x)"

C34="$(count 34)"
[ "$C34" -ge 1 ] || { echo "FAIL: authenticate did not refuse with a specific code"; exit 1; }
echo "ok: biometrics refused by the framework, not by a missing class (i=34 seen ${C34}x)"

C36="$(count 36)"
[ "$C36" -ge 1 ] || { echo "FAIL: registerSiriShortcut did not echo the donated shortcut"; exit 1; }
echo "ok: NSUserActivity donated and echoed back (i=36 seen ${C36}x)"

C38="$(count 38)"
# removeSiriShortcut answers from a void(^)(void) completion that carries no
# arguments at all, so this reply arriving proves Foundation fired the block
# and the parked payload was delivered under the right request id.
[ "$C38" -ge 1 ] || { echo "FAIL: the deletion completion never fired, or its reply was lost"; exit 1; }
echo "ok: argument-free completion block delivered its parked reply (i=38 seen ${C38}x)"

C46="$(count 46)"
# pageCount is PDFKit's answer for the bytes the page sent, so it cannot be
# produced without actually loading the document — and openPDF only replies
# after presenting, so a viewer is on screen at this point.
[ "$C46" -ge 1 ] || { echo "FAIL: openPDF did not load and present the document"; exit 1; }
echo "ok: PDF parsed and presented full screen (i=46 seen ${C46}x)"

C44="$(count 44)"
# The half that cannot be split from the other: closePDF dismisses the
# controller openPDF stored, so this passing is what proves both halves live
# in the same language.
[ "$C44" -ge 1 ] || { echo "FAIL: closePDF did not dismiss the viewer"; exit 1; }
echo "ok: the same module that presented the viewer dismissed it (i=44 seen ${C44}x)"

C48="$(count 48)"
[ "$C48" -ge 1 ] || { echo "FAIL: downloadFile did not land a file in Documents"; exit 1; }
echo "ok: URL fetched and moved into the app container (i=48 seen ${C48}x)"

C52="$(count 52)"
# NOT_FOUND rather than PLATFORM_NOT_SUPPORTED: WatchConnectivity is linked, so
# WCSession itself reported no reachable watch. Before this phase the action
# reached the shim instead, because ios_async had no way to deliver an error —
# which is the common branch here, not the exotic one.
[ "$C52" -ge 1 ] || { echo "FAIL: sendToWatch did not refuse through the error path"; exit 1; }
echo "ok: watch refusal delivered through the async error path (i=52 seen ${C52}x)"

C54="$(count 54)"
# The exact trap this action was held back for: ios_async's pooled block would
# have replied the STRING "denied", and "denied" is truthy — so a page's
# `if (await openSettings())` would take the success branch on failure. The
# page asserts `typeof payload === 'boolean'`, which only the module's own
# block can satisfy. Posted last, because it navigates to Settings.
[ "$C54" -ge 1 ] || { echo "FAIL: openSettings did not reply with a boolean"; exit 1; }
echo "ok: openSettings replied a real boolean, not \"granted\"/\"denied\" (i=54 seen ${C54}x)"

C56="$(count 56)"
# The refusal comes from centralManagerDidUpdateState, not from the handler:
# startBluetoothScan returns having done nothing but create a manager, and the
# radio answers later. So this passing proves the ticket survived the gap
# between the call and the callback.
[ "$C56" -ge 1 ] || { echo "FAIL: startBluetoothScan did not refuse from the state callback"; exit 1; }
echo "ok: scan refused by the radio's own state, via a deferred ticket (i=56 seen ${C56}x)"

C58="$(count 58)"
[ "$C58" -ge 1 ] || { echo "FAIL: stopBluetoothScan did not resolve"; exit 1; }
echo "ok: stopping with nothing running still answers true (i=58 seen ${C58}x)"

echo "PASS"
