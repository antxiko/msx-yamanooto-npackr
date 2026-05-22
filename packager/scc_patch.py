#!/usr/bin/env python3
"""
scc_patch.py — Patch a Konami SCC (K5) ROM so it works on the Yamanooto
WITHOUT the 4x mirror trick.

Background
----------
Konami SCC games enable the SCC sound chip by writing a value whose low 6
bits are `111111` (0x3F, 0x7F, 0xBF, or 0xFF) to the bank-2 register at
0x9000-0x97FF. The same write also switches segment 2 to bank value 0x3F.
On a real Konami cart the bank value is masked to the ROM's bank count
(0x3F & 0xF = 15 for a 128K cart -> "the last bank, which is the music
driver"). The Yamanooto does NOT mask, so 0x3F lands far past the game
data unless we either mirror the ROM 4x (wasteful) or patch the writes
to redirect them.

This patcher does the latter. It rewrites the 3-byte `LD (0x9LL),A`
following `LD A,<scc-enable-value>` into a 3-byte `CALL scc_helper`. The
helper (installed by the launcher at a fixed RAM address) does the bank
write while temporarily compensating the cart's OFFR register so that the
written 0x3F lands on the game's actual last bank.

Pattern matched (5 bytes):
    3E XX 32 LL HH
where:
    XX in {0x3F, 0x7F, 0xBF, 0xFF}        (SCC-enable values)
    HH in {0x90, 0x91, ... 0x97}          (K5 bank-2 switch range)
    LL is free

Patch: the last 3 bytes (32 LL HH) become CD lo hi (CALL to the helper).
`3E XX` stays so A still arrives at the helper with the SCC-enable value.

Limitations
-----------
- Only catches `LD A, imm; LD (addr), A` immediate-value pattern. Games
  that load the value via LD HL/IX/IY or via OR/AND ops are missed.
- A false positive (a `3E XX 32 LL 9X` sequence in data, not code) would
  corrupt the ROM. The pattern is 5 bytes specific so collisions are rare
  but possible.
- The packager falls back to the 4x mirror if no patches are found.

Usage
-----
    scc_patch.py in.rom out.rom            # write patched ROM
    scc_patch.py --count in.rom            # only count, no output
"""

import sys
from pathlib import Path

SCC_HELPER_ADDR = 0xF020   # must match SCC_HELPER_DST in launcher.asm

SCC_ENABLE_VALUES = (0x3F, 0x7F, 0xBF, 0xFF)


def convert(rom: bytes, helper_addr: int = SCC_HELPER_ADDR) -> tuple[bytes, int]:
    """Patch the ROM in memory. Returns (new_rom_bytes, num_patches)."""
    out = bytearray(rom)
    helper_lo = helper_addr & 0xFF
    helper_hi = (helper_addr >> 8) & 0xFF
    n = 0
    i = 0
    end = len(out) - 4
    while i < end:
        # LD A, imm => 3E XX
        if out[i] == 0x3E and out[i + 1] in SCC_ENABLE_VALUES:
            # followed by LD (nn), A => 32 LL HH
            if out[i + 2] == 0x32 and 0x90 <= out[i + 4] <= 0x97:
                out[i + 2] = 0xCD          # CALL nn
                out[i + 3] = helper_lo
                out[i + 4] = helper_hi
                n += 1
                i += 5
                continue
        i += 1
    return bytes(out), n


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__, file=sys.stderr)
        sys.exit(1)

    if sys.argv[1] == "--count":
        for path in sys.argv[2:]:
            data = Path(path).read_bytes()
            _, n = convert(data)
            print(f"  {n:>4} patches  {path}")
        return

    if len(sys.argv) != 3:
        print("Usage: scc_patch.py in.rom out.rom  (or  --count rom...)",
              file=sys.stderr)
        sys.exit(1)

    src = Path(sys.argv[1]).read_bytes()
    dst, n = convert(src)
    Path(sys.argv[2]).write_bytes(dst)
    print(f"Patched {n} SCC-enable instruction(s) "
          f"(LD A,0x3F/7F/BF/FF + LD (0x9LL),A -> CALL 0x{SCC_HELPER_ADDR:04X})")
    if n == 0:
        print("WARNING: no patches applied. ROM may use indirect addressing "
              "for SCC enable; fall back to mirror in the packager.",
              file=sys.stderr)


if __name__ == "__main__":
    main()
