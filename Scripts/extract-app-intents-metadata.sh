#!/bin/bash
# Extract App Intents metadata for the manually assembled SwiftPM application.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?usage: extract-app-intents-metadata.sh /path/to/Impuls.app}"
BINARY="$APP/Contents/MacOS/Impuls"
OUTPUT="$APP/Contents/Resources"
SOURCE="$ROOT/Sources/ImpulsLauncher/AppIntents.swift"

PROCESSOR="$(xcrun --find appintentsmetadataprocessor)"
DEVELOPER_DIR="$(xcode-select -p)"
TOOLCHAIN_DIR="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_TRIPLE="$(swift -print-target-info | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"]["triple"])')"

[ -x "$PROCESSOR" ] || { echo "appintentsmetadataprocessor is unavailable" >&2; exit 1; }
[ -x "$BINARY" ] || { echo "Impuls executable is missing before App Intents extraction" >&2; exit 1; }
[ -f "$SOURCE" ] || { echo "App Intents source is missing" >&2; exit 1; }

rm -rf "$OUTPUT/Metadata.appintents"

"$PROCESSOR" \
    --output "$OUTPUT" \
    --toolchain-dir "$TOOLCHAIN_DIR" \
    --module-name Impuls \
    --source-files "$SOURCE" \
    --sdk-root "$SDK_ROOT" \
    --target-triple "$TARGET_TRIPLE" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --bundle-identifier io.tumanov.impuls \
    --binary-file "$BINARY"

METADATA="$OUTPUT/Metadata.appintents"
test -d "$METADATA" || { echo "App Intents metadata directory was not produced" >&2; exit 1; }
test -s "$METADATA/extract.actionsdata" || { echo "App Intents actions metadata is empty" >&2; exit 1; }
test -s "$METADATA/version.json" || { echo "App Intents version metadata is empty" >&2; exit 1; }
