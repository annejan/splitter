#!/bin/bash
# Launch the custom VICE-MCP build and autostart splitter.prg.
#
# Starts x64sc with -mcpserver (HTTP JSON-RPC on 127.0.0.1:6510/mcp) so an
# agent can drive/inspect it. Override the binary with VICE_MCP_BIN.
# See AGENTS.md for the MCP debugging workflow + gotchas.
set -e
cd "$(dirname "$0")"

PRG="$(pwd)/splitter.prg"
[[ -f "$PRG" ]] || { echo "splitter.prg not found — run ./build.sh first."; exit 1; }

pkill -9 -f x64sc 2>/dev/null || true
sleep 1

VICE_BIN="${VICE_MCP_BIN:-/home/annejan/Projects/vice-mcp/vice/build-test-with-mcp/src/x64sc}"
if [[ ! -x "$VICE_BIN" ]]; then
    VICE_BIN="$(command -v x64sc 2>/dev/null || echo /usr/bin/x64sc)"
    echo "Warning: vice-mcp build not found at \$VICE_MCP_BIN. Using $VICE_BIN." >&2
fi

"$VICE_BIN" -mcpserver "$PRG" > /tmp/vice.log 2>&1 &
disown
sleep 4
if ss -tln 2>/dev/null | grep -q 6510; then
    echo "VICE-MCP up on 127.0.0.1:6510/mcp — splitter.prg autostarted."
else
    echo "VICE-MCP did not open port 6510. See /tmp/vice.log"
    echo "(NB: hard 'vice_machine_reset' can crash this build — prefer vice_autostart.)"
fi
