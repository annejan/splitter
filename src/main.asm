//==================================================================
// splitter — v0.5  "full-screen $d016 zig-zag shear + poetry + SID"
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

.var rowList   = List().add(7, 8, 9, 10, 11, 12, 13, 14, 15, 16)
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

.const PH_IN    = 0
.const PH_HOLD  = 1
.const PH_OUT   = 2
.const T_IN     = 130
.const T_HOLD   = 120
.const T_OUT    = 130

.const TOP      = $6b              // shear band = the packed poetry block (rows
.const BOT      = $bb              //   7-16). Tight band -> short shear loop ->
.const WORKLINE = $c0              //   ~70 lines of budget back. irq_work below BOT.
.const D016BASE = $0c              // 40-col + xscroll 4 (shear centre)
.const MODE_TIME = 220             // frames per shear mode (0 zigzag/1 wave/2 row)

start:
        sei
        lda #$35
        sta $01
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
!si:    lda line_start,x
        sta sp,x
        dex
        bpl !si-
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

        inc $d020                  // ## budget band ##
        jsr music.play             // every frame -> SID never skips
        jsr update_phase           // every frame -> phase timing stays true
        inc frame
        lda frame
        lsr
        bcs !oddframe+
        // EVEN frame: the 400-char render (skip while held still)
        lda phase
        cmp #PH_HOLD
        beq !workdone+
        jsr render
        jmp !workdone+
!oddframe:
        // ODD frame: shear table + the rainbow. Splitting render off the
        // build/colour frame keeps either single frame inside the budget
        // so the beam never laps us — animation steps at 25fps, music and
        // the shear DISPLAY stay a solid 50Hz.
        jsr build_shear
        jsr color_cycle
!workdone:
        dec $d020

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
        lda phase
        cmp #PH_HOLD
        bne !breathe+
        lda #$00                   // readable MEET -> no shear (clean)
        beq !setamp+
!breathe:
        ldx frame
        lda sine_amp,x             // slow breath 0..3 while lines move
!setamp:
        sta amp
        lda #D016BASE
        clc
        adc amp
        sta ev
        lda #D016BASE
        sec
        sbc amp
        sta od

        // per-LINE role: SPLIT rows weave (zig-zag), clean rows stay flat
        ldx #NLINES-1
!bl:    ldy line_scan,x
        lda role,x
        beq !clean+
        lda ev                     // SPLIT: 8 scanlines, even ev / odd od
        sta shear_tab,y
        iny
        lda od
        sta shear_tab,y
        iny
        lda ev
        sta shear_tab,y
        iny
        lda od
        sta shear_tab,y
        iny
        lda ev
        sta shear_tab,y
        iny
        lda od
        sta shear_tab,y
        iny
        lda ev
        sta shear_tab,y
        iny
        lda od
        sta shear_tab,y
        jmp !nx+
!clean: lda #D016BASE              // SCROLL/clean: 8 flat scanlines
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
!nx:    dex
        bpl !bl-
        rts


//==================================================================
// color_cycle — per-char 16-colour rainbow drifting diagonally. The
// whole palette in motion (jonguh, demoscene). Unrolled per row; runs
// on the odd frame next to build_shear so it stays inside 50 Hz.
//==================================================================
color_cycle:
        .for (var r=0; r<NLINES; r++) {
            ldx #39
        !cc:
            txa
            clc
            adc frame
            adc #(r*5)             // diagonal phase per row
            and #$0f
            tay
            lda rainbow16,y
            sta COLOR + rowList.get(r)*40, x
            dex
            bpl !cc-
        }
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
        // rotate roles -> the sexy splits land on new lines each cycle
        ldx role+0
        ldy #0
!rot:   lda role+1,y
        sta role,y
        iny
        cpy #NLINES-1
        bne !rot-
        stx role + NLINES-1
        ldx #NLINES-1
!rst:   lda line_start,x
        sta sp,x
        dex
        bpl !rst-
        rts
!move:
        ldx #NLINES-1
!ml:    lda phase
        cmp #PH_OUT
        bne !tgtc+
        lda line_exit,x
        jmp !havetgt+
!tgtc:  lda #CENTER
!havetgt:
        sta tmp
        lda sp,x
        cmp tmp
        beq !mnext+
        bcc !up+
        sec
        sbc line_speed,x
        cmp tmp
        bcs !sset+
        lda tmp
        jmp !sset+
!up:    clc
        adc line_speed,x
        cmp tmp
        bcc !sset+
        lda tmp
!sset:  sta sp,x
!mnext: dex
        bpl !ml-
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
sp:           .fill NLINES, 0

line_start:   .fill NLINES, startList.get(i)
line_exit:    .fill NLINES, 80 - startList.get(i)
line_speed:   .fill NLINES, speedList.get(i)
line_color:   .fill NLINES, colList.get(i)

// per-line role (1 = SPLIT/sexy weave, 0 = clean) — rotated each cycle
role:         .byte 1, 0, 0, 1, 0, 0, 0, 1, 0, 0
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
        poemline("   SEE YOU AT EVOKE   KLOOT WAS HERE    ")
