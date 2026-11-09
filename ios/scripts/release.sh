#!/bin/bash
# One command to TestFlight, from ios/:   make release NOTES="what to test"
# Archives, signs (cloud signing with the App Store Connect API key, which also creates any missing profiles),
# checks the signed IPA against project.yml (entitlements, background modes, the location string), uploads, waits
# for Apple's processing and hands the build to the "Personal Testing" group. The build number is the time
# (YYMMDDHHMM), so there's nothing to bump.
# The key comes from the active `asc` profile at run time (key ID from `asc auth status`, issuer from
# `asc auth issuer-id`, the .p8 from ~/.asc/keys/). Nothing secret is stored in the repo or printed.
# EXPORT_ONLY=1 stops after signing (checks signing without uploading). It stops first if the tree has uncommitted
# changes (ALLOW_DIRTY=1 goes on anyway) or the history has tool attribution.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ASC="${ASC:-/opt/homebrew/bin/asc}"
APP_ID="${ASC_APP_ID:-6829732693}"  # "Sona Notes" in App Store Connect (bundle ID com.dinilb.sona); set ASC_APP_ID for another app
GROUP="${TESTFLIGHT_GROUP_ID:-865243e7-dd63-4e22-bc72-75ae1646d00e}"  # TESTFLIGHT_GROUP_ID overrides; the default is "Personal Testing" (internal: only you). By id: a name lookup failed once
BUILD="${BUILD:-$(date +%y%m%d%H%M)}"
NOTES="${NOTES:-$(git log -1 --format=%s | cut -c1-3900)}"
ARCHIVE="build/Sona.xcarchive"
EXPORT="build/export"

# The same guards as the Mac's release (scripts/release.sh): what ships is what's committed, and the history has no
# tool attribution (human co-authors are fine). ALLOW_DIRTY=1 ships uncommitted changes anyway.
if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git status --porcelain)" ]]; then
  echo "Uncommitted changes. Commit them, or run with ALLOW_DIRTY=1." >&2
  exit 1
fi
if git log --format='%an %ae %cn %ce %B' | grep -qiE "co-authored-by:.*(claude|anthropic|copilot|codex|openai|chatgpt|cursor|gemini)|noreply@anthropic\.com|generated with"; then
  echo "AI attribution in the git history. Not releasing." >&2
  exit 1
fi

KEY_ID="$("$ASC" auth status 2>/dev/null | python3 -I -c "import json,sys;print(json.load(sys.stdin)['credentials'][0]['keyId'])" 2>/dev/null || true)"
ISSUER_ID="$("$ASC" auth issuer-id 2>/dev/null | tr -d '[:space:]' || true)"
KEY_PATH="$HOME/.asc/keys/AuthKey_${KEY_ID}.p8"
[[ -n "$KEY_ID" && -n "$ISSUER_ID" && -f "$KEY_PATH" ]] || {
  echo "No usable asc key. Run: asc auth status --validate (and see ios/README.md)" >&2
  exit 1
}

echo "==> build $BUILD"
xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project Sona.xcodeproj -scheme Sona -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGNING_ALLOWED=NO -quiet archive

# The archive is built unsigned (this Mac has no development certificate or device, and doesn't need them). Unsigned
# binaries carry no entitlements, so export would sign the app without its App Group. So each bundle is signed ad hoc
# with its own entitlements first (innermost first); export then re-signs them for the App Store and keeps them.
echo "==> entitlements"
APPS="$ARCHIVE/Products/Applications/Sona.app"
adhoc() {  # bundle, entitlements file
  local ents="$2"
  if grep -q "com.apple.developer.icloud-container-identifiers" "$ents"; then
    # iCloud builds for the App Store need the production environment; Xcode adds it only when it signs itself.
    ents="$(mktemp)"; cp "$2" "$ents"
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$ents"
  fi
  codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$ents" "$1" 2>/dev/null
}
adhoc "$APPS/Watch/SonaWatch.app/PlugIns/SonaWatchWidgets.appex" Configuration/watchWidgets.entitlements
adhoc "$APPS/Watch/SonaWatch.app" Configuration/watchOS.entitlements
adhoc "$APPS/PlugIns/SonaWidgets.appex" Configuration/widgets.entitlements
adhoc "$APPS" Configuration/iOS.entitlements

echo "==> sign"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath "$EXPORT" -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID" -quiet
IPA="$EXPORT/Sona.ipa"
[[ -f "$IPA" ]] || { echo "no IPA at $IPA" >&2; exit 1; }

# What the signed IPA must carry, checked against what project.yml declares (xcodegen wrote it into
# Configuration/*.entitlements and the Info.plists). Without these, notes never reach iCloud, the widgets can't see
# the app's state, or App Review sees a background mode the review notes don't explain (App Review guideline 2.5.4).
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
unzip -q "$IPA" -d "$CHECK"
APPDIR="$CHECK/Payload/Sona.app"
FAILED=0

