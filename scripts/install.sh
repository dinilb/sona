#!/bin/zsh
# make install: builds the app, swaps the installed copy for it and starts it again.
#   1. build (scripts/build.sh), copy it next to the installed app with ditto, check the copy's signature
#   2. stop the running Sona with SIGTERM: it saves the open conversation (transcribed on the next launch)
#      and gives the fn key back.
#   3. replace /Applications/Sona.app with the copy
#   4. LaunchServices forgets every other copy it knows (build/, worktrees, release staging, the Trash), so
#      Spotlight and `open` only find the installed one
#   5. start the installed app in the background (open -g)
#   6. print the line that connects Claude Code (no AI app's settings are changed)
# Trying it without touching the real app:
#   INSTALL_DIR=<dir>      install into <dir> instead of /Applications
#   SONA_HOME=<dir>        the support folder whose app.lock names the running copy (as for the app itself)
#   NO_LAUNCH=1            don't start it afterwards
#   DRY_RUN=1              build, then print each step's commands without running them
set -euo pipefail
cd "${0:A:h}/.."
STEP=setup
trap 'echo "install FAILED during: $STEP" >&2' ERR
step() { STEP="$1"; echo "==> $1"; }
die() { echo "install FAILED: $*" >&2; exit 1; }
# Prints a command that changes something, then runs it (unless DRY_RUN).
run() { print -r -- "    \$ ${(j: :)${(q-)@}}"; [[ -n "${DRY_RUN:-}" ]] || "$@"; }

DIR=${${INSTALL_DIR:-/Applications}:A}
DEST="$DIR/Sona.app"
LOCK="${SONA_HOME:-$HOME/Library/Application Support/Sona}/app.lock"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
STAGE="$DIR/.Sona-install-$$"
[[ -d "$DIR" && -w "$DIR" ]] || die "can't write to $DIR"

step build
scripts/build.sh

step "copy and check the signature"
trap '[[ -n "${DRY_RUN:-}" ]] || rm -rf "$STAGE"' EXIT
run ditto build/Sona.app "$STAGE/Sona.app"
run codesign --verify --deep --strict "$STAGE/Sona.app"
SIGNER=$(codesign -dv --verbose=2 build/Sona.app 2>&1 | sed -n 's/^Authority=//p' | head -1)
echo "    signed by: ${SIGNER:-nobody (ad hoc), so macOS asks for the microphone and Accessibility again}"

step "stop the running copy"
# The running app holds app.lock and wrote its pid in it; anything running from the install paths counts too.
lockpid=$(head -1 "$LOCK" 2>/dev/null | tr -cd 0-9 || true)
pids=()
for pid in ${=lockpid} $(pgrep -x Sona || true); do
  exe=$(ps -o comm= -p $pid 2>/dev/null || true)
  [[ -n "$exe" ]] || continue
  exe=${exe:A}
  if [[ "$exe" == "$DEST/Contents/MacOS/Sona" ]] ||
    [[ "$pid" == "$lockpid" && "$exe" == */Contents/MacOS/Sona ]]; then
    pids+=($pid)
  fi
done
pids=(${(u)pids})
(( ${#pids} )) || echo "    not running"
for pid in $pids; do
  echo "    pid $pid: $(ps -o comm= -p $pid)"
  run kill -TERM $pid
done
if [[ -z "${DRY_RUN:-}" ]]; then
  for pid in $pids; do
    for _ in {1..75}; do kill -0 $pid 2>/dev/null || break; sleep 0.2; done
    if kill -0 $pid 2>/dev/null; then die "pid $pid didn't quit within 15 s: quit Sona from its menu, then run make install again"; fi
    echo "    pid $pid quit"
  done
fi

step "replace $DEST"
# The old copy is set aside first (removed with the staging folder on exit), so a failed swap puts it back
# instead of leaving no app at all.
if [[ -e "$DEST" ]]; then run mv "$DEST" "$STAGE/old.app"; fi
if ! run mv "$STAGE/Sona.app" "$DEST"; then
  [[ -e "$STAGE/old.app" ]] && mv "$STAGE/old.app" "$DEST"
  die "couldn't move the new copy into place; the old one is back"
fi
run codesign --verify --deep --strict "$DEST"

step "LaunchServices: only the installed copy"
registered=$($LSREGISTER -dump 2>/dev/null | sed -n 's/^path: *\(.*\/Sona\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u || true)
for p in ${(f)registered}; do
  if [[ "$p" == "$DEST" || "$p" == /Applications/Sona.app ]]; then continue; fi
  run $LSREGISTER -u "$p" || echo "    (couldn't unregister it)"
done

step "start it"
if [[ -n "${NO_LAUNCH:-}" ]]; then echo "    skipped (NO_LAUNCH)"; else run open -g "$DEST"; fi

MCP="$DEST/Contents/MacOS/sona-mcp"
echo "==> done: $DEST"
echo
echo "To let Claude Code read your notes (once; other AI apps: README, Connect your AI):"
print -r -- "  claude mcp add --scope user sona -- ${(q-)MCP}"
