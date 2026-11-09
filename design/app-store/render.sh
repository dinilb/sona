#!/bin/bash
# Renders every App Store and social image from screens.html and the real captures in captures/, at the exact
# pixel sizes App Store Connect and GitHub want, then strips the alpha channel. Run from anywhere:
#   design/app-store/render.sh
# Headless Chrome runs with a fresh, throwaway profile, so it never touches the Chrome you're signed in to.
set -euo pipefail
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PAGE="$PWD/design/app-store/screens.html"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT

shoot() {  # id width height out
  "$CHROME" --headless=new --user-data-dir="$PROFILE" --no-first-run --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=1 --window-size="$2,$3" --screenshot="$PWD/$4" "file://$PAGE#$1" >"$PROFILE/chrome.log" 2>&1 || { tail -20 "$PROFILE/chrome.log" >&2; exit 1; }
  echo "$4"
}

for n in 1 2 3 4 5 6; do
  shoot "iphone-$n" 1320 2868 "design/app-store/iphone-6.9-0$n.png"
done
shoot header 3840 1646 design/app-store/header-3840x1646.png
shoot social 1280 640 design/social/social-preview.png

# The watch set is the real screens as they are (422 x 514, Apple Watch Ultra 3 and 4), without alpha.
cp design/app-store/captures/watch-record.png design/app-store/apple-watch-01.png
cp design/app-store/captures/watch-recording.png design/app-store/apple-watch-02.png

swift design/app-store/flatten.swift design/app-store/iphone-6.9-0?.png design/app-store/header-3840x1646.png \
  design/app-store/apple-watch-0?.png design/social/social-preview.png
sips -g pixelWidth -g pixelHeight -g hasAlpha design/app-store/*.png design/social/*.png | paste - - - - \
  | awk '{ print $1, $3 "x" $5, "alpha " $7 }'
