//==================================================================
// splitter — v0.37  "static lines now 1px-SMOOTH in/out (per-row sub-pixel $d016)"
//
// The splits are back — and over the WHOLE screen, cheaply. A stable
// per-scanline $d016 loop shears every visible line: even lines xscroll
// +A, odd lines -A, with A breathing each frame -> a fine per-pixel-row
// zig-zag across all 200 lines (no bitmap shifting). Underneath, the
// char-mode scene-poetry slides in/out (per line different) and resolves
// readable. Music "Dingen" by Cinder/deFEEST.
//
// Structure (the demoscene shape): IRQ fires in the lower border; the
// per-frame work (music, choreography, screen render, shear table) runs
// in the off-screen time — bracketed by $d020 inc/dec as the budget
// ruler — then the $d016 loop runs through the visible area. $d016
// mid-line is VSP-safe; the cmp $d012 poll re-syncs each line so badlines
// /DMA don't drift it.
//==================================================================
.cpu _6502
.encoding "screencode_upper"

.var music = LoadSid("../music/kleuter-dinges.sid")

.var rowList   = List().add(2, 3, 4, 7, 8, 9, 12, 13, 14, 18)   // paragraphs w/ blank rows
.var colList   = List().add($0e, $03, $0d, $07, $01, $0f, $0a, $05, $0c, $06)
.var startList = List().add(0, 80, 0, 80, 0, 80, 0, 80, 0, 80)
.var speedList = List().add(2, 3, 1, 2, 3, 1, 2, 3, 2, 1)

// Each banner rolls a LIST of lines (<=40 chars, padded to 40). On every meet
// the next line scrolls in -> a real story / greetings roll. Banner 1 (bottom)
// tells the demo's story; banner 2 (top) does the greetings.
.const MSGLEN  = 40
.const MSGLEN2 = 40
.var lines1 = List()
.eval lines1.add("  SPLITTER  -  A DEFEEST PRODUCTION")
.eval lines1.add("  TEXT TORN ON EVEN AND ODD LINES")
.eval lines1.add("  SCROLLING IN FROM LEFT AND RIGHT")
.eval lines1.add("  AND MEETING CLEAN IN THE MIDDLE")
.eval lines1.add("  ONE IDEA EXECUTED AT FIFTY HERTZ")
.eval lines1.add("  NO BITMAP - JUST A CHAR-MODE TRICK")
.eval lines1.add("  A RAM FONT CANVAS IS THE SCROLLER")
.eval lines1.add("  TWO SPLITS - ONE FAST - ONE SLOW")
.eval lines1.add("  RAINBOWS DRIFTING DIAGONALLY ...")
.eval lines1.add("  PROUDLY MADE AT THE SNACKBAR")
.var lines2 = List()
.eval lines2.add("  GREETINGS TO EVERYONE AT EVOKE !")
.eval lines2.add("  AND TO ALL C64 SCENERS OUT THERE")
.eval lines2.add("  DESIRE  BOOZE  CENSOR  GENESIS")
.eval lines2.add("  KLOOT WAS HERE - FRIET MET ALLES")
.eval lines2.add("  SEE YOU AT THE SNACKBAR - CINDER")
.eval lines2.add("  HELLO BREADBIN LOVERS WORLDWIDE")
.eval lines2.add("  GREETS TO THE WHOLE DUTCH SCENE")
.eval lines2.add("  CODERS GRAFICIANS AND MUSICIANS")
.eval lines2.add("  KEEP THE C64 ALIVE IN 2026 !")
.eval lines2.add("  RESPECT TO EVERYONE STILL HERE")
.const NL1 = lines1.size()
.const NL2 = lines2.size()

* = $0801
        .byte $0c, $08, $0a, $00, $9e, $32, $30, $36, $34, $00, $00, $00

* = $0810 "Main"

.const SCREEN   = $0400
.const COLOR    = $d800
.const LINEBUF  = $4000
.const NLINES   = 10
.const BUFW     = 120
.const CENTER   = 40

.const srcptr   = $fb
.const dstptr   = $fd
.const cptr     = $f9

.const SF_DONE  = $cffe

.const PH_IN    = 0
.const PH_HOLD  = 1
.const PH_OUT   = 2
.const T_IN     = 170             // frames for the static lines to slide IN
.const T_HOLD   = 250             // frames they sit readable
.const T_OUT    = 170             // frames to slide OUT
.const SLIDE_STEP = 4             // move sp 1 char every 4 frames (must be pow2);
                                  //   render the static rows only on those frames

.const TOP      = $42              // shear band over the poetry. Lowest SWIM row is now
.const BOT      = $c4              //   row13 (raster ~161), well inside; row18 is static
.const WORKLINE = $c8              //   (band edge + write-lag made it only half-animate,
                                   //   and covering it fully pushed WORKLINE into overrun).
.const D016BASE = $0c              // 38-col + xscroll 4 (shear centre)
.const MODE_TIME = 220             // frames per shear mode (0 zigzag/1 wave/2 row)
// --- Rubberband Swim (hero rows): a sine that travels through the 8
//     pixel-rows of each glyph and crawls upward every frame (woosh).
.const VSTEP    = $03              // phase step BETWEEN scanlines — SMALL so glyphs stay
                                   //   coherent. intra-glyph shear ~ AMP*(2pi/256)*VSTEP*8;
                                   //   $03,AMP=3 -> ~0.45px scuff inside a letter (crisp). $18 was
                                   //   ~3.6px = each glyph torn top-vs-bottom = the mush we saw.
.const ROWOFF   = $20              // phase offset between hero rows (they swim out of phase)
.const SWIMSPD  = 2                // master phase advance / frame = travel speed
// --- Beat (tunable tempo, since the SID isn't register-readable here):
.const BEAT_FRAMES = 24            // frames per beat — TUNE BY EAR to lock to the music
.const BEAT_KICK   = $18           // swim-phase lurch on each beat (wave pulse)
.const BEAT_HUE    = $02           // rainbow hue surge on each beat
// --- The Split (the demo's heart): a line breaks into two halves that
//     slide out the side borders and converge back to one readable line.
//     Left half = cols 0..19, right half = cols 20..39, both carrying the
//     SAME pre-split line; sep 20=apart/blank .. 0=met/readable.
.const R_STATIC = 0                // role: drawn once, no per-frame work
.const R_SWIM   = 1                // role: the $d016 sine swim (shear)
.const R_SPLIT  = 2                // role: the split/meet
.const SP_CLOSE = 0                // sub-phase: halves converging (20->0)
.const SP_HOLD  = 1                // sub-phase: met, readable, held
.const SP_OPEN  = 2                // sub-phase: halves diverging (0->20)
.const SP_GAP   = 3                // sub-phase: apart, blank pause
.const SPLIT_STEP  = 3             // frames per 1-col sep step (20 steps ~ 1.2s)
.const SPLIT_HOLD  = 110           // readable hold at the meet (~2.2s)
.const SPLIT_GAP   = 40            // blank pause when fully apart
.const SPLIT_FLASH = 6             // white colour-RAM flash frames on the meet

