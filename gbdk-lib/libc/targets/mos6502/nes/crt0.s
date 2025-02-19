;
; crt0.s for NES, using UNROM-512 (mapper30) with single-screen mirroring variant
;
; Provides:
;  * Start-up code clearing RAM and VRAM
;  * Constant-cycle-time NMI handler, performing sprite DMA and VRAM writes via transfer buffer at $100
;  * 16-bit frame counter _sys_time, to support VM routines
.module crt0
.include    "global.s"

; OAM CPU page
_shadow_OAM             = 0x200
; Attribute shadow (64 bytes, leaving 56 bytes available for CPU stack)
_attribute_shadow       = 0x188

; Declare a dummy symbol for banking
; TODO: Make banking actually work
b_wait_frames = 0
.globl b_wait_frames

.macro WRITE_PALETTE_SHADOW
    lda #>0x3F00
    sta PPUADDR
    lda #<0x3F00
    sta PPUADDR
    ldx *__crt0_paletteShadow
    i = 0
.rept 8
    stx PPUDATA
    lda *(__crt0_paletteShadow+1+3*i+0)
    sta PPUDATA
    lda *(__crt0_paletteShadow+1+3*i+1)
    sta PPUDATA
    lda *(__crt0_paletteShadow+1+3*i+2)
    sta PPUDATA
    i = i + 1
.endm
.endm

       ;; ****************************************

        ;; Ordering of segments for the linker
        ;; Code that really needs to be in the fixed bank
        .area _CODE
        .area _HOME
        ;; Similar to _HOME
        .area _BASE
        ;; Constant data
        .area _LIT
        ;; Constant data, used to init _DATA
        .area _INITIALIZER
        .area _XINIT
        ;; Code, used to init _DATA
        .area _GSINIT 
        .area _GSFINAL
        ;; Uninitialised ram data
        .area _DATA
        .area _BSS
        ;; Initialised in ram data
        .area _INITIALIZED
        ;; For malloc
        .area _HEAP
        .area _HEAP_END

.area	OSEG    (PAG, OVR)
.area _ZP (PAG)
__shadow_OAM_base::                     .ds 1
__current_bank::                        .ds 1
_sys_time::                             .ds 2
_shadow_PPUCTRL::                       .ds 1
_shadow_PPUMASK::                       .ds 1
__crt0_paletteShadow::                  .ds 25
__crt0_spritePageValid:                 .ds 1
__crt0_NMI_Done:                        .ds 1
__crt0_NMI_insideNMI:                   .ds 1
__crt0_ScrollHV:                        .ds 1
__crt0_NMITEMP:                         .ds 4
.mode::                                 .ds 1
.tmp::                                  .ds 2
_bkg_scroll_x::                         .ds 1
_bkg_scroll_y::                         .ds 1
_attribute_row_dirty::                  .ds 1
_attribute_column_dirty::               .ds 1
.crt0_forced_blanking::                 .ds 1
.tempA::                                .ds 1

.area _CODE

.bndry 0x100
.identity::
_identity::
i = 0
.rept 256
.db i
i = i + 1
.endm

__crt0_NMI:
    ; Prevent NMI re-entry
    bit *__crt0_NMI_insideNMI
    bpl NotInsideNMI
    rti
NotInsideNMI:
    pha
    txa
    pha
    tya
    pha

    lda #0x80
    sta *__crt0_NMI_insideNMI

    jsr __crt0_doSpriteDMA
    jsr __crt0_NMI_doUpdateVRAM

    nop
    ; Enable screen to get normal dot crawl pattern
    lda *_shadow_PPUMASK
    sta PPUMASK

    lda *_sys_time
    clc
    adc #1
    sta *_sys_time
    lda *(_sys_time+1)
    adc #0
    sta *(_sys_time+1)

    lda #0x80
    sta __crt0_NMI_Done
    
    lda *_shadow_PPUCTRL
    ora *__crt0_ScrollHV
    sta PPUCTRL

    pla
    tay
    pla
    tax
    pla
    asl *__crt0_NMI_insideNMI
    rti

__crt0_NMI_doUpdateVRAM:
    lda *_shadow_PPUMASK
    and #(PPUMASK_SHOW_BG | PPUMASK_SHOW_SPR)
    beq __crt0_NMI_doUpdateVRAM_blanked
    ; Not manually blanked - do updates
    lda PPUSTATUS
    lda #PPUCTRL_SPR_CHR
    sta PPUCTRL
    lda #0
    sta PPUMASK
    jsr DoUpdateVRAM
    ; Set scroll address
    lda _bkg_scroll_x
    sta PPUSCROLL
    lda _bkg_scroll_y
    sta PPUSCROLL
    rts
__crt0_NMI_doUpdateVRAM_blanked:
    ; Early-out if blanked to allow main code to do VRAM address / scroll updates
    nop
    nop
    nop
    rts

