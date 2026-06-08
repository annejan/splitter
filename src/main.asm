//==================================================================
// splitter — v0.1  "the wall splits and meets again"
//
// A char-mode demo seed: two text rows show the SAME message but scan
// it in OPPOSITE directions, so the wall of text drifts apart and then
// resolves back into one readable line at the meet point — the split /
// reunion that was the nicest effect in the x2026 intro, isolated here
// as the thing we build the whole demo around.
//
// Colours drift through a 16-entry rainbow every frame (per-char, both
// rows) for the "impossible hues" shimmer, with a slow border cycle.
//
// Standalone PRG: BASIC stub SYS 2064 -> $0810. Raster-IRQ driven.
// KERNAL/BASIC banked out ($01=$35); IRQ vector lives in RAM at $FFFE.
//==================================================================
.cpu _6502
.encoding "screencode_upper"      // A..Z -> $01..$1A, space $20

//------------------------------------------------------------------
// BASIC stub:  10 SYS 2064
//------------------------------------------------------------------
* = $0801
        .byte $0c, $08, $0a, $00, $9e, $32, $30, $36, $34, $00, $00, $00

//------------------------------------------------------------------
* = $0810 "Main"

.const SCREEN  = $0400
.const COLOR   = $d800
.const ROW_T   = SCREEN + 11*40    // top scroller  ($05B8)
.const ROW_B   = SCREEN + 13*40    // bottom scroller ($0608)
.const CROW_T  = COLOR  + 11*40
.const CROW_B  = COLOR  + 13*40

.const STEP_FRAMES = 3             // advance the scan every N frames

// zero-page scratch (KERNAL is out, so all of ZP is ours)
.const srcT = $fb                  // 16-bit src ptr, top row
.const srcB = $fd                  // 16-bit src ptr, bottom row

start:
        sei
        lda #$35
        sta $01                    // I/O + RAM, no KERNAL/BASIC ROM

        // VIC: bank 0, screen $0400, uppercase char ROM at $1000
        lda #$14
        sta $d018
        lda #$1b
        sta $d011                  // text mode, 25 rows, DEN, yscroll 3
        lda #$08
        sta $d016                  // 40 cols
        lda #$00
        sta $d020
        sta $d021

        // clear screen -> spaces, colour -> black
        ldx #0
        lda #$20
!cl:    sta SCREEN+$000,x
        sta SCREEN+$100,x
        sta SCREEN+$200,x
        sta SCREEN+$2e8,x
        inx
        bne !cl-
        ldx #0
        lda #$00
!cc:    sta COLOR+$000,x
        sta COLOR+$100,x
        sta COLOR+$200,x
        sta COLOR+$2e8,x
        inx
        bne !cc-

        // install raster IRQ at line 0
        lda #<irq
        sta $fffe
        lda #>irq
        sta $ffff
        lda #$7f
        sta $dc0d                  // CIA1 timer IRQs off
        sta $dd0d                  // CIA2 too
        lda $dc0d                  // ack pending CIA IRQs
        lda $dd0d
        lda #$01
        sta $d01a                  // enable raster IRQ
        lda #$00
        sta $d012
        lda $d011
        and #$7f
        sta $d011                  // clear raster MSB
        lda #$ff
        sta $d019                  // ack
        cli

!loop:  jmp !loop-                 // everything happens in the IRQ


//==================================================================
// raster IRQ — once per frame
//==================================================================
irq:
        pha
        txa
        pha
        tya
        pha
        lda #$ff
        sta $d019                  // ack raster IRQ

        inc frame

        dec stepctr
        bne !nostep+
        lda #STEP_FRAMES
        sta stepctr
        jsr advance_split
!nostep:
        jsr paint_colors

        lda frame                  // slow border drift
        lsr
        lsr
        lsr
        and #$0f
        sta $d020

        pla
        tay
        pla
        tax
        pla
        rti


//==================================================================
// data
//==================================================================
frame:    .byte 0
stepctr:  .byte STEP_FRAMES
splitK:   .byte 0

// 16-entry rainbow (C64 palette indices), smooth-ish hue walk.
rainbow:
        .byte $06, $0b, $04, $0e, $03, $05, $0d, $07
        .byte $01, $07, $0d, $05, $03, $0e, $04, $0b

// The wall of text. Two 40-col windows scan this in opposite
// directions; tune the wording so the MIDDLE 40 chars (the meet) land
// a punchline. Keep >= 40 + a healthy scan range of trailing slack.
message:
        .text "      SPLITTER      "
        .text "TWO HALVES OF ONE WALL DRIFT APART      "
        .text "      AND MEET AGAIN AS A SINGLE LINE      "    // <- the meet
        .text "DEFEEST WAS HERE   KLOTEN MET DE BROODTROMMEL      "
        .text "SEE YOU AT EVOKE          "
msg_end:

.const MSGLEN     = msg_end - message
.const SCAN_RANGE = MSGLEN - 40        // K walks 0 .. SCAN_RANGE-1


//==================================================================
// advance_split — step the scan, repaint both row windows.
//   top row shows   message[K .. K+39]            (scrolls left)
//   bottom row shows message[(RANGE-1-K) .. +39]  (scrolls right)
// They coincide at K = (RANGE-1)/2 -> the wall meets as one line.
//==================================================================
advance_split:
        inc splitK
        lda splitK
        cmp #SCAN_RANGE
        bcc !ok+
        lda #0
        sta splitK
!ok:
        // srcT = message + K
        lda #<message
        clc
        adc splitK
        sta srcT
        lda #>message
        adc #0
        sta srcT+1

        // srcB = message + (RANGE-1 - K)
        lda #(SCAN_RANGE-1)
        sec
        sbc splitK
        clc
        adc #<message
        sta srcB
        lda #>message
        adc #0
        sta srcB+1

        ldy #39
!cp:    lda (srcT),y
        sta ROW_T,y
        lda (srcB),y
        sta ROW_B,y
        dey
        bpl !cp-
        rts


//==================================================================
// paint_colors — per-char rainbow that drifts a column each frame,
// same ramp on both rows so the meet reads as one band.
//==================================================================
paint_colors:
        ldy #39
!pc:    tya
        clc
        adc frame
        and #$0f
        tax
        lda rainbow,x
        sta CROW_T,y
        sta CROW_B,y
        dey
        bpl !pc-
        rts
