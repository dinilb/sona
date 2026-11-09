#!/bin/zsh
# Publishes the DMG that `make release` made: a GitHub release (tag mac-<version>) holding the DMG, and a new item at
# the top of the Sparkle appcast (site/appcast.xml), signed with the update key in this Mac's keychain (made with
# Sparkle's generate_keys, account "sona"). Installed copies of Sona find it on their next update check.
#   NOTES="what changed"   release notes (default: the last commit's subject)
# Needs gh signed in, Sparkle's command-line tools (SPARKLE_BIN, default ~/.sparkle/bin: the bin/ folder of the
# Sparkle release that Package.swift pins) and a clean tree. The site is pushed to the gh-pages branch, which is what
# GitHub Pages serves.
set -euo pipefail
cd "${0:A:h}/.."
die() { echo "publish FAILED: $*" >&2; exit 1; }

SPARKLE_BIN=${SPARKLE_BIN:-$HOME/.sparkle/bin}
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "no sign_update in $SPARKLE_BIN (download Sparkle's release and set SPARKLE_BIN to its bin/)"
APP=build/release/stage/Sona.app
[[ -d "$APP" ]] || die "no $APP: run make release first"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
DMG=build/release/Sona-$VERSION.dmg
[[ -f "$DMG" ]] || die "no $DMG: run make release first"
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || die "Gatekeeper doesn't accept $DMG"
[[ -z "$(git status --porcelain)" ]] || die "uncommitted changes"
TAG=mac-$VERSION
NOTES=${NOTES:-$(git log -1 --format=%s)}
URL="https://github.com/dinilb/sona/releases/download/$TAG/Sona-$VERSION.dmg"

# After stapling (which changes the file), so the signature covers what people download.
SIG=$("$SPARKLE_BIN/sign_update" --account sona "$DMG")  # sparkle:edSignature="..." length="..."
[[ "$SIG" == *edSignature* ]] || die "sign_update gave no signature"

echo "==> GitHub release $TAG"
gh release create "$TAG" "$DMG" --repo dinilb/sona --target main --title "Sona for Mac $VERSION" --notes "$NOTES"

echo "==> appcast"
python3 -I - "$VERSION" "$BUILD" "$URL" "$SIG" "$TAG" <<'PY'
import sys, html, email.utils
version, build, url, sig, tag = sys.argv[1:6]
path = "site/appcast.xml"
t = open(path).read()
item = f"""    <item>
      <title>Sona {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/dinilb/sona/releases/tag/{html.escape(tag)}</sparkle:releaseNotesLink>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {sig}/>
    </item>
"""
anchor = "    <language>en</language>\n"
if anchor not in t:
    sys.exit("appcast: no <language> line to add the item after")
open(path, "w").write(t.replace(anchor, anchor + item, 1))
PY
plutil -lint site/appcast.xml >/dev/null 2>&1 || xmllint --noout site/appcast.xml
git add site/appcast.xml
git commit -q -m "Appcast: Sona for Mac $VERSION"
git push -q origin main

echo "==> site (gh-pages)"
PAGES=$(mktemp -d)
git clone -q --depth 1 --branch gh-pages https://github.com/dinilb/sona.git "$PAGES"
rsync -a --delete --exclude .git site/ "$PAGES/"
git -C "$PAGES" add -A
git -C "$PAGES" diff --cached --quiet || git -C "$PAGES" commit -q -m "Site from main's site/ folder ($(git rev-parse --short HEAD))"
git -C "$PAGES" push -q origin gh-pages
rm -rf "$PAGES"
echo "==> done: $TAG on GitHub, appcast item $VERSION ($BUILD)"
