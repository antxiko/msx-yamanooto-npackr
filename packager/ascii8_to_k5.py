#!/usr/bin/env python3
"""
ascii8_to_k5.py — Convert an ASCII8 MSX ROM to Konami-SCC (K5) mapper.

Both mappers use 8KB pages with 4 switchable segments at 0x4000-0xBFFF.
Only the bank-switch *addresses* differ. We rewrite every `LD (nn),A`
opcode whose destination falls in the ASCII8 switch zone:

  ASCII8 zone        ASCII8 segment   K5 switch address
  0x6000-0x67FF      0 (0x4000)       0x5000
  0x6800-0x6FFF      1 (0x6000)       0x7000
  0x7000-0x77FF      2 (0x8000)       0x9000
  0x7800-0x7FFF      3 (0xA000)       0xB000

We only touch the address bytes; the `32` opcode stays. Constant addresses
loaded into HL/IX/IY are NOT detected — most Konami-style games don't use
those for bank switching, but if conversion fails this is the first place
to look.

Usage:
  ascii8_to_k5.py in.rom out.rom
"""

import sys
from pathlib import Path

ASCII8_TO_K5_HI = {
    # ASCII8 high byte range -> K5 high byte
    # Range is [start, end) on the high byte. Mapping touches the high byte
    # only; the low byte is forced to 0x00 to land cleanly in the K5 switch
    # sub-range [n000, n7FF].
    (0x60, 0x68): 0x50,   # segment 0
    (0x68, 0x70): 0x70,   # segment 1
    (0x70, 0x78): 0x90,   # segment 2
    (0x78, 0x80): 0xB0,   # segment 3
}


def map_address(hi: int) -> int | None:
    for (start, end), new_hi in ASCII8_TO_K5_HI.items():
        if start <= hi < end:
            return new_hi
    return None


def convert(rom: bytes) -> tuple[bytes, list]:
    out = bytearray(rom)
    patches = []
    i = 0
    while i < len(out) - 2:
        if out[i] == 0x32:                  # LD (nn), A
            lo = out[i + 1]
            hi = out[i + 2]
            new_hi = map_address(hi)
            if new_hi is not None:
                old_addr = (hi << 8) | lo
                new_addr = (new_hi << 8) | 0x00
                out[i + 1] = 0x00
                out[i + 2] = new_hi
                patches.append((i, old_addr, new_addr))
        i += 1
    return bytes(out), patches


def main():
    if len(sys.argv) != 3:
        print("Usage: ascii8_to_k5.py in.rom out.rom", file=sys.stderr)
        sys.exit(1)
    src = Path(sys.argv[1]).read_bytes()
    dst, patches = convert(src)
    Path(sys.argv[2]).write_bytes(dst)
    print(f"Patched {len(patches)} bank-switch instructions:")
    seg_counts = {0x50: 0, 0x70: 0, 0x90: 0, 0xB0: 0}
    for off, old, new in patches[:8]:
        print(f"  @0x{off:06X}  0x{old:04X} -> 0x{new:04X}")
    if len(patches) > 8:
        print(f"  ... +{len(patches) - 8} more")
    for off, old, new in patches:
        seg_counts[new >> 8] += 1
    print(f"By target segment: seg0={seg_counts[0x50]}  seg1={seg_counts[0x70]}  "
          f"seg2={seg_counts[0x90]}  seg3={seg_counts[0xB0]}")


if __name__ == "__main__":
    main()
