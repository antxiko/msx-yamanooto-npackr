#!/bin/sh
# Build the SRAM-emulation test image (phase A verification).
# Output: testroms/sram_test_yamanooto.rom (8MB image for -romtype Yamanooto)
set -e
cd "$(dirname "$0")"

pasmo --bin sram_test.asm sram_test.raw
python3 - <<'EOF'
import sys
sys.path.insert(0, '../packager')
import ascii8sram_to_k5 as conv
import yamanooto_pack as y

raw = open('sram_test.raw', 'rb').read()
raw = raw + b'\xFF' * (32 * 1024 - len(raw))          # pad to 32KB
patched, patches = conv.convert(raw)
print(f"converted: {len(patches)} bank writes patched")
assert len(patches) >= 4, "expected the 4 test bank writes to be patched"

launcher = open('../launcher/launcher.bin', 'rb').read()
games = [y.Game('SRAM TEST', patched, y.MAPPER_ASCII8_SRAM)]
img, dropped = y.build_image(launcher, games)
assert not dropped
open('sram_test_yamanooto.rom', 'wb').write(img)
g = games[0]
print(f"image written: sram_test_yamanooto.rom ({len(img)} bytes)")
print(f"  game @0x{g.flash_offset:06X}  save sector @0x{g.save_sector_bank*0x2000:06X}")
EOF