// --- The venetian split-scroll BANNER (the kloten-intro effect, freshened):
//     even pixel-rows ROL forward, odd pixel-rows ROR backward, fed from one
//     message; the two halves cross and lock into readable text. We run it in
//     CHAR mode via a RAM-font canvas (banner cells point at scratch chars so
//     ROL/ROR over the charset bytes IS the per-pixel-row scroll) + a rainbow
//     colour drift over the row + a white flash on the meet. Fresh, not a copy.
.const FONT_RAM   = $3000          // RAM copy of the ROM uppercase font
.const D018_RAM   = $1c            // screen $0400 + font $3000
.const C1CODE     = 64             // banner 1 uses canvas char codes 64..103
.const CANVAS1    = FONT_RAM + C1CODE*8   // $3200 — the 40-char scratch canvas
.const BANNER1ROW = 16             // a free row (not in rowList) for the banner
.const C2CODE     = 104            // banner 2 uses canvas char codes 104..143
.const CANVAS2    = FONT_RAM + C2CODE*8   // $3340 — banner 2's scratch canvas
.const BANNER2ROW = 1              // top row (above the poem, outside the band)
.const BPAUSE2    = 70             // TOP banner: short hold -> fast, keeps scrolling
.const SMAX       = 40             // FULL line width: the halves slide the whole 40 cols
                                   //   (fully off + back) so the sweep covers the entire
                                   //   line — not a fixed shorter reach that left part of
                                   //   the row half-done. 40*2 ~ 1.6s each way.
.const BSTEP2     = 1              // step every frame -> with the even/odd split that
                                   //   lands a char-step every 2 frames (25Hz motion)
                                   //   while each frame stays <=3.8k cy -> 50Hz held
.const BPAUSE     = 360            // BOTTOM banner: long hold -> slow, sits readable
.const osrc       = $f9            // zp pair (= cptr) reused as odd-row source ptr
.const DEBUG    = 1                // 1 = colour-band raster profiler in the border
.const BARS     = 0                // 1 = flowing $d021 rasterbars (needs a stable raster
                                   //     to be speckle-free; off for now -> clean bg)
.const INTRO    = 0                // 1 = run DEFEEST screenfill bloom (WIP: hangs $c07d)

// dbg(c): paint $d020 = c, but ONLY when DEBUG — zero cost in the pretty build
.macro dbg(c) {
    .if (DEBUG != 0) {
        lda #c
        sta $d020
    }
}

start:
        sei
        lda #$35
        sta $01

        // Screenfill intro — DEFEEST radial bloom (toggle: WIP, currently
        // hangs at $c07d before setting SF_DONE -> bypass so we can see the
        // poem + effects. Flip INTRO=1 once the bloom hands off cleanly.)
        .if (INTRO != 0) {
            jsr copy_sf
            lda #$00
            sta SF_DONE
            jsr $c000
            cli
        !wait:  lda SF_DONE
            beq !wait-
            sei
            lda #$00
            sta $d01a
            lda #$ff
            sta $d019
        }
        // Clear screen from DEFEEST pattern before splitter draws
        ldx #0
        lda #$20
!clr:   sta $0400,x
        sta $0500,x
        sta $0600,x
        sta $06e8,x
        inx
        bne !clr-

        lda #D018_RAM              // screen $0400 + RAM font $3000 (for canvas)
        sta $d018
        lda #$1b
        sta $d011
        lda #D016BASE
        sta $d016
        lda #$00
        sta $d020
        sta $d021

        ldx #0
        lda #$20
!cl:    sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        inx
        bne !cl-

        ldx #0
!lc:    lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        lda line_color,x
        ldy #39
!cf:    sta (cptr),y
        dey
        bpl !cf-
        inx
        cpx #NLINES
        bne !lc-

        ldx #NLINES-1
!si:    lda role,x                 // swim rows sit readable at CENTER; static
        bne !sic+                  //   rows start PARKED off-screen (line_start)
        lda line_start,x           //   so they slide IN at startup.
        jmp !sis+
!sic:   lda #CENTER
!sis:   sta sp,x
        dex
        bpl !si-
        lda #PH_IN                 // kick off the oldskool slide-in
        sta phase
        lda #T_IN
        sta phase_timer
        jsr render                 // draw the whole poem ONCE
        // split lines start apart (sep=20 -> blank); draw them so they don't
        // flash their full text for a frame before the state machine kicks in
        ldx #NLINES-1
!sb:    stx linecnt
        lda role,x
        cmp #R_SPLIT
        bne !sbn+
        jsr render_split_x
        ldx linecnt
!sbn:   dex
        bpl !sb-
        jsr init_banner            // font copy + canvas + scroll seed
        lda #PH_IN
        sta phase
        lda #T_IN
        sta phase_timer

        lda #music.startSong-1
        jsr music.init

        lda #<irq_work
        sta $fffe
        lda #>irq_work
        sta $ffff
        lda #$7f
        sta $dc0d
        sta $dd0d
        lda $dc0d
        lda $dd0d
        lda #$01
        sta $d01a
        lda #WORKLINE              // first IRQ = work, below the band
        sta $d012
        lda $d011
        and #$7f
        sta $d011
        lda #$ff
        sta $d019
        cli
!loop:  jmp !loop-


//==================================================================
// raster IRQ — off-screen work, then the visible-area $d016 shear loop.
//==================================================================
//==================================================================
// irq_work — fires at BOT (lower border). ALL per-frame work happens
// here, out of the visible area, then hands the raster to irq_shear at
// the band top. The $d020 band shows the work's raster cost; keep it
// inside the border or the budget is blown.
//==================================================================
irq_work:
        pha
        txa
        pha
        tya
        pha
        lda #$ff
        sta $d019

        // ---- coloured debug bands: each $d020 colour = a routine, so the
        // ---- border graphs exactly where the raster time goes ----
        //   RED music | YELLOW phase | BLUE render | PURPLE shear | GREEN rainbow
        // Text is STATIC (drawn once) -> no per-frame render. Only the 3
        // hero rows animate (shear + rainbow), so build+color run every
        // frame and stay tiny. Coloured debug bands graph the cost.
        dbg($02)                   // RED = SID player
        jsr music.play
        // Beat: SID registers aren't readable in this setup, so drive a pulse
        // off a TUNABLE tempo (BEAT_FRAMES frames/beat — tune by ear to lock).
        dec beatctr
        bne !nobeat+
        lda #BEAT_FRAMES
        sta beatctr
        lda #BEAT_KICK             // a beat! lurch the swim wave forward
        clc
        adc swimphase
        sta swimphase
        lda #BEAT_HUE              // and surge the rainbow hue
        clc
        adc beathue
        sta beathue
