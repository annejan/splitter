//==================================================================
// splitter — v0.4  "scene-poetry choreographer + SID"
//
// A screen full of semi-poetic nonsense, each line moving DIFFERENTLY:
// some slide in from the left, some from the right, at different speeds.
// They converge to readable, hold a beat, drift back out, repeat. Music:
// "Dingen" by Cinder/deFEEST.
//
// Char mode: each line is a 120-char buffer (40 pad / 40 content / 40
// pad); a per-line scan position sp (0..80) windows 40 chars onto its
// row. sp=40 reads true. A global IN/HOLD/OUT machine drives sp toward
// 40 (each line at its own speed, from its own side), holds, then out.
//==================================================================
.cpu _6502
.encoding "screencode_upper"

.var music = LoadSid("../music/kleuter-dinges.sid")

// per-line choreography (assembly-time lists)
.var rowList   = List().add(2, 4, 6, 8, 10, 12, 14, 16, 18, 20)
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

start:
        sei
        lda #$35
        sta $01
        lda #$14
        sta $d018
        lda #$1b
        sta $d011
        lda #$08
        sta $d016
        lda #$00
        sta $d020
        sta $d021

        // clear screen
        ldx #0
        lda #$20
!cl:    sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        inx
        bne !cl-

        // per-line colour fill
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

        // init line state
        ldx #NLINES-1
!si:    lda line_start,x
        sta sp,x
        dex
        bpl !si-
        lda #PH_IN
        sta phase
        lda #T_IN
        sta phase_timer

        // init music (song 0)
        lda #music.startSong-1
        jsr music.init

        // raster IRQ
        lda #<irq
        sta $fffe
        lda #>irq
        sta $ffff
        lda #$7f
        sta $dc0d
        sta $dd0d
        lda $dc0d
        lda $dd0d
        lda #$01
        sta $d01a
        lda #$00
        sta $d012
        lda $d011
        and #$7f
        sta $d011
        lda #$ff
        sta $d019
        cli
!loop:  jmp !loop-


irq:
        pha
        txa
        pha
        tya
        pha
        lda #$ff
        sta $d019

        jsr music.play

        inc $d020                  // ## debug budget band ##
        jsr update_phase
        jsr render
        dec $d020

        pla
        tay
        pla
        tax
        pla
        rti


//==================================================================
// update_phase — IN/HOLD/OUT machine + per-line move toward target.
//==================================================================
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
        sec                         // sp > target -> down by speed
        sbc line_speed,x
        cmp tmp
        bcs !sset+
        lda tmp
        jmp !sset+
!up:    clc                         // sp < target -> up by speed
        adc line_speed,x
        cmp tmp
        bcc !sset+
        lda tmp
!sset:  sta sp,x
!mnext: dex
        bpl !ml-
        rts


//==================================================================
// render — window 40 chars of each line buffer onto its screen row.
//==================================================================
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
tmp:          .byte 0
sp:           .fill NLINES, 0

line_start:   .fill NLINES, startList.get(i)
line_exit:    .fill NLINES, 80 - startList.get(i)
line_speed:   .fill NLINES, speedList.get(i)
line_color:   .fill NLINES, colList.get(i)

src_lo: .fill NLINES, <(LINEBUF + i*BUFW)
src_hi: .fill NLINES, >(LINEBUF + i*BUFW)
dst_lo: .fill NLINES, <(SCREEN + rowList.get(i)*40)
dst_hi: .fill NLINES, >(SCREEN + rowList.get(i)*40)
col_lo: .fill NLINES, <(COLOR + rowList.get(i)*40)
col_hi: .fill NLINES, >(COLOR + rowList.get(i)*40)


//==================================================================
// SID music — "Dingen" by Cinder/deFEEST (load $1000, init/play there)
//==================================================================
* = music.location "Music"
        .fill music.size, music.getData(i)


//==================================================================
// line buffers — 40 pad / line / pad to 120. Window at sp=40 -> chars
// 40..79 (the readable line).
//==================================================================
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