.bndry 0x100
__crt0_doSpriteDMA:
    bit *__crt0_spritePageValid
    bpl __crt0_doSpriteDMA_spritePageInvalid
    lda #0                      ; +2
    sta OAMADDR                 ; +4
    lda #>_shadow_OAM           ; +2
    sta OAMDMA                  ; +512/513
    rts
__crt0_doSpriteDMA_spritePageInvalid:
    ; Delay 520 cycles to keep timing consistent
    ldx #104
__crt0_doSpriteDMA_loop:
    dex
    bne __crt0_doSpriteDMA_loop
    rts

DoUpdateVRAM:
    WRITE_PALETTE_SHADOW
    bit *__vram_transfer_buffer_valid
    bmi DoUpdateVRAM_drawListValid
DoUpdateVRAM_drawListInvalid:
    ; Delay exactly 1633 cycles to keep timing consistent
    ldx #(VRAM_DELAY_CYCLES_X8+7)
DoUpdateVRAM_invalid_loop:
    lda *__vram_transfer_buffer_num_cycles_x8
    dex
    bne DoUpdateVRAM_invalid_loop
    nop
    rts
DoUpdateVRAM_drawListValid:
    jsr ProcessDrawList
    ; Delay up to 167*8-1 = 1575 cycles (value set by draw list creation code)
    ; ...plus fixed-cost of 56 cycles
    ldx *__vram_transfer_buffer_num_cycles_x8
DoUpdateVRAM_valid_loop:
    stx *__vram_transfer_buffer_num_cycles_x8
    dex
    bne DoUpdateVRAM_valid_loop
    lda #VRAM_DELAY_CYCLES_X8
    sta *__vram_transfer_buffer_num_cycles_x8
    rts

;
; Number of cycles spent = 19 + 21 + 48*NumTransfers + 8*NumBytesTransferred
;                        = 56 + 48*NumTransfers + 8*NumBytesTransferred
;                        = 8 * (7 + 6*NumTransfers + NumBytesTransferred)
;                        = 8 * (6*NumTransfers + NumBytesTransferred + 7)
;
ProcessDrawList:
    ProcessDrawList_tempX  = __crt0_NMITEMP+2
    ProcessDrawList_addr   = __crt0_NMITEMP+0
    lda #>ProcessDrawList_UnrolledCopyLoop  ; +2
    sta *ProcessDrawList_addr+1             ; +3
    tsx                                     ; +2
    stx *ProcessDrawList_tempX              ; +3
    ldx #0xFF                               ; +2
    txs                                     ; +2
    jmp ProcessDrawList_DoOneTransfer       ; +3
    ; Total = 2 + 3 + 2 + 3 + 2 + 2 + 3 = 17 fixed-cost entry

.bndry 0x100
ProcessDrawList_UnrolledCopyLoop:
.rept 64
pla             ; +4
sta PPUDATA     ; +4
.endm
ProcessDrawList_DoOneTransfer:
    pla                                         ; +4
    beq ProcessDrawList_EndOfList               ; +2/3
    tay                                         ; +2
    ; branchaddr = 256-4*num_bytes = NOT(4*num_bytes)+1+256 = NOT(4*num_bytes)+1
    lda ProcessDrawList_NumBytesToAddress,y     ; +4
    sta *ProcessDrawList_addr                   ; +3
    pla                                         ; +4
    sta PPUCTRL                                 ; +4
    pla                                         ; +4
    sta PPUADDR                                 ; +4
    pla                                         ; +4
    sta PPUADDR                                 ; +4
    nop                                         ; +2
    nop                                         ; +2
    jmp [ProcessDrawList_addr]                  ; +5
    ; Total = 4 + 2 + 2 + 4 + 3 + 6*4 + 2 + 2 + 5 = 48 for each transfer (...+ 8*NumBytesCopied)
    ;         4 + 3 + 14 = 7 + 14 = 21 fixed-cost exit

ProcessDrawList_EndOfList:
    ldx *ProcessDrawList_tempX          ; +3
    txs                                 ; +2
    lda #0                              ; +2
    sta *__vram_transfer_buffer_pos_w   ; +3
    sta *__vram_transfer_buffer_valid   ; +3
    rts                                 ; +6
    ; = 3 + 2 + 2 + 3 + 3 + 6 = 19

.bndry 0x100
ProcessDrawList_NumBytesToAddress:
i = 0
.rept 65
.db <(256-4*i)
i = i + 1
.endm

__crt0_IRQ:
    jmp __crt0_IRQ