!nobeat:
        inc frame
        lda #0                     // clear "a banner homed (heavy) this frame";
        sta b_did_render           //   the home blit below sets it so the slide
                                   //   render yields that one frame -> no overrun
        dbg($0a)                   // LT-RED = venetian banner (sets b_did_render)
        // Stream only ONE banner per frame (50Hz). WEIGHTED 2:1 so the TOP
        // banner (2) scrolls fast and the BOTTOM banner (1) scrolls slow:
        // top gets 2 of every 3 frames, bottom 1.
        inc b3ctr
        lda b3ctr
        cmp #3
        bcc !c3+
        lda #0
        sta b3ctr
!c3:    lda b3ctr
        cmp #2
        bcs !slow+
        jsr banner_scroll2         // TOP (fast) — 2 of 3 frames
        jmp !bcol+
!slow:  jsr banner_scroll          // BOTTOM (slow) — 1 of 3 frames
!bcol:  jsr banner_color           // banner 1 colour every frame
        lda phase                  // during the static-row slide we spend this
        cmp #PH_HOLD               //   frame's headroom on render_next_static
        bne !skipc2+               //   instead, so skip banner 2's recolour
        jsr banner_color2          //   (its rainbow just stops drifting briefly)
!skipc2:
        dbg($07)                   // YELLOW = phase machine + static-row slide
        jsr update_phase           //   (runs AFTER the banner so b_did_render is
                                   //   known -> skips its render on a home frame)
        dbg($04)                   // PURPLE = shear table (swim rows)
        jsr build_shear
        dbg($0e)                   // LT-BLUE = split state machine
        jsr split_update
        // Rainbow runs EVERY frame now — it's round-robin (half the swim rows
        // per frame, ~3k cy) so it fits even alongside the banner streaming,
        // giving a consistent diagonal drift instead of fast-then-frozen.
        dbg($05)                   // GREEN = rainbow drift
        jsr color_cycle
        .if (BARS != 0) {
            lda b_did_render
            bne !light_done+
            lda frame
            and #$01
            bne !light_done+
            inc barscroll
            dbg($06)
            jsr build_d021tab
        }
!light_done:
        dbg($00)                   // BLACK = idle

        lda #<irq_shear
        sta $fffe
        lda #>irq_shear
        sta $ffff
        lda #TOP
        sta $d012

        pla
        tay
        pla
        tax
        pla
        rti

//==================================================================
// irq_shear — fires at TOP (band top). Just the per-scanline $d016
// loop over the poetry band, nothing else. Hands back to irq_work.
//==================================================================
irq_shear:
        pha
        txa
        pha
        tya
        pha
        lda #$ff
        sta $d019

        ldy #TOP
        // Wait for the line FIRST, then write $d016/$d021 immediately on the
        // poll exit (cy ~4-11) — well before the ~cy14 fetch even with the
        // poll's <=7cy jitter. Doing the BOT check AFTER the writes (not
        // before) is what keeps the shear write early enough to stop the
        // swim-row left-column speckle.
!sl:    cpy $d012
        bne !sl-
        lda shear_tab,y
        sta $d016
        .if (BARS != 0) {
            lda d021tab,y
            sta $d021
        }
        iny
        cpy #BOT
        bne !sl-
        lda #D016BASE
        sta $d016
        lda #$00
        sta $d021                  // black background outside the band

        lda #<irq_work
        sta $fffe
        lda #>irq_work
        sta $ffff
        lda #WORKLINE
        sta $d012

        pla
        tay
        pla
        tax
        pla
        rti


//==================================================================
// build_shear — shear_tab[line] = base +A (even) / -A (odd). A breathes
// from a sine table; smaller during HOLD so the wall reads cleaner.
//==================================================================
build_shear:
        // Rubberband Swim: hero rows show a sine that travels through the
        // 8 pixel-rows of each glyph (per-scanline phase = +VSTEP) and the
        // whole wave crawls upward every frame (master phase += SWIMSPD).
        // Clean rows stay dead flat (0 wobble, readable).
        lda #NLINES-1
        sta linecnt
!bl:    ldx linecnt
        ldy line_scan,x            // Y = shear_tab base raster line for this row
        // Swim shear RETIRED: per-line $d016 + the cmp $d012 poll's <=7cy
        // jitter speckled the swim rows against the bars (no stable raster).
        // All rows now stay flat; those lines instead move via the rainbow
        // colour drift (color_cycle still targets R_SWIM rows). The !swim
        // code below is kept (dead) for an easy revert once a stable raster
        // lands. To re-enable: uncomment the two lines below.
        lda role,x                 // swim re-enabled now the bars are off: the swim
        bne !swim+                 //   speckle only showed against the bars; on the
                                   //   black bg it's clean (write-order + badline fix).
        lda sxval,x                // static row: its live sub-pixel xscroll (= the
                                   //   smooth in/out slide); D016BASE when at HOLD
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        iny
        sta shear_tab,y
        jmp !nx+
!swim:  // base phase for scanline 0 = swimphase + row*ROWOFF
        txa
        .for (var b = 0; b < 5; b++) { asl }   // row * $20 (ROWOFF)
        clc
        adc swimphase
        tax                        // X = phase, walks +VSTEP per scanline
        // NOTE scanline 1 deliberately repeats scanline 0's xscroll: on a swim
        // row that 2nd scanline is always a badline (line_scan&7==2 -> +1==3),
        // where the $d016 write lands late; making it equal its neighbour means
        // the late write changes nothing = no left-edge speckle.
        .for (var s = 0; s < 8; s++) {
            lda sin7,x
            sta shear_tab,y
            .if (s < 7) {
                iny
                .if (s != 0) {
                    txa
                    clc
                    adc #VSTEP
                    tax
                }
            }
        }
!nx:    dec linecnt
        bmi !done+
        jmp !bl-
!done:
        lda swimphase              // wave crawls upward (woosh) each frame
        clc
        adc #SWIMSPD
        sta swimphase
        rts

//==================================================================
// build_d021tab — precompute the rasterbar bg for the band: ONE colour per
// 8-line block (edges on the 8-line grid, off badlines), flowing via
// barscroll. irq_shear then just reads d021tab,y and writes it early. Only
// called on LIGHT frames (not a banner-render frame), so it never stacks
// with render_banner -> no overrun.
//==================================================================
build_d021tab:
        ldy #TOP
!bf:    tya
        lsr
        lsr
        lsr
        clc
        adc barscroll
        and #$07
        tax
        lda barpal8,x              // colour for this 8-line block
        sta tmp                    // hold it (the boundary check below clobbers A)
!bff:   lda tmp
        sta d021tab,y
        iny
        cpy #BOT
        beq !bfd+
        tya
        and #$07
        bne !bff-                  // still inside the block -> same colour
        jmp !bf-                   // block boundary -> recompute
!bfd:
        rts


