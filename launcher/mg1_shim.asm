;==============================================================================
; mg1_shim.asm — six TAP* stubs + common shim, patched into MG1's bank 0x0F
;------------------------------------------------------------------------------
; The packager (mg1_to_yamanooto.py) writes this blob into the free 0xFF tail
; of MG1's bank F: ROM 0x1FFA7 = CPU 0xBFA7 (bank F is mapped at 0xA000-0xBFFF
; while the game's saveload code runs). Every `call TAPxx` in saveload is
; repointed at its stub. Stubs are 5 bytes each, at fixed addresses:
;     stub(fn) = 0xBFA7 + fn*5      fn: 0 TAPION 1 TAPIN 2 TAPIOF
;                                       3 TAPOON 4 TAPOUT 5 TAPOOF
; The common shim maps the driver bank (0x10) into the 0x8000 window, calls
; it with A = original input / C = fn id under DI (MG1's interrupt handler
; remaps banks 0x6000/0x8000!), then restores the window from MG1's own
; shadow and returns the driver's A + carry to the game.
;
; Build: pasmo --bin mg1_shim.asm mg1_shim.bin   (org 0xBFA7, max 89 bytes)
;==============================================================================

K4_REG_8000 equ 0x8000
BankIn80    equ 0xF0F2      ; MG1's shadow of the 0x8000 window (= 2 here)
DRIVER_BANK equ 0x10
DRIVER      equ 0x8000

    org 0xBFA7

stub_tapion:                ; 0xBFA7
    push bc
    ld   c, 0
    jr   common
stub_tapin:                 ; 0xBFAC
    push bc
    ld   c, 1
    jr   common
stub_tapiof:                ; 0xBFB1
    push bc
    ld   c, 2
    jr   common
stub_tapoon:                ; 0xBFB6
    push bc
    ld   c, 3
    jr   common
stub_tapout:                ; 0xBFBB
    push bc
    ld   c, 4
    jr   common
stub_tapoof:                ; 0xBFC0
    push bc
    ld   c, 5
    jr   common

common:                     ; 0xBFC5
    push de
    push hl
    di
    ld   b, a               ; keep the BIOS input byte
    ld   a, DRIVER_BANK
    ld   (K4_REG_8000), a   ; map the driver into window 2
    ld   a, b
    call DRIVER             ; A = input, C = fn -> returns A + carry
    push af
    ld   a, (BankIn80)
    ld   (K4_REG_8000), a   ; put MG1's bank back
    pop  af
    pop  hl
    pop  de
    pop  bc
    ei
    ret
    end
