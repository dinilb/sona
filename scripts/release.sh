#!/bin/zsh
# Builds a signed, notarized DMG of the app: build/release/Sona-<version>.dmg, holding the app and an
# Applications link to drag it onto, with the app's icon on the volume.
#   ALLOW_DIRTY=1   release uncommitted changes anyway
# Needs your own Apple Developer account:
#   - a "Developer ID Application" certificate in the keychain (the first one is used; SIGN_IDENTITY picks another)
#   - an App Store Connect API key for notarization: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file),
#     set in the environment or in ~/.appstoreconnect/config.env (ASC_CONFIG points elsewhere), kept outside the repo
# Without them, `make` still builds an ad-hoc signed app. Then scripts/publish-mac.sh puts the DMG on GitHub Releases and
# adds it to the Sparkle appcast, so installed copies update themselves.
set -euo pipefail
cd "${0:A:h}/.."
STEP=setup
trap 'echo "release FAILED during: $STEP" >&2' ERR
step() { STEP="$1"; echo "==> $1"; }
die() { echo "release FAILED: $*" >&2; exit 1; }

step checks
if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git status --porcelain)" ]]; then die "uncommitted changes (commit, or ALLOW_DIRTY=1)"; fi
if git log --format='%an %ae %cn %ce %B' | grep -qiE "co-authored-by:.*(claude|anthropic|copilot|codex|openai|chatgpt|cursor|gemini)|noreply@anthropic\.com|generated with"; then die "AI tool attribution in git history (a tool Co-Authored-By or Generated with line)"; fi
CONFIG="${ASC_CONFIG:-$HOME/.appstoreconnect/config.env}"
if [[ -f "$CONFIG" ]]; then source "$CONFIG"; fi
[[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-}" ]] ||
  die "no App Store Connect API key for notarization: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file), in the environment or in $CONFIG. For a local build, use make"
NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
[[ -n "$IDENTITY" && "$IDENTITY" != "-" ]] ||
  die "no Developer ID Application certificate in the keychain (or set SIGN_IDENTITY to yours). For a local build, use make"
export SIGN_IDENTITY="$IDENTITY"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
BUILD=$(date -u +%Y%m%d%H%M)
echo "    Sona $VERSION ($BUILD)"

step build
scripts/build.sh >/dev/null

OUT=build/release
STAGE=$OUT/stage
APP=$STAGE/Sona.app
rm -rf "$OUT"
mkdir -p "$STAGE"
ditto build/Sona.app "$APP"

step "sign (Developer ID, hardened runtime)"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Inside out, as in scripts/build.sh: Sparkle's helper and updater app, the framework, then Sona's own code.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE_FW/Versions/B/Autoupdate"
sign "$SPARKLE_FW/Versions/B/Updater.app"
sign "$SPARKLE_FW"
sign --identifier com.dinilb.sona.mcp "$APP/Contents/MacOS/sona-mcp"
# The CLI is signed on its own only if it's its own binary (a link to the app's binary is covered by the app).
CLI=$APP/Contents/Helpers/sona
if [[ -f "$CLI" && ! -L "$CLI" ]]; then sign --identifier com.dinilb.sona.cli "$CLI"; fi
sign --entitlements Resources/Sona.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# Submits and waits; on anything but Accepted, prints Apple's log for that submission, then fails.
notarize() {
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 60m --output-format json >"$OUT/notary.json" || true
  # (not `status`: in zsh that's a read-only special variable)
  local id verdict
  id=$(plutil -extract id raw -o - "$OUT/notary.json" 2>/dev/null || true)
  verdict=$(plutil -extract status raw -o - "$OUT/notary.json" 2>/dev/null || true)
  echo "    ${1:t}: ${verdict:-no status} (submission ${id:-none})"
  if [[ "$verdict" != "Accepted" ]]; then
    cat "$OUT/notary.json" >&2 || true
    if [[ -n "$id" ]]; then xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true; fi
    die "notarization not accepted (${1:t})"
  fi
}

step "notarize the app (usually a few minutes)"
ditto -c -k --keepParent "$APP" "$OUT/app.zip"
notarize "$OUT/app.zip"
xcrun stapler staple "$APP"
rm -f "$OUT/app.zip"

step dmg
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
DMG="$OUT/Sona-$VERSION.dmg"
# The volume icon needs the custom-icon flag on the volume's root, which only a writable image takes: so a
# read-write image, attached out of sight (-nobrowse) to set it, then compressed.
MOUNT=$(mktemp -d)
hdiutil create -quiet -volname "Sona $VERSION" -srcfolder "$STAGE" -ov -format UDRW "$OUT/rw.dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$OUT/rw.dmg"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT"
hdiutil detach -quiet "$MOUNT"
rmdir "$MOUNT"
hdiutil convert -quiet "$OUT/rw.dmg" -format UDZO -o "$DMG"
rm -f "$OUT/rw.dmg"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

step verify
spctl -a -vv -t exec "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || die "Gatekeeper doesn't accept the app"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | grep -q "source=Notarized Developer ID" || die "Gatekeeper doesn't accept the DMG"
# LaunchServices picks up the staged app along the way: forget it before it's deleted, so "Sona" never
# resolves to a copy that's gone.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
rm -rf "$STAGE"
echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"
