// The fixture page, as a C string so the fixture needs no bundle resources.
//
// Signals are carried by *request id*, because ids are already logged by the
// dispatcher and need no extra native code to observe. Each is sent at most
// once — an earlier version of this page re-sent its confirmation from inside
// the reply handler that the confirmation's own reply then re-entered, which
// span forever and made the assertion pass on its first iteration regardless.
//
//   i=1  the page called native
//   i=2  native's reply came back carrying a real UIKit systemName
//   i=3  the user script had already run when the page's own script executed
//
// i=2 is the one that matters. It cannot be produced by a stub, a browser
// fallback, or native talking to itself: it exists only if the page received
// and understood an answer that came from UIKit.
const char craft_slice_page[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    "</head><body><h1 id=\"s\">craft slice</h1><script>\n"
    "var sentRoundTrip = false;\n"
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
    "window.__craftBridgeResult = function (action, payload, id) {\n"
    "  window.__craftSliceAck = JSON.stringify({action: action, id: id, payload: payload});\n"
    "  document.getElementById('s').textContent = window.__craftSliceAck;\n"
    "  if (!sentRoundTrip && payload && payload.systemName === 'iOS') {\n"
    "    sentRoundTrip = true;\n"
    "    bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:2});\n"
    "  }\n"
    "};\n"
    "\n"
    "if (bridge) {\n"
    "  bridge.postMessage({t:'mobile', a:'getDeviceInfo', i:1});\n"
    "} else {\n"
    "  document.getElementById('s').textContent = 'NO BRIDGE';\n"
    "}\n"
    "</script></body></html>";

const unsigned long craft_slice_page_len = sizeof(craft_slice_page) - 1;
