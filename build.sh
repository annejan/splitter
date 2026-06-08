#!/bin/bash
# splitter build — assemble src/main.asm to splitter.prg with KickAssembler.
#
# Single standalone PRG for now (BASIC stub SYS 2064). When the demo grows
# to multiple parts we add Spindle/pefchain linking — see AGENTS.md.
set -eo pipefail

ROOT="$(dirname "$(readlink -f "$0")")"
KICKASS="$ROOT/kickass/KickAss.jar"

if [[ ! -f "$KICKASS" ]]; then
    echo "KickAssembler jar missing at $KICKASS" >&2
    exit 1
fi

java -jar "$KICKASS" "$ROOT/src/main.asm" -o "$ROOT/splitter.prg" -symbolfile
echo ">>> built splitter.prg"
ls -la "$ROOT/splitter.prg"