# Every entitlement project.yml declares for a bundle must be in its signature with exactly that value (the signature
# may hold more: the team and application identifiers). The App Group must be on every bundle. On the app, with
# iCloud on, the container environment must be Production (release.sh adds it when it signs; an App Store build
# without it can't reach the container).
entitlements_match() {  # bundle, entitlements file from project.yml, "production" if the iCloud environment is required
  local bundle="$1" source="$2" production="${3:-}" signed
  signed="$CHECK/$(basename "$bundle").entitlements.plist"
  if ! codesign -d --entitlements - --xml "$bundle" > "$signed" 2>/dev/null || [[ ! -s "$signed" ]]; then
    echo "!! $(basename "$bundle"): no entitlements in its signature" >&2
    FAILED=1
    return
  fi
  python3 -I - "$signed" "$source" "$(basename "$bundle")" "$production" <<'PY' || FAILED=1
import plistlib, sys
signed_path, source_path, name, production = sys.argv[1:5]
with open(signed_path, "rb") as f:
    signed = plistlib.load(f)
with open(source_path, "rb") as f:
    source = plistlib.load(f)
problems = []
for key, want in sorted(source.items()):
    if key not in signed:
        problems.append(f"missing {key}")
    elif signed[key] != want:
        problems.append(f"{key} is {signed[key]!r}, project.yml says {want!r}")
if "group.com.dinilb.sona" not in signed.get("com.apple.security.application-groups", []):
    problems.append("no App Group group.com.dinilb.sona")
if signed.get("get-task-allow") is True:
    problems.append("get-task-allow is true (a development signature)")
if production:
    env = signed.get("com.apple.developer.icloud-container-environment")
    if env != "Production" and env != ["Production"]:
        problems.append(f"com.apple.developer.icloud-container-environment is {env!r}, not Production")
for problem in problems:
    print(f"!! {name}: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

# The background modes each binary declares, exactly: a mode added later can't ship without its line in the review
# notes. No location mode, ever: places use When In Use only.
modes_are() {  # Info.plist, expected modes as a JSON list
  python3 -I - "$1" "$2" <<'PY' || FAILED=1
import json, plistlib, sys
path, expected = sys.argv[1], json.loads(sys.argv[2])
with open(path, "rb") as f:
    info = plistlib.load(f)
got = info.get("UIBackgroundModes", [])
if got != expected:
    print(f"!! {path.split('/Payload/')[-1]}: UIBackgroundModes is {got}, expected {expected}", file=sys.stderr)
    sys.exit(1)
PY
}

# The location purpose string must be there (no prompt and ITMS-90683 without it), and never the Always one.
location_strings_ok() {  # Info.plist
  python3 -I - "$1" <<'PY' || FAILED=1
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
problems = []
if not info.get("NSLocationWhenInUseUsageDescription"):
    problems.append("no NSLocationWhenInUseUsageDescription")
if "NSLocationAlwaysAndWhenInUseUsageDescription" in info:
    problems.append("asks for Always location (NSLocationAlwaysAndWhenInUseUsageDescription)")
for problem in problems:
    print(f"!! Sona.app Info.plist: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY
}

ICLOUD=""
if grep -q "icloud-container-identifiers" Configuration/iOS.entitlements; then ICLOUD=production; fi
entitlements_match "$APPDIR" Configuration/iOS.entitlements "$ICLOUD"
entitlements_match "$APPDIR/PlugIns/SonaWidgets.appex" Configuration/widgets.entitlements
entitlements_match "$APPDIR/Watch/SonaWatch.app" Configuration/watchOS.entitlements
entitlements_match "$APPDIR/Watch/SonaWatch.app/PlugIns/SonaWatchWidgets.appex" Configuration/watchWidgets.entitlements
modes_are "$APPDIR/Info.plist" '["audio", "processing"]'
modes_are "$APPDIR/Watch/SonaWatch.app/Info.plist" '["audio"]'
location_strings_ok "$APPDIR/Info.plist"
if [[ "$FAILED" != 0 ]]; then
  echo "The signed IPA doesn't match project.yml (above). Not uploading." >&2
  exit 1
fi
echo "    signed; entitlements, background modes and the location string match project.yml"

if [[ "${EXPORT_ONLY:-0}" == 1 ]]; then echo "EXPORT_ONLY: not uploading ($IPA)"; exit 0; fi

echo "==> upload, wait for processing, give to Personal Testing"
"$ASC" publish testflight --app "$APP_ID" --ipa "$IPA" --group "$GROUP" --wait --notify \
  --test-notes "$NOTES" --locale en-AU --timeout 60m --output table
echo "==> build $BUILD is on TestFlight"
