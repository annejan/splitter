//==================================================================
// splitter — v0.3  "zig-zag wall (multi-row)"
//
// The per-pixel-row zig-zag from v0.2, now a WALL: NROWS char-rows
// stacked, each a line of text, all shearing into the same zig-zag and
// meeting together. Even pixel rows scroll LEFT (forward stream), odd
// rows scroll RIGHT (backward stream); they cross in the middle and the
// whole wall reads true for a beat.
//
// The shifter is fully unrolled (KA .for over row/pixel-row/cell) -> no
// loop overhead, just a long ROL/ROR blob. $d020 inc/dec brackets it so
// the border band shows exactly how much raster time the wall costs —
// the classic way to find the per-frame budget ceiling. Push NROWS up
// until the border band gets fat, then stop (or switch to a cheaper
// full-screen technique: $d016 per-scanline shear).
//==================================================================
.cpu _6502
.encoding "screencode_upper"

* = $0801
        .byte $0c, $08, $0a, $00, $9e, $32, $30, $36, $34, $00, $00, $00

* = $0810 "Main"

.const SCREEN     = $0400
.const BITMAP     = $2000
.const FONT       = $4000
.const NROWS      = 4              // char-rows in the wall (watch the border!)
.const BAND_TOP   = 10             // first char-row of the band
.const SCROLL_BMP = BITMAP + BAND_TOP*320
.const MSGLEN     = 80             // chars per wall line

.const fontptr    = $fb

start:
        sei
        lda #$35
        sta $01

        // copy uppercase CHARGEN -> FONT
        lda #$33
        sta $01
        ldx #0
!fc:    lda $d000,x
        sta FONT+$000,x
        lda $d100,x
        sta FONT+$100,x
        lda $d200,x
        sta FONT+$200,x
        lda $d300,x
        sta FONT+$300,x
        lda $d400,x
        sta FONT+$400,x
        lda $d500,x
        sta FONT+$500,x
        lda $d600,x
        sta FONT+$600,x
        lda $d700,x
        sta FONT+$700,x
        inx
        bne !fc-
        lda #$35
        sta $01

        // clear bitmap
        lda #$00
        ldx #0
!cb:    .for (var p=0; p<32; p++) { sta BITMAP + p*256, x }
        inx
        bne !cb-

        // colour RAM: band cells visible, rest black
        lda #$00
        ldx #0
!cs:    sta SCREEN+$000, x
        sta SCREEN+$100, x
        sta SCREEN+$200, x
        sta SCREEN+$2e8, x
        inx
        bne !cs-

        // VIC: bitmap mode
        lda #$18
        sta $d018
        lda #$3b
        sta $d011
        lda #$08
        sta $d016
        lda #$00
        sta $d020
        sta $d021

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
        inc frame
        jsr update_scroll
        jsr cycle_band_colors
        pla
        tay
        pla
        tax
        pla
        rti


//==================================================================
// update_scroll — fully-unrolled multi-row zig-zag.
//==================================================================
update_scroll:
        inc $d020                  // ## debug: budget band start ##
        .for (var r=0; r<NROWS; r++) {
            .for (var px=0; px<8; px++) {
                .var b = SCROLL_BMP + r*320 + px
                .var p = r*8 + px
                .if (floor(px/2)*2 == px) {
                    // even pixel row -> ROL (left), bit from pending_row
                    asl pending_row + p
                    .for (var i=39; i>=0; i--) { rol b + i*8 }
                } else {
                    // odd pixel row -> ROR (right), bit from pending_odd
                    lsr pending_odd + p
                    .for (var i=0; i<40; i++) { ror b + i*8 }
                }
            }
        }
        dec $d020                  // ## debug: budget band end ##

        inc smooth
        lda smooth
        cmp #8
        bne !done+
        lda #$00
        sta smooth
        jsr load_chars
!done:
        rts


//==================================================================
// load_chars — for each wall row, next forward char -> pending_row,
// next backward char -> pending_odd. Shared fwd/bwd indices, so the
// whole wall splits and meets as one.
//==================================================================
load_chars:
        .for (var r=0; r<NROWS; r++) {
            ldx fwd_idx
            lda walltext + r*MSGLEN, x
            jsr set_fontptr
            .for (var k=0; k<8; k++) {
                ldy #k
                lda (fontptr), y
                sta pending_row + r*8 + k
            }
            ldx bwd_idx
            lda walltext + r*MSGLEN, x
            jsr set_fontptr
            .for (var k=0; k<8; k++) {
                ldy #k
                lda (fontptr), y
                sta pending_odd + r*8 + k
            }
        }
        inc fwd_idx
        lda fwd_idx
        cmp #MSGLEN
        bcc !fok+
        lda #$00
        sta fwd_idx
!fok:
        dec bwd_idx
        bpl !bok+
        lda #MSGLEN-1
        sta bwd_idx
!bok:
        rts


set_fontptr:
        sta fontptr
        lda #$00
        sta fontptr+1
        asl fontptr
        rol fontptr+1
        asl fontptr
        rol fontptr+1
        asl fontptr
        rol fontptr+1
        lda fontptr
        clc
        adc #<FONT
        sta fontptr
        lda fontptr+1
        adc #>FONT
        sta fontptr+1
        rts


//==================================================================
// cycle_band_colors — rainbow drift on all NROWS band rows.
//==================================================================
cycle_band_colors:
        ldx #39
!cy:    txa
        clc
        adc frame
        and #$0f
        tay
        lda rainbow, y
        asl
        asl
        asl
        asl
        .for (var r=0; r<NROWS; r++) {
            sta SCREEN + (BAND_TOP+r)*40, x
        }
        dex
        bpl !cy-
        rts


//==================================================================
// data
//==================================================================
frame:    .byte 0
smooth:   .byte 0
fwd_idx:  .byte 0
bwd_idx:  .byte MSGLEN-1

pending_row: .fill NROWS*8, 0
pending_odd: .fill NROWS*8, 0

rainbow:
        .byte $06, $0b, $04, $0e, $03, $05, $0d, $07
        .byte $01, $07, $0d, $05, $03, $0e, $04, $0b

// NROWS wall lines, MSGLEN chars each. The meet (fwd==bwd, middle char)
// reads true — keep the middle ~20 chars a readable phrase per line.
walltext:
        .text "  SPLITTER OVER THE WHOLE SCREEN NOW    DEFEEST  "
        .text "  THE WALL SHEARS INTO A ZIG ZAG AND BACK       "
        .text "  EVEN ROWS LEFT  ODD ROWS RIGHT  THEY MEET     "
        .text "  KLOTEN MET DE BROODTROMMEL   SEE YOU AT EVOKE "
