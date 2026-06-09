//==================================================================
// splitter — v0.31  "diagonal rainbow, slow + consistent (round-robin, every frame)"
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

// Banner line — EXACTLY 40 chars so the meet snaps to a clean readable row.
.var bmsg   = "    SPLITTER  -  FRISSER  DAN  OOIT     "
.const MSGLEN = bmsg.size()   // = 40

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
.const T_IN     = 130
.const T_HOLD   = 120
.const T_OUT    = 130

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
.const SMAX       = 40             // FULL line width: the halves slide the whole 40 cols
                                   //   (fully off + back) so the sweep covers the entire
                                   //   line — not a fixed shorter reach that left part of
                                   //   the row half-done. 40*2 ~ 1.6s each way.
.const BSTEP2     = 1              // step every frame -> with the even/odd split that
                                   //   lands a char-step every 2 frames (25Hz motion)
                                   //   while each frame stays <=3.8k cy -> 50Hz held
.const BPAUSE     = 220            // long readable hold (~4.4s) so the meet still dominates
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
!si:    lda #CENTER                // all lines static at their readable window
        sta sp,x
        dex
        bpl !si-
        jsr render                 // draw the whole poem ONCE (static)
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
        dbg($07)                   // YELLOW = phase machine
        jsr update_phase
        inc frame
        dbg($0a)                   // LT-RED = venetian banner (sets b_did_render)
        jsr banner_scroll          //   run FIRST so the heavy-frame flag is known
        jsr banner_color
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
        lda #D016BASE              // clean: 8 flat scanlines
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
        lda linecnt
        clc
        adc frame
        and #$01
        bne !skip+
        lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        lda frame                  // hue base = (frame>>2) + row*3
        lsr
        lsr
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


update_phase:
        dec phase_timer
        bne !move+
        lda phase
        cmp #PH_IN
        bne !notin+
        lda #PH_HOLD
        sta phase
        lda #T_HOLD
        sta phase_timer
        ldx #NLINES-1
!snap:  lda #CENTER
        sta sp,x
        dex
        bpl !snap-
        rts
!notin:
        cmp #PH_HOLD
        bne !nothold+
        lda #PH_OUT
        sta phase
        lda #T_OUT
        sta phase_timer
        rts
!nothold:
        lda #PH_IN
        sta phase
        lda #T_IN
        sta phase_timer
        // roles are FIXED while we dial in the split — no rotation (it would
        // shuffle which lines split mid-flight and fight the state machine).
        rts
!move:
        rts                        // text is static — no per-frame slide


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

        // banner row cells -> canvas char codes C1CODE..C1CODE+39
        ldx #0
!bc:    txa
        clc
        adc #C1CODE
        sta SCREEN + BANNER1ROW*40, x
        lda #$0e                   // light-blue for now (rainbow drift later)
        sta COLOR + BANNER1ROW*40, x
        inx
        cpx #40
        bne !bc-

        // pre-render the clean line into bsrc; start at the meet, holding
        jsr build_bsrc
        lda #0
        sta bs_sub                 // HOLD (readable)
        sta bcol                   // feed starts at column 0
        sta bsmooth
        lda #BPAUSE
        sta bs_tmr
        jsr load_pending           // seed the incoming column
        jsr blit_bsrc              // draw the clean readable line into the canvas
        rts

//==================================================================
// build_bsrc — render the 40-char banner line into bsrc, in CANVAS byte
// order (bsrc[c*8 + r] = font glyph row r of char c). Done once at init.
//==================================================================
build_bsrc:
        lda #<bsrc
        sta cptr
        lda #>bsrc
        sta cptr+1
        ldx #0                     // X = char column 0..39
!bc:    lda msg,x
        jsr glyph_ptr              // $02/$03 = FONT_RAM + char*8
        ldy #7
!br:    lda ($02),y
        sta (cptr),y               // bsrc[c*8 + r]
        dey
        bpl !br-
        lda cptr                   // cptr += 8
        clc
        adc #8
        sta cptr
        bcc !nc+
        inc cptr+1
!nc:    inx
        cpx #40
        bne !bc-
        rts

