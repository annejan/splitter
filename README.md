# splitter

A Commodore 64 (PAL) demo by **deFEEST**, built around one idea pushed
hard: a **wall of text that splits into two opposite-scanning halves and
resolves back into a single readable line** — the split / reunion.

This is the follow-up to *Kloten met de broodtrommel* (X'2026). That one
proved the toolchain and the spirit; this one picks the single nicest
effect from its intro and makes it the whole show — in the "one concept,
executed perfectly" lane, with drifting *impossible hues* for colour.

```
./build.sh      # -> splitter.prg     (KickAssembler)
./run.sh        # launch VICE-MCP + autostart
```

Or load it on a real breadbin: `LOAD "SPLITTER",8,1` then `RUN`.

## Status

`v0.1` — the seed: two char-mode rows scan the same message in opposite
directions and meet as one line, in a per-frame rainbow. Coarse for now;
the smooth `$d016` scroll, the raster colour-splits, graphics and the
multi-part structure come next. See [`AGENTS.md`](./AGENTS.md) for the
build pipeline, the VICE-MCP debugging workflow, and every hard-won
gotcha carried over from X'2026.

## Roadmap (loose)

- [ ] Smooth `$d016` sub-pixel scroll on each half (independent via raster split)
- [ ] The zig-zag interleave (even/odd pixel-rows opposite directions) — the real x2026 trick
- [ ] Tune the meet so a punchline lands on the reunion + a beat-synced freeze
- [ ] "Impossible hues": multicolour + raster colour-cycling as a deliberate colour statement
- [ ] Graphics layer (logo / koala) behind the wall
- [ ] Music (custom SID) + sync
- [ ] Spindle/pefchain when it becomes multi-part

> see you at Evoke