__crt0_setPalette:
    ; Set background color to 30 (white)
    lda #0x30
    sta *__crt0_paletteShadow
    ; set all background / sprite sub-palettes to 10, 00, 1D
    lda #0x10
    ldx #0x00
    ldy #0x1D
    ;
    sta *(__crt0_paletteShadow+1)
    sta *(__crt0_paletteShadow+1+12)
    stx *(__crt0_paletteShadow+2)
    stx *(__crt0_paletteShadow+2+12)
    sty *(__crt0_paletteShadow+3)
    sty *(__crt0_paletteShadow+3+12)
    ;
    sta *(__crt0_paletteShadow+4)
    sta *(__crt0_paletteShadow+4+12)
    stx *(__crt0_paletteShadow+5)
    stx *(__crt0_paletteShadow+5+12)
    sty *(__crt0_paletteShadow+6)
    sty *(__crt0_paletteShadow+6+12)
    ;
    sta *(__crt0_paletteShadow+7)
    sta *(__crt0_paletteShadow+7+12)
    stx *(__crt0_paletteShadow+8)
    stx *(__crt0_paletteShadow+8+12)
    sty *(__crt0_paletteShadow+9)
    sty *(__crt0_paletteShadow+9+12)
    ;
    sta *(__crt0_paletteShadow+10)
    sta *(__crt0_paletteShadow+10+12)
    stx *(__crt0_paletteShadow+11)
    stx *(__crt0_paletteShadow+11+12)
    sty *(__crt0_paletteShadow+12)
    sty *(__crt0_paletteShadow+12+12)
    rts

__crt0_waitPPU:
__crt0_waitPPU_loop:
    lda PPUSTATUS
    bpl __crt0_waitPPU_loop
    rts

__crt0_clearRAM:
    ldx #0x00
    txa
__crt0_clearRAM_loop:
    sta 0x0000,x
    ;sta 0x0100,x
    sta 0x0200,x
    sta 0x0300,x
    sta 0x0400,x
    sta 0x0500,x
    sta 0x0600,x
    sta 0x0700,x
    inx
    bne __crt0_clearRAM_loop
    rts

__crt0_clearVRAM:
    lda #0x00
    sta PPUADDR
    sta PPUADDR
    ldy #64
    ldx #0
__crt0_clearVRAM_loop:
    sta PPUDATA
    dex
    bne __crt0_clearVRAM_loop
    dey
    bne __crt0_clearVRAM_loop
    rts

.wait_vbl_done::
_wait_vbl_done::
_vsync::
    lda *_sys_time
_wait_vbl_done_waitForNextFrame_loop:
    cmp *_sys_time
    beq _wait_vbl_done_waitForNextFrame_loop
    rts

__crt0_RESET:
    ; Disable IRQs
    sei
    ; Set stack pointer
    ldx #0xff
    txs
    ; Set switchable bank to first
__crt0_RESET_bankSwitchValue:
    lda #0x00
    sta __crt0_RESET_bankSwitchValue+1
    ; Disable NMIs and rendering
    sta PPUCTRL
    sta PPUMASK
    ; Wait for PPU warm-up
    jsr __crt0_waitPPU
    jsr __crt0_waitPPU
    ; Clear RAM and VRAM
    jsr __crt0_clearRAM
    jsr __crt0_clearVRAM
    ; Hide sprites in shadow OAM, and perform OAM DMA
    ldx #0
    txa
    jsr _hide_sprites_range
    stx OAMADDR
    lda #>_shadow_OAM
    sta OAMDMA
    ; Perform initialization of DATA area
    lda #<s__XINIT
    sta ___memcpy_PARM_2
    lda #>s__XINIT
    sta ___memcpy_PARM_2+1
    lda #<l__XINIT
    sta ___memcpy_PARM_3
    lda #>l__XINIT
    sta ___memcpy_PARM_3+1
    lda #<s__DATA
    ldx #>s__DATA
    jsr ___memcpy
    ; Set bank to first
    lda #0x00
    sta *__current_bank
    ; Set palette shadow
    jsr __crt0_setPalette
    lda #VRAM_DELAY_CYCLES_X8
    sta *__vram_transfer_buffer_num_cycles_x8
    lda #0
    sta *__vram_transfer_buffer_pos_w
    ; 
    lda #(PPUMASK_SHOW_BG | PPUMASK_SHOW_SPR | PPUMASK_SHOW_BG_LC | PPUMASK_SHOW_SPR_LC)
    sta *_shadow_PPUMASK
    lda #0x80
    sta *__crt0_spritePageValid
    ; enable NMI
    lda #(PPUCTRL_NMI | PPUCTRL_SPR_CHR)
    sta *_shadow_PPUCTRL
    sta PPUCTRL
    ; Call main
    jsr _main
    ; main finished - loop forever
__crt0_waitForever:
    jmp __crt0_waitForever

.display_off::
_display_off::
    lda *_shadow_PPUMASK
    and #~(PPUMASK_SHOW_BG | PPUMASK_SHOW_SPR)
    sta *_shadow_PPUMASK
    sta PPUMASK
    ; Set forced blanking bit
    sec
    ror *.crt0_forced_blanking
    rts

.display_on::
_display_on::
    lda *_shadow_PPUMASK
    ora #(PPUMASK_SHOW_BG | PPUMASK_SHOW_SPR)
    sta *_shadow_PPUMASK
    sta PPUMASK
    ; Clear forced blanking bit
    clc
    ror *.crt0_forced_blanking
    rts

; Interrupt / RESET vector table
.area VECTORS (ABS)
.org 0xfffa
.dw	__crt0_NMI
.dw	__crt0_RESET
.dw	__crt0_IRQ