//==================================================================
// banner_scroll — SMOOTH 1px venetian split-scroll via per-pixel-row ROL/ROR
// (the real kloten technique). Each frame: even rows shift LEFT 1px (ROL,
// fed a bit from pending_even), odd rows shift RIGHT 1px (ROR, fed
// pending_odd). Every 8 frames a full char-column has entered -> advance
// bcol and reload pending from bsrc. After a whole MSGLEN cycle the row is
// back to bsrc (readable) -> snap+HOLD. ~2.4k cy/frame, EVERY frame, so the
// motion is a buttery 50Hz (no even/odd split, no overrun).
//==================================================================
banner_scroll:
        lda #0
        sta b_did_render           // default: let irq_work run colour this frame
        lda bs_sub
        bne !move+
        dec bs_tmr                 // HOLD the readable meet
        beq !holddone+
        rts
!holddone:
        lda #1                     // -> MOVE
        sta bs_sub
        rts
!move:  lda #1                     // streaming this frame -> irq_work skips colour
        sta b_did_render           //   (the swim rainbow freezes ~0.8s, imperceptible)
        ldx #0                     // X = pixel row 0..7
!row:   txa
        and #$01
        beq !even+
        jmp !odd+
!even:  asl pending_even,x         // even row: ROL left, new bit enters cell 39
        .for (var c = 39; c >= 0; c--) {
            rol CANVAS1 + c*8, x
        }
        jmp !nx+
!odd:   lsr pending_odd,x          // odd row: ROR right, new bit enters cell 0
        .for (var c = 0; c <= 39; c++) {
            ror CANVAS1 + c*8, x
        }
!nx:    inx
        cpx #8
        beq !adv+
        jmp !row-
!adv:   inc bsmooth                // 8 bits = one full char-column scrolled in
        lda bsmooth
        cmp #8
        bne !done+
        lda #0
        sta bsmooth
        inc bcol
        lda bcol
        cmp #MSGLEN
        bne !ld+
        lda #0                     // wrapped a full cycle -> home (== bsrc)
        sta bcol
        jsr blit_bsrc              // snap exactly clean + hold the readable line
        lda #0
        sta bs_sub
        lda #BPAUSE
        sta bs_tmr
        rts
!ld:    jsr load_pending           // feed the next column into pending_even/odd
!done:  rts

//==================================================================
// blit_bsrc — copy the clean readable line (bsrc) straight into the canvas.
//==================================================================
blit_bsrc:
        ldx #0
!b1:    lda bsrc,x
        sta CANVAS1,x
        inx
        bne !b1-
        ldx #0
!b2:    lda bsrc+$100,x
        sta CANVAS1+$100,x
        inx
        cpx #(320-256)
        bne !b2-
        rts

//==================================================================
// load_pending — load bsrc column `bcol` (8 bytes) into pending_even/odd
// (both get the same column; the opposite ROL/ROR makes the venetian).
//==================================================================
load_pending:
        lda bcol
        sta tmp
        asl
        asl
        asl
        clc
        adc #<bsrc
        sta srcptr
        lda tmp
        lsr
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>bsrc
        sta srcptr+1
        ldy #7
!lp:    lda (srcptr),y
        sta pending_even,y
        sta pending_odd,y
        dey
        bpl !lp-
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
frame:        .byte 0
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
bhue:         .byte 0                  // rainbow drift phase for the banner row
barscroll:    .byte 0                  // flowing-rasterbar scroll offset
colrow:       .fill 40, 0              // one computed rainbow row, copied to all swim rows
b_did_render: .byte 0                  // 1 = banner rebuilt the canvas this frame (unused now)
msg:          .text bmsg               // the banner line (screencode_upper)

line_start:   .fill NLINES, startList.get(i)
line_exit:    .fill NLINES, 80 - startList.get(i)
line_speed:   .fill NLINES, speedList.get(i)
line_color:   .fill NLINES, colList.get(i)

// per-line role: 0 static, 1 swim, 2 split(center-column, retired). The real
// split is the venetian banner (row 16); 3 swim lines (rows 3/8/13) keep the
// poem wall alive, staggered with static lines between for readability.
role:         .byte R_SWIM, R_SWIM, 0, R_SWIM, R_SWIM, 0, R_SWIM, R_SWIM, 0, 0
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
bsrc: .fill 320, 0


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