//==================================================================
// color_cycle — per-char 16-colour rainbow drifting diagonally. The
// whole palette in motion (jonguh, demoscene). Unrolled per row; runs
// on the odd frame next to build_shear so it stays inside 50 Hz.
//==================================================================
color_cycle:
        // DIAGONAL rainbow: each swim row's hue ramp is offset by its row
        // index (row*3) so the colours flow diagonally across the wall (funky),
        // drifting SLOWLY (frame>>2). ROUND-ROBIN: only half the swim rows are
        // recoloured per frame ((row+frame)&1) so it's cheap enough to run
        // EVERY frame — also during the banner scroll — for a CONSISTENT
        // rainbow instead of fast-when-idle / frozen-when-scrolling.
        lda #NLINES-1
        sta linecnt
!cl:    ldx linecnt
        lda role,x
        cmp #R_SWIM
        bne !skip+
        lda linecnt                // round-robin ~1/4 swim rows per frame (cheaper,
        clc                        //   to leave room for the 2nd banner streaming)
        adc frame
        and #$03
        bne !skip+
        lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        lda frame                  // hue base = (frame>>2) + row*3 + beathue
        lsr
        lsr
        clc
        adc beathue                //   the beat surges the colours forward
        sta tmp
        lda linecnt
        asl
        clc
        adc linecnt
        clc
        adc tmp
        sta tmp
        ldy #39
!cc:    tya
        lsr                        // col>>1 (one hue / 2 chars)
        clc
        adc tmp
        and #$07
        tax
        lda rbsafe,x
        sta (cptr),y
        dey
        bpl !cc-
!skip:  dec linecnt
        bpl !cl-
        rts

// recolor_all — restore every line to its plain colour (called on a role
// rotation so a line that just lost hero status drops its leftover rainbow)
recolor_all:
        lda #NLINES-1
        sta linecnt
!rl:    ldx linecnt
        lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        lda line_color,x
        ldy #39
!rc:    sta (cptr),y
        dey
        bpl !rc-
        dec linecnt
        bpl !rl-
        rts


// update_phase — STATIC poem rows scroll oldskool in/out, SMOOTH (1px) and
// budget-safe. Each static row has its OWN sub-pixel phase fine = (gfine +
// soff[x]) & 7, written as a live $d016 xscroll (sxval[x]) onto every scanline
// of the row by build_shear -> 1px/frame hardware scroll. A row char-steps
// (slides its 120-char buffer window sp by 1 + re-render) only when ITS fine
// wraps to 0. The per-row stagger (distinct soff) spreads those wraps so at
// most ONE row re-renders per frame (~440cy) instead of all six at once (the
// 2.6k spike that blew the budget). slide_char 0->40 = IN (enters to CENTRE),
// HOLD, 40->80 = OUT (exits far side), re-park. Swim rows untouched; the shear
// LOOP is unchanged. soff/soff2row below are hand-tuned to the fixed role map.
update_phase:
        lda phase
        cmp #PH_HOLD
        bne !slide+
        // HOLD: settle any rows left 1 char short (spread render over 6 frames)
        lda hold_settle
        beq !hc+
        dec hold_settle
        jsr render_hold_row
!hc:    dec phase_timer
        bne !ret+
        lda #PH_OUT
        sta phase
!ret:   rts
!slide:
        lda b_did_render           // heavy banner-home frame -> freeze 1 frame
        bne !ret2+                 //   (sub-pixel pauses, invisible) -> no overrun
        inc gfine
        lda gfine
        and #7
        sta gfine
        jsr slide_step
        jsr update_sxval
!ret2:  rts

// slide_step — char-step + render the ONE static row whose fine just hit 0
// (soff == (8-gfine)&7). When the reference row (soff 0, gfine==0) steps, bump
// slide_char and check for IN->HOLD (centre) / OUT->re-park (exited far side).
slide_step:
        lda #8
        sec
        sbc gfine
        and #7
        cmp #6
        bcs !none+                 // soff 6/7 -> no row wraps this frame
        tay
        ldx soff2row,y             // X = row index to char-step + render
        clc
        lda sp,x
        adc sdir,x                 // sdir = +1 (text left) or $ff/-1 (text right)
        sta sp,x
        lda src_lo,x
        clc
        adc sp,x
        sta srcptr
        lda src_hi,x
        adc #0
        sta srcptr+1
        lda dst_lo,x
        sta dstptr
        lda dst_hi,x
        sta dstptr+1
        ldy #39
!cp:    lda (srcptr),y
        sta (dstptr),y
        dey
        bpl !cp-
        lda gfine                  // only the reference row (gfine==0) drives progress
        bne !none+
        inc slide_char
        lda phase
        cmp #PH_IN
        bne !out+
        lda slide_char
        cmp #CENTER
        bcc !none+
        jmp enter_hold
!out:   lda slide_char
        cmp #80
        bcc !none+
        jmp repark
!none:  rts

enter_hold:                        // IN done -> lock readable, align, settle
        lda #PH_HOLD
        sta phase
        lda #T_HOLD
        sta phase_timer
        lda #6
        sta hold_settle
        lda #0
        sta hold_idx
        sta gfine
        ldx #NLINES-1
!eh:    lda role,x
        bne !ehn+
        lda #CENTER
        sta sp,x
        lda #D016BASE
        sta sxval,x
!ehn:   dex
        bpl !eh-
        rts

repark:                            // OUT done -> park off-screen, slide IN again
        lda #PH_IN
        sta phase
        lda #0
        sta slide_char
        sta gfine
        ldx #NLINES-1
!rp:    lda role,x
        bne !rpn+
        lda line_start,x
        sta sp,x
!rpn:   dex
        bpl !rp-
        rts

// render_hold_row — at HOLD entry rows may sit 1 char short of CENTRE (stagger);
// render one static row per frame at CENTRE to settle them without a spike.
render_hold_row:
        ldx hold_idx
!adv:   inx
        cpx #NLINES
        bcc !w+
        ldx #0
!w:     lda role,x
        bne !adv-
        stx hold_idx
        lda src_lo,x
        clc
        adc sp,x
        sta srcptr
        lda src_hi,x
        adc #0
        sta srcptr+1
        lda dst_lo,x
        sta dstptr
        lda dst_hi,x
        sta dstptr+1
        ldy #39
!cp:    lda (srcptr),y
        sta (dstptr),y
        dey
        bpl !cp-
        rts

// update_sxval — each static row's live $d016 xscroll from its own fine =
// (gfine+soff)&7. $08 keeps 38-col so the scroll-wrap hides in the border.
update_sxval:
        ldx #NLINES-1
!u:     lda role,x
        bne !un+
        lda gfine
        clc
        adc soff,x
        and #7
        sta tmp                    // this row's fine
        lda sdir,x
        bmi !neg+
        lda #7                     // text left  -> xscroll = 7 - fine
        sec
        sbc tmp
        jmp !wr+
!neg:   lda tmp                    // text right -> xscroll = fine
!wr:    ora #$08
        sta sxval,x
