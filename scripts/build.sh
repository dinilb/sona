#!/bin/zsh
# Builds build/Sona.app from a clean checkout. Everything stays inside build/.
#   Sona.app/Contents/MacOS/Sona        the app (menu bar, window, live transcript, dictation, notes)
#   Sona.app/Contents/MacOS/sona-mcp    the MCP server (stdio)
#   Sona.app/Contents/Helpers/sona      the CLI (file, simulate, models, mcp, ...)
# Also build/sona-live-bench (the latency bench; not in the app).
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --scratch-path build/spm
BIN=$(swift build -c "$CONFIG" --scratch-path build/spm --show-bin-path)

APP=build/Sona.app
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # drawn in design/icon (render.swift)
cp Resources/com.dinilb.sona.keepalive.plist "$APP/Contents/Library/LaunchAgents/"
cp "$BIN/SonaApp" "$APP/Contents/MacOS/Sona"
cp "$BIN/sona-mcp" "$APP/Contents/MacOS/sona-mcp"
cp "$BIN/sona" "$APP/Contents/Helpers/sona"
# Licences: ours, the credits, and FluidAudio's licence with its own third-party notices.
FA=build/spm/checkouts/FluidAudio
mkdir -p "$APP/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
cp "$FA/LICENSE" "$APP/Contents/Resources/Licenses/FluidAudio-LICENSE.txt"
cp "$FA/ThirdPartyLicenses/vbx-LICENSE.md" "$FA/ThirdPartyLicenses/fastcluster-LICENSE.md" "$APP/Contents/Resources/Licenses/"

# Sparkle, the updater: its framework goes in Contents/Frameworks, where the app's rpath looks. Sona isn't sandboxed,
# so Sparkle's XPC services aren't needed and are left out (fewer pieces to sign, nothing unused shipped).
SPARKLE="$BIN/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE=$(find build/spm/artifacts -type d -path '*macos*/Sparkle.framework' | head -1)
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework not found after swift build" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp build/spm/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Licenses/Sparkle-LICENSE.txt"

# A stable identity keeps macOS privacy grants (mic, Accessibility for dictation) and the login item across
# rebuilds; ad-hoc signatures change every build, so they'd be asked for again each time. The first Developer
# ID in the keychain is used, if there is one; SIGN_IDENTITY picks another, or `-` for ad hoc.
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
[[ "$IDENTITY" != "-" ]] || IDENTITY=""
echo "==> signing (${IDENTITY:-ad hoc}, hardened runtime)"
# The hardened runtime, as in a release, even ad hoc: without it any process of this user could inject a library
# (DYLD_INSERT_LIBRARIES) and use Sona's mic, Accessibility and System Audio grants. It blocks the mic unless the
# app has the audio-input entitlement. Everything Sona loads is its own code or the system's, so library
# validation can stay on.
# No secure timestamp here (a Developer ID asks for one by default, and Apple's server is sometimes slow or down);
# `make release` signs again with one.
sign() { codesign --force --options runtime --timestamp=none --sign "${IDENTITY:--}" "$@"; }
# Inside out: Sparkle's helper and its updater app, then the framework, then Sona's own binaries and the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"
sign "$SPARKLE_FW"
sign --identifier com.dinilb.sona.mcp "$APP/Contents/MacOS/sona-mcp"
sign --identifier com.dinilb.sona.cli "$APP/Contents/Helpers/sona"
sign --entitlements Resources/Sona.entitlements "$APP"
codesign --verify --strict "$APP"

# Handy copies for the terminal.
ln -sf Sona.app/Contents/Helpers/sona build/sona
ln -sf Sona.app/Contents/MacOS/sona-mcp build/sona-mcp
ln -sf spm/$CONFIG/sona-live-bench build/sona-live-bench
echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
