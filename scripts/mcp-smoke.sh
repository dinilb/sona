#!/bin/zsh
# Drives sona-mcp over stdio with real JSON-RPC: initialize, tools/list, search, recent, read, rename.
# usage: scripts/mcp-smoke.sh [search words]   (uses $SONA_HOME if set)
set -euo pipefail
cd "${0:A:h}/.."
Q=${1:-budget}
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"search\",\"arguments\":{\"query\":\"$Q\",\"limit\":3}}}"
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"recent","arguments":{"minutes":120}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_conversations","arguments":{}}}'
} | build/sona-mcp