!un:    dex
        bpl !u-
        rts



render:
        ldx #0
!rl:    lda src_lo,x
        clc
        adc sp,x
        sta srcptr
        lda src_hi,x
        adc #0
        sta srcptr+1
        lda dst_lo,x
        sta dstptr
        lda dst_hi,x
        sta dstptr+1
        ldy #39
!cp:    lda (srcptr),y
        sta (dstptr),y
        dey
        bpl !cp-
        inx
        cpx #NLINES
        bne !rl-
        rts


//==================================================================
// split_update — per frame, drive every R_SPLIT line's state machine.
// sep steps once every SPLIT_STEP frames; we only re-draw the row on a
// step (cheap). MEET (sep=0) snaps a white colour flash + holds readable.
//==================================================================
split_update:
        lda #NLINES-1
        sta linecnt
!su:    ldx linecnt
        lda role,x
        cmp #R_SPLIT
        beq !live+
        jmp !next+
!live:
        lda sflash,x               // white-flash decay after a meet
        beq !noflash+
        dec sflash,x
        bne !noflash+
        lda line_color,x           // flash ended -> restore the line's colour
        jsr fill_col_x
        ldx linecnt
!noflash:
        dec stmr,x
        beq !step+
        jmp !next+

!step:  lda ssub,x                 // timer hit 0 -> advance the state machine
        cmp #SP_CLOSE
        beq !close+
        cmp #SP_HOLD
        beq !hold+
        cmp #SP_OPEN
        beq !open+
        // SP_GAP done -> begin closing
        lda #SP_CLOSE
        sta ssub,x
        lda #SPLIT_STEP
        sta stmr,x
        jmp !next+

!close: dec sep,x
        bne !stepdraw+
        // reached 0 -> MEET: flash white, hold readable
        lda #SP_HOLD
        sta ssub,x
        lda #SPLIT_HOLD
        sta stmr,x
        lda #SPLIT_FLASH
        sta sflash,x
        lda #$01                   // white reunion flash
        jsr fill_col_x
        jsr render_split_x
        jmp !next+

!hold:  lda #SP_OPEN               // held long enough -> diverge again
        sta ssub,x
        lda #SPLIT_STEP
        sta stmr,x
        jmp !next+

!open:  inc sep,x
        lda sep,x
        cmp #20
        bcc !stepdraw+
        lda #SP_GAP                // fully apart -> blank pause
        sta ssub,x
        lda #SPLIT_GAP
        sta stmr,x
        jsr render_split_x
        jmp !next+

!stepdraw:
        lda #SPLIT_STEP
        sta stmr,x
        jsr render_split_x
!next:  dec linecnt
        bmi !sudone+
        jmp !su-
!sudone:
        rts

//==================================================================
// render_split_x — draw line `linecnt` as two converging halves.
//   left  col c (0..19): k=c+sep ; k<20 ? text[k] : space
//   right col c (20..39): k=c-sep ; k>=20 ? text[k] : space
// X=column, Y=k (text idx), srcptr=text base (=buffer+CENTER), store
// self-modded to the row's screen address. ~1000 cy, only on a step.
//==================================================================
render_split_x:
        ldx linecnt
        lda src_lo,x               // srcptr = buffer + CENTER (= text[0])
        clc
        adc #CENTER
        sta srcptr
        lda src_hi,x
        adc #0
        sta srcptr+1
        lda dst_lo,x               // patch both store targets to this row
        sta !rsl+ +1
        sta !rsr+ +1
        lda dst_hi,x
        sta !rsl+ +2
        sta !rsr+ +2
        lda sep,x
        sta tmp                    // sep
        ldx #0
!lh:    txa                        // left half, c = 0..19
        clc
        adc tmp                    // k = c + sep
        cmp #20
        bcs !lsp+
        tay
        lda (srcptr),y
        jmp !lput+
!lsp:   lda #$20
!lput:
!rsl:   sta $0400,x                // self-modified row address
        inx
        cpx #20
        bne !lh-
!rh:    txa                        // right half, c = 20..39
        sec
        sbc tmp                    // k = c - sep
        cmp #20
        bcc !rsp+                  // k < 20 -> space
        tay
        lda (srcptr),y
        jmp !rput+
!rsp:   lda #$20
!rput:
!rsr:   sta $0400,x
        inx
        cpx #40
        bne !rh-
        rts

//==================================================================
// fill_col_x — fill colour RAM for line `linecnt` with the colour in A.
//==================================================================
fill_col_x:
        pha
        ldx linecnt
        lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        pla
        ldy #39
!fc:    sta (cptr),y
        dey
        bpl !fc-
        rts


//==================================================================
// init_banner — copy ROM font to RAM, point the banner row's cells at the
// canvas scratch chars, clear the canvas, seed the scroll pointers/pending.
// Call once during setup, BEFORE the display is enabled.
//==================================================================
init_banner:
        // copy ROM uppercase font ($D000) -> FONT_RAM (2KB, 8 pages)
        lda $01
        pha
        lda #$33                   // bank char ROM in at $D000
        sta $01
        lda #$00
        sta $02
        lda #$d0
        sta $03
        lda #$00
        sta $04
        lda #>FONT_RAM
        sta $05
        ldx #8
        ldy #0
!fc:    lda ($02),y
        sta ($04),y
        iny
        bne !fc-
        inc $03
        inc $05
        dex
        bne !fc-
        pla
        sta $01                    // I/O back in

        // both banner rows: screen cells -> their canvas char codes
        ldx #0
!bc:    txa
        clc
        adc #C1CODE
        sta SCREEN + BANNER1ROW*40, x
        txa
        clc
        adc #C2CODE
        sta SCREEN + BANNER2ROW*40, x
        lda #$0e
        sta COLOR + BANNER1ROW*40, x
        sta COLOR + BANNER2ROW*40, x
        inx
        cpx #40
        bne !bc-

        jsr build_bsrc             // pre-render both clean lines into bsrc/bsrc2
        jsr build_bsrc2

        lda #0                     // both start at the meet, holding
        sta bs_sub
        sta bcol
        sta bsmooth
        sta bs_sub2
        sta bcol2
        sta bsmooth2
        lda #BPAUSE
        sta bs_tmr
        lda #BPAUSE2
        sta bs_tmr2
        ldy #7                     // seed pending from column 0 of each
!sp:    lda bsrc,y
        sta pending_even,y
        sta pending_odd,y
        lda bsrc2,y
        sta pending_even2,y
        sta pending_odd2,y
        dey
        bpl !sp-
        ldx #0                     // blit both canvases = clean readable lines
!c1:    lda bsrc,x
        sta CANVAS1,x
        lda bsrc2,x
        sta CANVAS2,x
        inx
        bne !c1-
        ldx #0
!c2:    lda bsrc+$100,x
        sta CANVAS1+$100,x
        lda bsrc2+$100,x
        sta CANVAS2+$100,x
        inx
        cpx #64
        bne !c2-
        rts

