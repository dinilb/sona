#!/bin/zsh
# Drives sona-mcp over stdio with real JSON-RPC: initialize, tools/list, search, recent, list, and the tools that read
# audio not yet in a note (current_conversation, transcript, live past 10 minutes).
# usage: scripts/mcp-smoke.sh [search words]   (uses $SONA_HOME if set)
#   CLIP=test-audio/two-voices.wav SONA_HOME=$PWD/test-home scripts/mcp-smoke.sh pricing
#   CLIP puts a 16 kHz mono WAV in the test home's spool as a conversation still being recorded, so those tools have
#   something to transcribe (it needs the models in the test home), and takes it out again after.
set -euo pipefail
cd "${0:A:h}/.."
Q=${1:-budget}
if [[ -n "${CLIP:-}" ]]; then
  [[ -n "${SONA_HOME:-}" ]] || { echo "CLIP needs SONA_HOME set to a test folder (never the real spool)" >&2; exit 2; }
  ID=$(date +%Y%m%d-%H%M%S)-SMKE
  SECS=$(( ($(stat -f %z "$CLIP") - 44) / 32000 ))
  mkdir -p "$SONA_HOME/Spool"
  cp "$CLIP" "$SONA_HOME/Spool/$ID.wav"
  print -r -- "{\"id\":\"$ID\",\"startedAt\":\"$(date -u -v-${SECS}S +%Y-%m-%dT%H:%M:%SZ)\",\"speechEnd\":0,\"speechSeconds\":0,\"closed\":false,\"attempts\":0}" \
    > "$SONA_HOME/Spool/$ID.json"
  trap 'rm -f "$SONA_HOME/Spool/$ID.wav" "$SONA_HOME/Spool/$ID.json"' EXIT
fi
FROM=$(date -v-2H '+%Y-%m-%d %H:%M')
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"search\",\"arguments\":{\"query\":\"$Q\",\"limit\":3}}}"
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"recent","arguments":{"minutes":120}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_conversations","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"current_conversation","arguments":{}}}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"transcript\",\"arguments\":{\"from\":\"$FROM\"}}}"
  echo '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"live","arguments":{"minutes":30}}}'
} | build/sona-mcp
