#!/usr/bin/env python3
"""Build the K4 PROBE ROMs (copy A 'P' and copy B 'Q') from the pasmo outputs.

Inputs (same directory):
  k4probe_engine.bin  - experiment engine (org 0xC800), must be >0 and <=4096
  k4probe_bank0.bin   - bank 0 with the engine embedded, must be exactly 8192

Outputs:
  k4probe.rom    - 131072 bytes, signatures 'P','B',bank,~bank at +0x1F00
  k4probe_b.rom  - same, letter 'Q' (boot-fallback copy, packed as PLAIN)

Every check exists because pasmo emits an EMPTY binary with exit code 0 when
a `ds` goes negative (block overflow) - sizes are the only reliable signal.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BANK = 8192
SIG_OFF = 0x1F00
BANKS = 16  # 128KB


def fail(msg: str) -> None:
    print(f"make_probe_rom: ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    engine = (HERE / "k4probe_engine.bin").read_bytes()
    if len(engine) == 0:
        fail("k4probe_engine.bin is EMPTY (pasmo negative-ds quirk?)")
    if len(engine) > 4096:
        fail(f"engine is {len(engine)} bytes (> 4096: overflows 0xC800-0xD7FF)")

    bank0 = (HERE / "k4probe_bank0.bin").read_bytes()
    if len(bank0) != BANK:
        fail(f"k4probe_bank0.bin is {len(bank0)} bytes (expected exactly {BANK})")
    if bank0[SIG_OFF:SIG_OFF + 4] != b"PB\x00\xff":
        fail("bank 0 signature missing/odd at +0x1F00 (layout overflow?)")
    if bank0[0:2] != b"AB":
        fail("bank 0 lacks the AB cartridge header")

    for letter, out_name in ((b"P", "k4probe.rom"), (b"Q", "k4probe_b.rom")):
        rom = bytearray()
        b0 = bytearray(bank0)
        b0[SIG_OFF] = letter[0]
        rom += b0
        for b in range(1, BANKS):
            bank = bytearray(b"\xff" * BANK)
            bank[SIG_OFF] = letter[0]
            bank[SIG_OFF + 1] = ord("B")
            bank[SIG_OFF + 2] = b
            bank[SIG_OFF + 3] = b ^ 0xFF
            rom += bank
        if len(rom) != BANK * BANKS:
            fail(f"{out_name}: built {len(rom)} bytes (expected {BANK * BANKS})")
        (HERE / out_name).write_bytes(rom)
        print(f"make_probe_rom: {out_name} OK ({len(rom)} bytes, letter {letter.decode()})")


if __name__ == "__main__":
    main()