//==================================================================
// Banner engine — both banners share these two macros.
//==================================================================
// BUILD_BSRC — render a 40-char line MSGB into BSRCB (CANVAS byte order).
.macro BUILD_BSRC(BSRCB, PTRLO, PTRHI, LINEIDX) {
        ldx LINEIDX                // srcptr = line PTRLO/HI[LINEIDX]
        lda PTRLO,x
        sta srcptr
        lda PTRHI,x
        sta srcptr+1
        lda #<BSRCB
        sta cptr
        lda #>BSRCB
        sta cptr+1
        ldy #0                     // Y = char column 0..39
!bc:    lda (srcptr),y
        sty tmp                    // save col (inner loop reuses Y)
        jsr glyph_ptr
        ldy #7
!br:    lda ($02),y
        sta (cptr),y
        dey
        bpl !br-
        lda cptr
        clc
        adc #8
        sta cptr
        bcc !nc+
        inc cptr+1
!nc:    ldy tmp
        iny
        cpy #40
        bne !bc-
}

// BANNER_FRAME — one frame of 1px ROL/ROR venetian streaming for a banner
// (even rows ROL left, odd rows ROR right). At a column boundary advance and
// reload pending from BSRCB; after a full MLEN cycle snap clean + HOLD PAUSE.
.macro BANNER_FRAME(CANVAS, MLEN, BSRCB, PAUSE, sub, tmr, col, smth, pe, po, LINEIDX, NLINESB, REBUILD) {
        lda sub
        bne !mv+
        dec tmr                    // HOLD the readable meet
        beq !hd+
        jmp !end+
!hd:    lda #1
        sta sub
        jmp !end+
!mv:    ldx #0
!row:   txa
        and #$01
        beq !ev+
        jmp !od+
!ev:    asl pe,x
        .for (var c = 39; c >= 0; c--) { rol CANVAS + c*8, x }
        jmp !nx+
!od:    lsr po,x
        .for (var c = 0; c <= 39; c++) { ror CANVAS + c*8, x }
!nx:    inx
        cpx #8
        beq !adv+
        jmp !row-
!adv:   inc smth
        lda smth
        cmp #8
        beq !home+
        jmp !end+
!home:
        lda #0
        sta smth
        inc col
        lda col
        cmp #MLEN
        bne !ldp+
        lda #0                     // home -> snap exactly clean + hold
        sta col
        lda #1                     // mark this a HEAVY frame (big blit + rebuild)
        sta b_did_render           //   so the static-row slide skips its render
        ldx #0
!bl:    lda BSRCB,x
        sta CANVAS,x
        inx
        bne !bl-
        ldx #0
!bl2:   lda BSRCB+$100,x
        sta CANVAS+$100,x
        inx
        cpx #(MLEN*8-256)
        bne !bl2-
        // canvas now shows the current line at its meet. Advance to the NEXT
        // line, rebuild BSRCB from it + reseed pending, so the next scroll
        // brings the next story line in.
        inc LINEIDX
        lda LINEIDX
        cmp #NLINESB
        bcc !li+
        lda #0
        sta LINEIDX
!li:    jsr REBUILD
        ldy #7
!rs:    lda BSRCB,y
        sta pe,y
        sta po,y
        dey
        bpl !rs-
        lda #0
        sta sub
        lda #PAUSE
        sta tmr
        jmp !end+
!ldp:   lda col                    // feed next column into pending
        asl
        asl
        asl
        clc
        adc #<BSRCB
        sta srcptr
        lda col
        lsr
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>BSRCB
        sta srcptr+1
        ldy #7
!lp:    lda (srcptr),y
        sta pe,y
        sta po,y
        dey
        bpl !lp-
!end:
}

// The banner engine + remaining code/data live above the SID ($1000-$144e)
// to keep the first code block under it — the 2nd banner pushed Main over.
* = $2000 "Banner+"

build_bsrc:
        BUILD_BSRC(bsrc, ln1lo, ln1hi, lineidx1)
        rts
build_bsrc2:
        BUILD_BSRC(bsrc2, ln2lo, ln2hi, lineidx2)
        rts

//==================================================================
// banner_scroll / banner_scroll2 — one 1px streaming frame each (macro).
//==================================================================
banner_scroll:
        BANNER_FRAME(CANVAS1, MSGLEN, bsrc, BPAUSE, bs_sub, bs_tmr, bcol, bsmooth, pending_even, pending_odd, lineidx1, NL1, build_bsrc)
        rts
banner_scroll2:
        BANNER_FRAME(CANVAS2, MSGLEN2, bsrc2, BPAUSE2, bs_sub2, bs_tmr2, bcol2, bsmooth2, pending_even2, pending_odd2, lineidx2, NL2, build_bsrc2)
        rts

// banner_color — drift a 16-hue rainbow across the banner row every frame
// (col>>1 de-confettis it; runs even during the meet pause so it never sits
// dead). Light, ~40 colour-RAM writes.
banner_color:
        lda frame
        and #$03
        bne !nd+
        inc bhue
!nd:    ldx #0
!bc:    txa
        lsr
        clc
        adc bhue
        and #$07                   // text-safe 8-hue palette: all high-luma,
        tay                        // so every letter stays readable at the meet
        lda rbsafe,y
        sta COLOR + BANNER1ROW*40, x
        inx
        cpx #40
        bne !bc-
        rts

// banner_color2 — same drift on banner 2's row, phase-offset for variety.
banner_color2:
        ldx #0
!bc:    txa
        lsr
        clc
        adc bhue
        clc
        adc #4
        and #$07
        tay
        lda rbsafe,y
        sta COLOR + BANNER2ROW*40, x
        inx
        cpx #40
        bne !bc-
        rts

// glyph_ptr — A = char code -> $02/$03 = FONT_RAM + A*8
glyph_ptr:
        pha
        asl
        asl
        asl
        sta $02                    // low = (char<<3) & $ff
        pla
        lsr
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>FONT_RAM             // high = (char>>5) + FONT_RAM page
        sta $03
        rts


//==================================================================
// data
//==================================================================
phase:        .byte 0
phase_timer:  .byte 0
gfine:        .byte 0           // global sub-pixel counter 0..7 (the smooth scroll)
slide_char:   .byte 0           // char progress 0..80 (0/80 off-screen, 40 centre)
hold_settle:  .byte 0           // frames left to spread-render rows at HOLD entry
hold_idx:     .byte 0           // round-robin cursor for the HOLD settle render
sxval:        .fill NLINES, D016BASE   // per static row: live $d016 (smooth slide)
sdir:         .fill NLINES, (startList.get(i) < CENTER) ? 1 : 255  // slide dir/row
// per-row sub-pixel stagger so at most one row char-steps per frame. Tuned to
// the fixed role map (static rows = idx 1,2,4,5,8,9 -> soff 0..5); soff2row is
// the inverse. If role[] changes, regenerate both.
soff:         .byte 0, 0, 1, 0, 2, 3, 0, 0, 4, 5
soff2row:     .byte 1, 2, 4, 5, 8, 9
frame:        .byte 0
beatctr:      .byte 1                  // counts down to the next beat
beathue:      .byte 0                  // rainbow hue surge accumulated on beats
amp:          .byte 0
ev:           .byte 0
od:           .byte 0
tmp:          .byte 0
mode:         .byte 0
mode_timer:   .byte 1
wave_scroll:  .byte 0
linecnt:      .byte 0
swimphase:    .byte 0
sp:           .fill NLINES, 0

