    .include    "global.s"

    .title  "Metasprites"
    .module Metasprites

    .area	OSEG (PAG, OVR)
    ___move_metasprite_hflip_PARM_2::
    ___move_metasprite_flipy_PARM_2:: .ds 2
    ___move_metasprite_hflip_PARM_3::
    ___move_metasprite_flipy_PARM_3:: .ds 2

    .area   _HOME

.define xPos  "___move_metasprite_flipy_PARM_2"
.define yPos  "___move_metasprite_flipy_PARM_3"

; uint8_t __move_metasprite_flipy(uint8_t id, int16_t x, int16_t y)

___move_metasprite_flipy::
___move_metasprite_hflip::
    jsr .move_metasprite_prologue
___move_metasprite_flipy_loop:
    lda [*___current_metasprite],y      ; dy
    eor #0xFF
    bpl ___move_metasprite_flipy_dyNeg
    sec
    adc *yPos
    sta *yPos
    bcs 1$
    dec *yPos+1
1$:
___move_metasprite_flipy_loop_writePosY:
    sta _shadow_OAM+OAM_POS_Y,x
    lda *yPos+1
    bne ___move_metasprite_flipy_outsideY
    iny
    lda [*___current_metasprite],y      ; dx
    bmi ___move_metasprite_flipy_dxNeg
    clc
    adc *xPos
    sta *xPos
    bcc 2$
    inc *xPos+1
2$:
___move_metasprite_flipy_loop_writePosX:
    sta _shadow_OAM+OAM_POS_X,x
    lda *xPos+1
    bne ___move_metasprite_flipy_outsideX
    iny
    lda [*___current_metasprite],y      ; tile index
    iny
    clc
    adc *___current_base_tile
    sta _shadow_OAM+OAM_TILE_INDEX,x
    lda [*___current_metasprite],y      ; props
    eor #OAMF_YFLIP
    adc *___current_base_prop
    iny
    sta _shadow_OAM+OAM_ATTRIBUTES,x
    inx
    inx
    inx
    inx
    bne ___move_metasprite_flipy_loop
___move_metasprite_flipy_end:
    jmp .move_metasprite_epilogue

___move_metasprite_flipy_dxNeg:
    clc
    adc *xPos
    sta *xPos
    bcs 1$
    dec *xPos+1
1$:
    jmp ___move_metasprite_flipy_loop_writePosX

___move_metasprite_flipy_dyNeg:
    cmp #0x7F
    beq ___move_metasprite_flipy_end
    sec
    adc *yPos
    sta *yPos
    bcc 1$
    inc *yPos+1
1$:
    jmp ___move_metasprite_flipy_loop_writePosY

___move_metasprite_flipy_outsideY:
    iny
    lda [*___current_metasprite],y      ; dx
    bmi ___move_metasprite_flipy_outsideY_dxNeg
    clc
    adc *xPos
    sta *xPos
    bcc ___move_metasprite_flipy_outsideX
    inc *xPos+1
___move_metasprite_flipy_outsideX:
    iny
    ; Skip tile index / props
    iny
    iny
    lda #0xF0
    sta _shadow_OAM+OAM_POS_Y,x
    jmp ___move_metasprite_flipy_loop

___move_metasprite_flipy_outsideY_dxNeg:
    clc
    adc *xPos
    sta *xPos
    bcs 1$
    dec *xPos+1
1$:
    jmp ___move_metasprite_flipy_outsideX
