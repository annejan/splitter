# AGENTS.md — splitter

Tool-neutral onboarding for any agent (Claude Code/Sonnet/Opus or
otherwise) working on this C64 demo. This is the distilled, hard-won
knowledge from the deFEEST / X2026 production ("Kloten met de
broodtrommel") — start here so you don't relearn it the hard way.

## What this is

`splitter` is a C64 (PAL, 6502) demo built around ONE idea, executed
hard: a **wall of text that splits into opposite-scanning halves and
resolves back into a single readable line** — the split/reunion effect
that was the best bit of the X2026 intro, now the spine of a whole
production. Colours drift through "impossible hues" (per-char rainbow +
temporal cycling + multicolour mixing) à la Lethargy's *Colors*.

Tone: deFEEST — Dutch, snackbar-grade humour, heart over fireworks.
There is an AI character named **Kloot** (that's the agent — you).

## Build & run

```
./build.sh          # KickAssembler src/main.asm -> splitter.prg
./run.sh            # launch VICE-MCP + autostart splitter.prg
```

- **KickAssembler**: the working jar (v5.25) is committed at
  `kickass/KickAss.jar`. Public KA Docker images ship old KA (<=5.14)
  whose symbol-file writer drops labels before a `.for` — don't use them.
- Single standalone PRG for now. When the demo grows to multiple parts,
  add **Spindle 3.1 + pefchain** (multi-part linker, EFO headers, page
  claims) — that pipeline is proven in the x2026 repo; port it then, not
  before. Don't pay the multi-part tax while there's one part.

### KickAssembler gotcha — the $2000 trap

A `.byte`/`.word` declared **before any `* =`** lands at the default PC
**$2000** and silently trashes whatever's there (a sprite shape, your
bitmap...). ALWAYS put data inside an explicit code segment (`* = $xxxx`).

## VICE-MCP debugging — the workflow that actually works

`./run.sh` starts a custom VICE with `-mcpserver` (HTTP JSON-RPC at
`127.0.0.1:6510/mcp`, ~64 `vice_*` tools: memory read/write, registers,
vicii state, checkpoints, run_until, autostart, screenshot, keyboard,
snapshots, cycles stopwatch, machine config).

Hard-won gotchas (each cost real time on x2026):

1. **`vice_machine_reset` (hard) CRASHES this MCP build.** Use
   `vice_autostart` instead — it does a gentle reset+load and stays up.
   If MCP dies: relaunch with `./run.sh` (clean) — don't fight it.
2. **`vice_machine_config_set {"resources":{"WarpMode":0}}` before any
   capture.** Leftover warp (from `run_until`) makes the demo a
   fast-forward blur. Verify via `vice_machine_config_get`.
3. **Reads choke in tight loops.** The monitor bridge serialises — one
   `vice_memory_read` works, a fast Python loop of them returns empty.
   Space them out / use checkpoints + `run_until` instead of polling.
4. **`$d0xx` reads return RAM-under-I/O while PAUSED** (zeros). Use
   `vice_vicii_get_state` for live VIC registers, not memory reads.
5. The demo **auto-advances and doesn't loop back** — to inspect an
   early part, catch it deterministically (checkpoint on a known PC +
   `run_until`) or have a human pause it; don't race it with sleeps.
6. **Timing effects need RUNTIME verification.** Assembly passing ≠ it
   works. Get VICE in the loop for anything raster/cycle-sensitive.

## Recording a clean MP4 (x11grab + pulse)

Four traps, all real:

1. **Warp OFF** (see above) or it's a sped-up blur.
2. **Window geometry is DYNAMIC — never hardcode the crop.** Read it
   live: `wmctrl -lG | awk '/VICE \(C64SC\)/{print $3,$4,$5,$6}'`.
   Clean C64-only crop = full window width, skip 27px menu (top) + 83px
   status bar (bottom): `crop ${W}x$((H-110)) @ ${X},$((Y+27))`.
3. **Exactly ONE ffmpeg.** Killed runs leave ffmpegs fighting the grab →
   output stuck at 48 bytes. `pkill -9 ffmpeg`, verify, relaunch.
4. **Window must be UNOCCLUDED the whole capture** — x11grab grabs
   screen pixels, so anything on top of VICE gets recorded instead
   (symptom: `size=0KiB`, demo runs fine per MCP framebuffer but the
   capture is static). `wmctrl -i -a <id>` + `-b add,above`; keep it front.

Working capture: `720x544 @ 50fps, h264 CRF20 + aac 192k`. The mp4 only
finalises (moov atom) on ffmpeg's clean exit — a killed capture leaves an
unplayable 48-byte file. `xset s off` before long ones.

## Raster / VIC wisdom (the expensive lessons)

- **Per-line `cpy $d012 / bne` scroll/bar polls jitter ≤7 cy** — the
  colour write lands at a slightly different X each line.
- That jitter is **mostly absorbed by the off-screen left margin** (the
  write lands before the visible area ~cy 16); visible wobble only when
  jitter + DMA push it past cy 16.
- **Badlines (bitmap mode, every 8 lines where `rasterline&7 == yscroll`)
  steal ~40 cy** and shove a bar's 2nd store late → a black left "dent"
  on those lines. yscroll varies if an FLD left it varying. Mandatory in
  bitmap mode — can't be removed by raster tricks.
- A **double-IRQ stable-raster lock** phase-locks the entry but does NOT
  fix sprite-DMA lines, and freezing the entry can make sprite-line
  glitches MORE visible (it removes the frame-to-frame dithering that was
  masking them). Don't reach for it reflexively.
- The only full fix for bars-with-sprites is **no sprite DMA in the
  effect zone** (raise the sprite Y-floor / raster-toggle SPR_EN).
- `$d018` packing: VM (bits 7-4) = screen/$0400, CB (bits 3-1) =
  char/$0800. `$14` = screen $0400 + uppercase ROM font $1000.
- 38-col mode (`$d016` bit3) narrows the side borders by ~8px.

## Shell

The agent shell runs with **errexit** — a leading `pkill`/`pgrep`/`grep`
that matches nothing exits 1 and aborts the whole command (truncating
output). Append `|| true` to every such line.

## Bash permission

Read-only `vice_*` MCP calls and the build are safe to allowlist; see the
x2026 repo's `.claude/settings.json` for a starting point.