// per-line split state (only R_SPLIT lines use it)
sep:   .fill NLINES, 20                // separation: 20=apart/blank, 0=met
ssub:  .fill NLINES, SP_GAP            // sub-phase, start apart
stmr:  .fill NLINES, 1 + i*22          // staggered start so meets don't sync
sflash:.fill NLINES, 0                 // white-flash countdown after a meet

// banner venetian split-scroll state (1px ROL/ROR streaming)
bs_sub:       .byte 0                  // 0 = HOLD at meet, 1 = MOVE (streaming)
bs_tmr:       .byte 0                  // hold timer
bcol:         .byte 0                  // bsrc column currently feeding in (0..MSGLEN-1)
bsmooth:      .byte 0                  // 0..7 bit counter within a char-column
pending_even: .fill 8, 0               // incoming column bytes for the even (ROL) rows
pending_odd:  .fill 8, 0               // incoming column bytes for the odd (ROR) rows
b3ctr:        .byte 0                  // 0..2 weighting counter (top:bottom = 2:1)
bs_sub2:      .byte 0                  // banner 2 state (own canvas/message/tempo)
bs_tmr2:      .byte 0
bcol2:        .byte 0
bsmooth2:     .byte 0
pending_even2:.fill 8, 0
pending_odd2: .fill 8, 0
bhue:         .byte 0                  // rainbow drift phase for the banner row
barscroll:    .byte 0                  // flowing-rasterbar scroll offset
colrow:       .fill 40, 0              // one computed rainbow row, copied to all swim rows
b_did_render: .byte 0                  // 1 = banner rebuilt the canvas this frame (unused now)
// each line padded to 40 chars (screencode_upper); pointer tables index them
lines1data:
.for (var i = 0; i < NL1; i++) {
        .text lines1.get(i)
        .fill 40 - lines1.get(i).size(), $20
}
lines2data:
.for (var i = 0; i < NL2; i++) {
        .text lines2.get(i)
        .fill 40 - lines2.get(i).size(), $20
}
ln1lo: .fill NL1, <(lines1data + i*40)
ln1hi: .fill NL1, >(lines1data + i*40)
ln2lo: .fill NL2, <(lines2data + i*40)
ln2hi: .fill NL2, >(lines2data + i*40)
lineidx1:     .byte 0
lineidx2:     .byte 0

line_start:   .fill NLINES, startList.get(i)
line_exit:    .fill NLINES, 80 - startList.get(i)
line_speed:   .fill NLINES, speedList.get(i)
line_color:   .fill NLINES, colList.get(i)

// per-line role: 0 static, 1 swim, 2 split(center-column, retired). The real
// split is the venetian banner (row 16); 3 swim lines (rows 3/8/13) keep the
// poem wall alive, staggered with static lines between for readability.
role:         .byte R_SWIM, 0, 0, R_SWIM, 0, 0, R_SWIM, R_SWIM, 0, 0
// first raster line of each poetry row (display top 51 + row*8)
line_scan:    .fill NLINES, 50 + rowList.get(i)*8   // 50 (not 51): the shear value
                                   // written during a line affects THAT line, so place
                                   // the band one raster up or the top pixel-row lags
// all 16 C64 colours in a hue-ish order, for the drifting rainbow
rainbow16:
        .byte $01, $07, $08, $0a, $02, $04, $06, $0e
        .byte $03, $0d, $05, $0c, $0f, $0b, $09, $00
// text-safe rainbow (luma 12..32, no dark blue/brown/red) so the banner line
// reads cleanly at the meet while still cycling all the bright hues
rbsafe: .byte $08, $0a, $07, $0d, $01, $03, $0e, $04

src_lo: .fill NLINES, <(LINEBUF + i*BUFW)
src_hi: .fill NLINES, >(LINEBUF + i*BUFW)
dst_lo: .fill NLINES, <(SCREEN + rowList.get(i)*40)
dst_hi: .fill NLINES, >(SCREEN + rowList.get(i)*40)
col_lo: .fill NLINES, <(COLOR + rowList.get(i)*40)
col_hi: .fill NLINES, >(COLOR + rowList.get(i)*40)

// The 256-byte tables live ABOVE the SID ($1000-$144e), in the free gap
// before the line buffers ($4000). Keeps the Main code+state under $1000.
* = $1500 "Tables"

// Rubberband Swim sine: $d016 values $08..$0f (38-col bit always set,
// xscroll 0..7) so the column mode never flickers — only the shear swings.
sin7: .fill 256, $08 + round(3 + 3 * sin(toRadians(i * 360 / 256)))

// shear amplitude breath: 0..3, a few cycles over 256 frames
sine_amp: .fill 256, round(1.5 + 1.5 * sin(toRadians(i * 360 / 256)))

// traveling-wave table: actual $d016 values, base + a ±3 sine (4 cycles
// down the screen). build_wave indexes it by (line + wave_scroll).
wave_sine: .fill 256, D016BASE + round(3 * sin(toRadians(i * 360 * 4 / 256)))

.align 256
shear_tab: .fill 256, D016BASE

// flowing rasterbar palette: 8 dark blue/grey colours (readable behind text),
// rotated by barscroll. Bar EDGES sit on the 8-line grid (badline-safe).
barpal8: .byte $00, $06, $0b, $0c, $0b, $06, $00, $00
// per-rasterline bg colour, precomputed each frame by build_shear (one colour
// per 8-line block) so irq_shear can write $d021 early with no compute.
d021tab: .fill 256, 0

// the clean readable banner line, pre-rendered in CANVAS byte order
bsrc:  .fill 320, 0
bsrc2: .fill 320, 0


//==================================================================
// SID — "Dingen" by Cinder/deFEEST
//==================================================================
* = music.location "Music"
        .fill music.size, music.getData(i)


.macro poemline(s) {
        .fill 40, $20
        .text s
        .fill BUFW - 40 - s.size(), $20
}

