//==================================================================
// splitter — v0.12  "THE SPLIT: lines break into two halves that converge to one"
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

.const TOP      = $42              // shear band spans the poetry (rows 2-18). Most
.const BOT      = $c4              //   lines are static (drawn once, 0 work/frame);
.const WORKLINE = $c8              //   only 3 hero lines animate -> budget wide open.
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
.const DEBUG    = 1                // 1 = colour-band raster profiler in the border
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

        lda #$14
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
        dbg($04)                   // PURPLE = shear table (swim rows)
        jsr build_shear
        dbg($05)                   // GREEN = rainbow (swim rows)
        jsr color_cycle
        dbg($0e)                   // LT-BLUE = split state machine + redraw
        jsr split_update
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
        tya
        pha
        lda #$ff
        sta $d019

        ldy #TOP
!sl:    lda shear_tab,y
        sta $d016
        iny
!w:     cpy $d012
        bne !w-
        cpy #BOT
        bne !sl-
        lda #D016BASE
        sta $d016

        lda #<irq_work
        sta $fffe
        lda #>irq_work
        sta $ffff
        lda #WORKLINE
        sta $d012

        pla
        tay
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
        lda role,x
        bne !swim+
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
        .for (var s = 0; s < 8; s++) {
            lda sin7,x
            sta shear_tab,y
            .if (s < 7) {
                iny
                txa
                clc
                adc #VSTEP
                tax
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
// color_cycle — per-char 16-colour rainbow drifting diagonally. The
// whole palette in motion (jonguh, demoscene). Unrolled per row; runs
// on the odd frame next to build_shear so it stays inside 50 Hz.
//==================================================================
color_cycle:
        lda #NLINES-1
        sta linecnt
!cl:    ldx linecnt
        lda role,x                 // only SWIM rows rainbow; split/static stay plain
        cmp #R_SWIM
        bne !skip+
        lda col_lo,x
        sta cptr
        lda col_hi,x
        sta cptr+1
        ldy #39
!cc:    tya
        clc
        adc frame
        and #$0f
        tax
        lda rainbow16,x
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

line_start:   .fill NLINES, startList.get(i)
line_exit:    .fill NLINES, 80 - startList.get(i)
line_speed:   .fill NLINES, speedList.get(i)
line_color:   .fill NLINES, colList.get(i)

// per-line role: 0 static, 1 swim, 2 split. Two splits (rows 2,14) + one
// swim (row 8) on orthogonal axes, staggered; the rest static negative space.
role:         .byte R_SPLIT, 0, 0, 0, R_SWIM, 0, 0, 0, R_SPLIT, 0
// first raster line of each poetry row (display top 51 + row*8)
line_scan:    .fill NLINES, 51 + rowList.get(i)*8
// all 16 C64 colours in a hue-ish order, for the drifting rainbow
rainbow16:
        .byte $01, $07, $08, $0a, $02, $04, $06, $0e
        .byte $03, $0d, $05, $0c, $0f, $0b, $09, $00

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
