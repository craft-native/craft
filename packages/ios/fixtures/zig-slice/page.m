// The fixture page, as a C string so the fixture needs no bundle resources.
//
// Signals are carried by *request id*, because ids are already logged by the
// dispatcher and need no extra native code to observe. Each is sent at most
// once — an earlier version re-sent its confirmation from inside the reply
// handler that the confirmation's own reply then re-entered, which span
// forever and made the assertion pass on its first iteration regardless.
//
//   i=1  the page called an action Zig serves
//   i=2  that reply came back carrying a real UIKit systemName
//   i=3  the user script had already run when the page's own script executed
//   i=4  the page called an action Zig does *not* serve
//   i=5  that reply came back, having been answered by the host shim
//   i=6  the page called an action the shim answers by *rejecting*
//   i=7  the rejection arrived via __craftBridgeError with its id, code, and
//        an unmangled message — proving the error route and Zig-side escaping
//
// i=2 and i=5 are the load-bearing ones, and they prove different things.
// i=2 cannot be produced by a stub: only a real UIKit process reports
// systemName "iOS". i=5 cannot be produced by Zig alone: `servedBy` is a
// string only the shim writes, delivered back through Zig's own reply path.
// Together they show both arms of the dispatcher reaching the same page over
// one protocol.
const char craft_slice_page[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    "</head><body><h1 id=\"s\">craft slice</h1><script>\n"
    "var sentRoundTrip = false, sentHandOff = false;\n"
    "var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.craft;\n"
    "\n"
    "// Read before anything else touches it: the user script is installed at\n"
    "// atDocumentStart, so it must already have run by the time this inline\n"
    "// script does. The previous implementation injected after navigation had\n"
    "// begun, which wiped it — this is the check for that.\n"
    "if (window.__craftInjectedAtDocumentStart === true && bridge) {\n"
    "  bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:3});\n"
    "}\n"
    "\n"
    "var sentErrorAck = false;\n"
    "window.__craftBridgeError = function (ctx) {\n"
    "  // The message crossed Zig's escaping with a backslash, quote, and\n"
    "  // newline intact; anything mangled and this equality fails, i=7 never\n"
    "  // fires, and the harness reports the error route broken.\n"
    "  var messageIntact = ctx && ctx.message === 'declined \\\\ \"on purpose\"\\nsecond line';\n"
    "  if (!sentErrorAck && ctx && ctx.error === true && ctx.code === 'HOST_DECLINED'\n"
    "      && ctx.id === 6 && messageIntact) {\n"
    "    sentErrorAck = true;\n"
    "    bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:7});\n"
    "  }\n"
    "};\n"
    "window.__craftBridgeResult = function (action, payload, id) {\n"
    "  window.__craftSliceAck = JSON.stringify({action: action, id: id, payload: payload});\n"
    "  document.getElementById('s').textContent = window.__craftSliceAck;\n"
    "\n"
    "  if (!sentRoundTrip && payload && payload.systemName === 'iOS') {\n"
    "    sentRoundTrip = true;\n"
    "    bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:2});\n"
    "  }\n"
    "\n"
    "  // `language` is written by the Swift shim and by nothing else, so this\n"
    "  // distinguishes a real hand-off from Zig answering by some other route.\n"
    "  // Zig routed the call out, Swift answered through\n"
    "  // craft_ios_deliver_result, and Zig delivered it here over the same\n"
    "  // protocol it uses for its own actions.\n"
    "  if (!sentHandOff && payload && payload.servedBy === 'host-shim'\n"
    "      && payload.language === 'swift') {\n"
    "    sentHandOff = true;\n"
    "    bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:5});\n"
    "  }\n"
    "};\n"
    "\n"
    "if (bridge) {\n"
    "  bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:1});\n"
    "  // An action Zig does not serve, so it must reach the host shim.\n"
    "  bridge.postMessage({t:'mobile', a:'hostOnlyPing', i:4});\n"
    "  // And one the shim answers by rejecting, to prove the error route.\n"
    "  bridge.postMessage({t:'mobile', a:'hostOnlyFail', i:6});\n"
    "} else {\n"
    "  document.getElementById('s').textContent = 'NO BRIDGE';\n"
    "}\n"
    "</script></body></html>";

const unsigned long craft_slice_page_len = sizeof(craft_slice_page) - 1;
