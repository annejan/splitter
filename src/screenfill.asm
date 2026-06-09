// screenfill.asm — DEFEEST radial bloom + water ripple intro
//
// Packed via .pseudopc $c000 in main.asm, copied to $c000 at startup.
// Entry: init VIC, fill char_table, install IRQ, return
// IRQ:   radial fill -> water ripple -> set $cffe=$ff when done
//
// Ported from x2026-kloten/parts/screenfill/ by Augurk & de Zuursectie
//
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
        bne irq_done
        lda #$06
        sta $d020
        jmp irq_done

do_ripple:
        lda $06
        beq irq_done

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
