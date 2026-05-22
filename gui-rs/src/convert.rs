// Ports of packager/ascii8_to_k5.py and packager/ascii16_to_k5.py.

/// ASCII8 → K5 conversion. Rewrites `LD (nn),A` opcodes whose destination
/// lands in the ASCII8 switch zone:
///     0x6000-0x67FF (seg 0)  →  0x5000 (K5 seg 0)
///     0x6800-0x6FFF (seg 1)  →  0x7000 (K5 seg 1)
///     0x7000-0x77FF (seg 2)  →  0x9000 (K5 seg 2)
///     0x7800-0x7FFF (seg 3)  →  0xB000 (K5 seg 3)
/// Only the address bytes are touched; the low byte is forced to 0x00.
/// Returns (patched_rom, num_patches).
pub fn ascii8_to_k5(rom: &[u8]) -> (Vec<u8>, usize) {
    let mut out = rom.to_vec();
    let mut n = 0;
    if out.len() < 3 { return (out, 0); }
    let mut i = 0;
    while i < out.len().saturating_sub(2) {
        if out[i] == 0x32 {
            let hi = out[i + 2];
            let new_hi = match hi {
                0x60..=0x67 => Some(0x50),
                0x68..=0x6F => Some(0x70),
                0x70..=0x77 => Some(0x90),
                0x78..=0x7F => Some(0xB0),
                _ => None,
            };
            if let Some(new_hi) = new_hi {
                out[i + 1] = 0x00;
                out[i + 2] = new_hi;
                n += 1;
            }
        }
        i += 1;
    }
    (out, n)
}

/// ASCII16 → K5 conversion. Rewrites `LD (nn),A` opcodes hitting the
/// ASCII16 switch zone into `CALL 0xF000` (segment 0) or `CALL 0xF010`
/// (segment 1). The launcher installs the helper routines at those
/// addresses when FLAG_ASCII16 is set.
/// Returns (patched_rom, seg0_patches, seg1_patches).
pub fn ascii16_to_k5(rom: &[u8]) -> (Vec<u8>, usize, usize) {
    let mut out = rom.to_vec();
    let mut seg0 = 0;
    let mut seg1 = 0;
    if out.len() < 3 { return (out, 0, 0); }
    let mut i = 0;
    while i < out.len().saturating_sub(2) {
        if out[i] == 0x32 {
            let hi = out[i + 2];
            if (0x60..=0x67).contains(&hi) {
                out[i] = 0xCD;        // CALL nn
                out[i + 1] = 0x00;
                out[i + 2] = 0xF0;    // → 0xF000
                seg0 += 1;
            } else if (0x70..=0x77).contains(&hi) {
                out[i] = 0xCD;
                out[i + 1] = 0x10;
                out[i + 2] = 0xF0;    // → 0xF010
                seg1 += 1;
            }
        }
        i += 1;
    }
    (out, seg0, seg1)
}
