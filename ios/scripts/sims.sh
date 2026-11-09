#!/bin/bash
# Makes Sona's own simulators (an iPhone and a paired watch) if they aren't there yet. Idempotent.
set -euo pipefail
PHONE="${1:-Sona iPhone}"; WATCH="${2:-Sona Watch}"
runtime() { xcrun simctl list runtimes -j | python3 -I -c "import json,sys;print([r['identifier'] for r in json.load(sys.stdin)['runtimes'] if r['platform']=='$1' and r['isAvailable']][-1])"; }
udid() { xcrun simctl list devices -j | python3 -I -c "import json,sys;print(next((d['udid'] for v in json.load(sys.stdin)['devices'].values() for d in v if d['name']=='$1' and d['isAvailable']),''))"; }
[[ -n "$(udid "$PHONE")" ]] || xcrun simctl create "$PHONE" "iPhone 18 Pro" "$(runtime iOS)" >/dev/null
[[ -n "$(udid "$WATCH")" ]] || xcrun simctl create "$WATCH" "Apple Watch Series 12 (46mm)" "$(runtime watchOS)" >/dev/null
P="$(udid "$PHONE")"; W="$(udid "$WATCH")"
if ! xcrun simctl list pairs | grep -q "$W"; then xcrun simctl pair "$W" "$P" >/dev/null; fi
echo "phone $P"; echo "watch $W"