* = LINEBUF "LineBuffers"
        poemline("    DEFEEST DREAMS IN FORTY KILOBYTES   ")
        poemline("  THE BREADBIN HUMS A RASTER LULLABY    ")
        poemline("  PIXELS FALL LIKE FRIET FROM THE SKY   ")
        poemline("  EVERY SCANLINE A SMALL CONFESSION     ")
        poemline("  WE SOLDER POETRY INTO THE BORDER      ")
        poemline("    MAYO AND MATH AND MIDNIGHT OIL      ")
        poemline("  TWENTY MEN AND ONE EXTENSION CORD     ")
        poemline("   THE COMPO CLOCK FORGIVES NOTHING     ")
        poemline("   SPLIT APART TO MEET AGAIN AS ONE     ")
        poemline("   SEE YOU AT EVOKE   AUGURK WAS HERE    ")

// ============================================================
// ScreenFill pack — assembled at $c000 but packed at physical *
// ============================================================
screenfill_pack_start:
.pseudopc $c000 {
// screenfill — DEFEEST radial bloom + water ripple intro
// Ported from x2026-kloten/parts/screenfill/ by Augurk & de Zuursectie
// Zero page: $02 CHARCNT, $03 SCRPOS, $04 WCNT, $05 PHASE,
//            $06 HOLDCNT, $07 RADIUS, $08 RFRAME, $fb MASK

.label char_table = $c700

entry:
        sei
        lda #$3c
        sta $dd02
        lda #%00010111
        sta $d018
        lda #$1b
        sta $d011
        lda #$08
        sta $d016
        lda #$00
        sta $d015
        lda #$06
        sta $d021
        lda #$0e
        sta $d020
        ldx #0
        lda #$0e
!col:   sta $d800,x
        sta $d900,x
        sta $da00,x
        sta $db00,x
        inx
        bne !col-
        lda #0
        sta $02
        sta $03
        sta $04
        sta $05
        sta $07
        sta $08
        lda #150
        sta $06
        jmp loop_outer

fill_done:
        lda #<irq
        sta $fffe
        lda #>irq
        sta $ffff
        lda #$ff
        sta $d012
        lda #$01
        sta $d01a
        lda $d011
        and #$7f
        sta $d011
        lda #$ff
        sta $d019
        cli
        rts

loop_outer:
        lda #0
        sta $02
loop_char:
        lda $02
        and #$07
        clc
        adc #1
        tax
        lda #$01
!rol:   asl
        dex
        bne !rol-
        sta $fb
        lda $04
        and $fb
        beq is_lower
        ldx $02
        lda dtext,x
        jmp emit
is_lower:
        ldx $02
        lda dtext,x
        cmp #$20
        beq emit
        sec
        sbc #$40
emit:
        ldx $03
chrtab_w:
        sta char_table,x
        inc $03
        bne !nowrap+
        inc chrtab_w+2
        lda chrtab_w+2
        cmp #(>char_table + 4)
        beq fill_done
!nowrap:
        inc $02
        lda $02
        cmp #7
        bne loop_char
        inc $04
        jmp loop_outer

irq:
        pha
        txa
        pha
        tya
        pha
        lda #$ff
        sta $d019
        lda $07
        cmp #16
        bcs do_ripple
        inc $08
        lda $08
        cmp #8
        bcs !emit+
        jmp irq_done
!emit:  lda #0
        sta $08
        ldy #0
!p1:    lda dist_table+$000,y
        cmp $07
        bne !nx1+
        lda char_table+$000,y
        sta $0400,y
!nx1:   iny
        bne !p1-
!p2:    lda dist_table+$100,y
        cmp $07
        bne !nx2+
        lda char_table+$100,y
        sta $0500,y
!nx2:   iny
        bne !p2-
!p3:    lda dist_table+$200,y
        cmp $07
        bne !nx3+
        lda char_table+$200,y
        sta $0600,y
!nx3:   iny
        bne !p3-
!p4:    lda dist_table+$300,y
        cmp $07
        bne !nx4+
        lda char_table+$300,y
        sta $0700,y
!nx4:   iny
        bne !p4-
        inc $07
        lda $07
        cmp #16
        beq !setborder+
        jmp irq_done
!setborder:
        lda #$06
        sta $d020
        jmp irq_done

do_ripple:
        lda $06
        bne !doripple+
        jmp irq_done
!doripple:
        ldy #0
!bp:    tya
        sec
        sbc $05
        and #$0f
        tax
        lda ripple_pal,x
        sta current_pal,y
        iny
        cpy #16
        bne !bp-
        ldy #0
!r1:    ldx dist_table+$000,y
        lda current_pal,x
        sta $d800,y
        iny
        bne !r1-
!r2:    ldx dist_table+$100,y
        lda current_pal,x
        sta $d900,y
        iny
        bne !r2-
!r3:    ldx dist_table+$200,y
        lda current_pal,x
        sta $da00,y
        iny
        bne !r3-
!r4:    ldx dist_table+$300,y
        lda current_pal,x
        sta $db00,y
        iny
        bne !r4-
        lda $06
        cmp #85
        bcs !nofade+
        and #$07
        bne !nofade+
        ldy #15
!fl:    ldx ripple_pal,y
        lda fadetab,x
        sta ripple_pal,y
        dey
        bpl !fl-
!nofade:
        lda $06
        cmp #72
        bne !nbg+
        lda #$00
        sta $d021
        sta $d020
!nbg:
        inc $05
        dec $06
        bne irq_done
        lda #$ff
        sta $cffe
irq_done:
        pla
        tay
        pla
        tax
        pla
        rti

.align 256
dist_table:
.for (var i = 0; i < 1024; i++) {
    .var y  = floor(i / 40)
    .var x  = i - y * 40
    .var dx = x - 20
    .var dy = y - 12
    .var d  = round(sqrt(dx*dx + dy*dy) * 15 / 23)
    .byte d & $0f
}

ripple_pal:
        .byte $00, $06, $06, $0e, $0e, $03, $03, $01
        .byte $01, $03, $03, $0e, $0e, $06, $06, $00
current_pal:
        .fill 16, 0
fadetab:
        .byte $00, $0f, $00, $0e, $00, $00, $00, $00
        .byte $00, $00, $00, $00, $0b, $00, $06, $0c
dtext:
        .byte $44, $45, $46, $45, $45, $53, $54
}
screenfill_pack_end:
.const screenfill_pack_size = screenfill_pack_end - screenfill_pack_start

// ============================================================
// copy_sf — copy screenfill pack from PRG to $c000
// Uses zp $02-$07 (screenfill init overwrites them next)
// ============================================================
copy_sf:
        lda #<screenfill_pack_start
        sta $02
        lda #>screenfill_pack_start
        sta $03
        lda #$00
        sta $04
        lda #$c0
        sta $05
        lda #<screenfill_pack_size
        sta $06
        lda #>screenfill_pack_size
        sta $07
        ldy #0
!lp:    lda $06
        ora $07
        beq !done+
        lda ($02),y
        sta ($04),y
        iny
        bne !next+
        inc $03
        inc $05
!next:  lda $06
        bne !dec+
        dec $07
!dec:   dec $06
        jmp !lp-
!done:  rts
