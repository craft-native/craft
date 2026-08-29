#!/usr/bin/env bash
# Type-check CraftApp.swift without generating a project.
#
# The template cannot be compiled as-is: it carries {{BUNDLE_ID}} placeholders
# and top-level code, and it references CraftActivityAttributes from a sibling
# template. This substitutes a dummy id, adds -parse-as-library, and includes
# the sibling — which is exactly what the generated app does, minus xcodegen.
#
# Detecting failure by exit code, not by grepping for "error:": the file is
# full of `rejectCallback(callbackId, error: ...)` argument labels, and a grep
# happily counts those as compiler errors. That mistake already cost a cycle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TPL="$ROOT/packages/ios/templates"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sed 's/{{BUNDLE_ID}}/app.craft.typecheck/g' "$TPL/CraftApp.swift" > "$TMP/CraftApp.swift"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swiftc -typecheck -parse-as-library \
    -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
    "$TMP/CraftApp.swift" "$TPL/CraftActivityAttributes.swift"

echo "CraftApp.swift typechecks"
