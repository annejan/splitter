//==================================================================
// splitter — v0.2  "per-pixel-row zig-zag split"
//
// THE effect: one bitmap scroller, but its 8 pixel rows are split —
// EVEN pixel rows scroll LEFT, ODD pixel rows scroll RIGHT. A forward
// text stream feeds the even rows, a backward stream the odd rows, so
// the wall of text shears into a fine zig-zag and resolves into one
// readable line when the two streams cross in the middle. (The trick
// from the x2026 intro, isolated.)
//
// Per pixel row x (0..7): a 40-cell ROL chain (left) or ROR chain
// (right), new bit fed from pending_row[x] / pending_odd[x]. Every 8
// sub-pixel steps a fresh char is loaded into the pending buffers.
//
// $d020 is used the classic way: inc at the top of the shifter, dec at
// the bottom — the border band shows exactly how much raster time the
// zig-zag eats. Standalone PRG, BASIC stub SYS 2064 -> $0810.
//==================================================================
.cpu _6502
.encoding "screencode_upper"

* = $0801
        .byte $0c, $08, $0a, $00, $9e, $32, $30, $36, $34, $00, $00, $00

* = $0810 "Main"

.const SCREEN     = $0400          // bitmap colour RAM (hi nibble = fg)
.const BITMAP     = $2000
.const FONT       = $4000          // uppercase CHARGEN copied here
.const SCROLL_ROW = 12             // char-row of the scroller band
.const SCROLL_BMP = BITMAP + SCROLL_ROW*320   // $2F00
.const SCREEN_ROW = SCREEN + SCROLL_ROW*40    // $04E0 (band's colour cells)

.const fontptr    = $fb            // ZP 16-bit glyph pointer
.const MSGLEN     = 80             // message length (4 rows x 20 chars)

start:
        sei
        lda #$35
        sta $01

        // --- copy uppercase CHARGEN ($D000 with $01=$33) to FONT ---
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

        // --- clear bitmap $2000-$3FFF to 0 ---
        lda #$00
        ldx #0
!cb:    .for (var p=0; p<32; p++) {
            sta BITMAP + p*256, x
        }
        inx
        bne !cb-

        // --- colour RAM: band cells visible (white fg), rest black ---
        lda #$00
        ldx #0
!cs:    sta SCREEN+$000, x
        sta SCREEN+$100, x
        sta SCREEN+$200, x
        sta SCREEN+$2e8, x
        inx
        bne !cs-
        ldx #39
        lda #$10                   // hi nibble = white fg, lo = black bg
!cband: sta SCREEN_ROW, x
        dex
        bpl !cband-

        // --- VIC: bitmap mode, screen $0400, bitmap $2000 ---
        lda #$18
        sta $d018                  // VM=$0400, bitmap base $2000
        lda #$3b
        sta $d011                  // BMM + DEN + 25 rows + yscroll 3
        lda #$08
        sta $d016                  // hires, 40 cols
        lda #$00
        sta $d020
        sta $d021

        // --- raster IRQ ---
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


//==================================================================
// raster IRQ
//==================================================================
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
// update_scroll — the zig-zag shifter. Even pixel rows ROL (left),
// odd ROR (right). $d020 brackets show the raster cost (debug).
//==================================================================
update_scroll:
        inc $d020                  // ## debug: routine start ##
        ldx #0
!rowloop:
        txa
        and #$01
        bne !odd+
        // even pixel row -> shift LEFT, new bit from pending_row[x] bit7
        asl pending_row, x
        .for (var i=39; i>=0; i--) {
            rol SCROLL_BMP + i*8, x
        }
        jmp !next+
!odd:
        // odd pixel row -> shift RIGHT, new bit from pending_odd[x] bit0
        lsr pending_odd, x
        .for (var i=0; i<40; i++) {
            ror SCROLL_BMP + i*8, x
        }
!next:
        inx
        cpx #8
        beq !rldone+
        jmp !rowloop-
!rldone:
        dec $d020                  // ## debug: routine end ##

        // advance sub-pixel; every 8 steps load the next chars
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
// load_chars — pull the next forward char into pending_row and the
// next backward char into pending_odd. fwd walks +1, bwd walks -1;
// they cross in the middle (the "meet" where the zig-zag reads true).
//==================================================================
load_chars:
        ldx fwd_idx
        lda message, x
        jsr set_fontptr
        ldy #7
!lf:    lda (fontptr), y
        sta pending_row, y
        dey
        bpl !lf-
        inc fwd_idx
        lda fwd_idx
        cmp #MSGLEN
        bcc !fok+
        lda #$00
        sta fwd_idx
!fok:
        ldx bwd_idx
        lda message, x
        jsr set_fontptr
        ldy #7
!lb:    lda (fontptr), y
        sta pending_odd, y
        dey
        bpl !lb-
        dec bwd_idx
        bpl !bok+
        lda #MSGLEN-1
        sta bwd_idx
!bok:
        rts


//==================================================================
// set_fontptr — fontptr = FONT + (A * 8)
//==================================================================
set_fontptr:
        sta fontptr                // A = char (0..255), low for now
        lda #$00
        sta fontptr+1
        asl fontptr
        rol fontptr+1
        asl fontptr
        rol fontptr+1
        asl fontptr
        rol fontptr+1              // fontptr = char*8
        lda fontptr
        clc
        adc #<FONT
        sta fontptr
        lda fontptr+1
        adc #>FONT
        sta fontptr+1
        rts


//==================================================================
// cycle_band_colors — drift the band's per-cell fg colour each frame
// for the "impossible hues" shimmer.
//==================================================================
cycle_band_colors:
        ldx #39
!cy:    txa
        clc
        adc frame
        and #$0f
        tay
        lda rainbow, y
        asl                        // colour -> hi nibble (fg)
        asl
        asl
        asl
        sta SCREEN_ROW, x
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

pending_row: .fill 8, 0
pending_odd: .fill 8, 0

rainbow:
        .byte $06, $0b, $04, $0e, $03, $05, $0d, $07
        .byte $01, $07, $0d, $05, $03, $0e, $04, $0b

// fwd walks forward from char 0, bwd backward from the last char; they
// meet at the MIDDLE char -> put the readable punchline there.
message:
        .text "SPLITTER  DEFEEST   "           // 0..19
        .text "WALL OF TEXT MEETS  "           // 20..39
        .text "SEE YOU AT EVOKE    "           // 40..59   (middle ~= meet)
        .text "KLOTEN MET DE BROOD "           // 60..79
msg_end:                                       // MSGLEN = 80 (const, top)
