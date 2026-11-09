#!/bin/bash
# Draws the Live Activity and the widgets to PNGs (sona-activity-*.png, sona-widget-*.png) without Xcode previews or a
# phone: builds the widgets' views and SonaWidgets/WidgetSnapshots.swift into a small executable for the iOS simulator
# and runs it there. Usage: scripts/widget-snapshots.sh [folder, default /tmp]. SIM picks the simulator (default
# "Sona iPhone"); it's booted if it isn't already.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUT="${1:-/tmp}"
SIM="${SIM:-Sona iPhone}"
BIN=build/widget-snapshots
mkdir -p build

# Everything the widgets are drawn with, but not the @main bundle (the executable has its own entry point) or the previews.
FILES=(Shared/SonaIDs.swift Shared/RecordingAttributes.swift Shared/RecordingIntents.swift Shared/SonaTheme.swift)
for f in SonaWidgets/*.swift; do
  case "$f" in
    */SonaWidgetsBundle.swift | */WidgetPreviews.swift) ;;
    *) FILES+=("$f") ;;
  esac
done

xcrun swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios26.0-simulator \
  -swift-version 6 -default-isolation MainActor -D DEBUG -D WIDGET_EXTENSION \
  -o "$BIN" "${FILES[@]}" scripts/widget-snapshots/main.swift

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl spawn "$SIM" "$PWD/$BIN" "$OUT" 2>&1 | grep -v IOSurfaceClientSetSurfaceNotify
