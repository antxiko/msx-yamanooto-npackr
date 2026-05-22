#!/usr/bin/env python3
"""
ascii16_to_k5.py — Convert an ASCII16 MSX ROM to Konami-SCC (K5) mapper.

ASCII16 has 2 switchable 16KB segments and writes a single bank value to
either 0x6000-0x67FF (segment 0 = 0x4000-0x7FFF) or 0x7000-0x77FF
(segment 1 = 0x8000-0xBFFF).

K5 has 4 switchable 8KB segments and writes happen at 0x5000, 0x7000,
0x9000, 0xB000 (one per segment).

A single ASCII16 bank write must become two K5 bank writes (one for each
half of the 16KB segment). Since we can't expand a 3-byte instruction
into multiple instructions without rebuilding the binary, we replace each
"LD (nn),A" with a "CALL helper" to a small routine in RAM:

    helper_seg0 at 0xF000:    ; called for original LD (0x6000-0x67FF), A
        add a, a              ; double the bank value
        ld (0x5000), a        ; K5 bank 0
        inc a
        ld (0x7000), a        ; K5 bank 1
        ret

    helper_seg1 at 0xF010:    ; called for original LD (0x7000-0x77FF), A
        add a, a
        ld (0x9000), a        ; K5 bank 2
        inc a
        ld (0xB000), a        ; K5 bank 3
        ret

The launcher installs these helpers at 0xF000-0xF018 in RAM before
jumping to the game, but ONLY if the directory entry has the
FLAG_ASCII16 bit set. Pack with mapper="ascii16_k5" in the TOML.

Limitations:
- Only catches "LD (nn),A" pattern (opcode 0x32). Code that uses
  LD HL,addr / LD (HL),A or pushes addresses around won't be patched.
- False positives possible (a coincidental 32 xx 6X byte sequence in
  data). For game ROMs without big data tables this is rare.

Usage:
  ascii16_to_k5.py in.rom out.rom
"""

import sys
from pathlib import Path


def convert(rom: bytes) -> tuple[bytes, int, int]:
    """Returns (patched_rom, seg0_patches, seg1_patches)."""
    out = bytearray(rom)
    seg0 = 0
    seg1 = 0
    i = 0
    while i < len(out) - 2:
        if out[i] == 0x32:                       # LD (nn), A
            hi = out[i + 2]
            if 0x60 <= hi < 0x68:                # ASCII16 segment 0
                out[i] = 0xCD                    # CALL nn
                out[i + 1] = 0x00
                out[i + 2] = 0xF0                # -> 0xF000
                seg0 += 1
            elif 0x70 <= hi < 0x78:              # ASCII16 segment 1
                out[i] = 0xCD
                out[i + 1] = 0x10
                out[i + 2] = 0xF0                # -> 0xF010
                seg1 += 1
        i += 1
    return bytes(out), seg0, seg1


def main():
    if len(sys.argv) != 3:
        print("Usage: ascii16_to_k5.py in.rom out.rom", file=sys.stderr)
        sys.exit(1)
    src = Path(sys.argv[1]).read_bytes()
    dst, seg0, seg1 = convert(src)
    Path(sys.argv[2]).write_bytes(dst)
    print(f"Patched {seg0 + seg1} bank-switch instructions "
          f"(seg0=0x6000->CALL 0xF000: {seg0}, seg1=0x7000->CALL 0xF010: {seg1})")
    print("Pack with `mapper = \"ascii16_k5\"` so the launcher installs the helper.")


if __name__ == "__main__":
    main()
