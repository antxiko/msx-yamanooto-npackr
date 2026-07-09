// Ports of packager/ascii8_to_k5.py, ascii16_to_k5.py,
// mg1_to_yamanooto.py and mg2_to_yamanooto.py.

/// Bank-F virtual-tape driver + shim for Metal Gear 1 (built from
/// mg1_driver.asm / mg1_shim.asm). Kept in sync by the forensic gate.
const MG1_DRIVER: &[u8] = include_bytes!("../../launcher/mg1_driver.bin");
const MG1_SHIM: &[u8] = include_bytes!("../../launcher/mg1_shim.bin");
/// GM2-shaped flash save driver for Metal Gear 2 (built from mg2_driver.asm).
const MG2_DRIVER: &[u8] = include_bytes!("../../launcher/mg2_driver.bin");

// --- Metal Gear 1: redirect the 20 cassette BIOS calls to bank-F stubs ------
// (routine label, ROM offset of the CD opcode, BIOS vector). Mirrors the SITES
// table in mg1_to_yamanooto.py; assembly-verified against the disassembly.
const MG1_SITES: &[(usize, u16)] = &[
    (0x1F985, 0x00EA), (0x1F98D, 0x00ED), (0x1F99D, 0x00ED), (0x1F9A9, 0x00F0),
    (0x1F9C0, 0x00EA), (0x1F9CE, 0x00ED), (0x1F9DE, 0x00ED), (0x1F9E3, 0x00F0),
    (0x1FA39, 0x00E4), (0x1FA49, 0x00E4), (0x1FA55, 0x00E7), (0x1FB16, 0x00E4),
    (0x1FB24, 0x00E4), (0x1FB2C, 0x00E7), (0x1FB47, 0x00E7), (0x1FB9A, 0x00E1),
    (0x1FBA2, 0x00E4), (0x1FBB5, 0x00E4), (0x1FBD7, 0x00E1), (0x1FBDE, 0x00E1),
];
const MG1_SHIM_OFFSET: usize = 0x1FFA7;   // bank F free 0xFF tail (CPU 0xBFA7)
const MG1_STUB_BASE: u16 = 0xBFA7;
const MG1_STUB_STRIDE: u16 = 5;

fn mg1_fn_id(bios: u16) -> u16 {
    match bios {
        0x00E1 => 0, 0x00E4 => 1, 0x00E7 => 2,
        0x00EA => 3, 0x00ED => 4, 0x00F0 => 5, _ => unreachable!(),
    }
}

/// Is this a RAW (unpatched) Metal Gear 1 ROM we can convert? 128KB, every
/// intercept site holds `call TAPxx`, and the shim area is pristine 0xFF.
pub fn is_raw_mg1(rom: &[u8]) -> bool {
    if rom.len() != 0x20000 { return false; }
    if !rom[MG1_SHIM_OFFSET..0x20000].iter().all(|&b| b == 0xFF) { return false; }
    MG1_SITES.iter().all(|&(off, bios)| {
        rom.get(off..off + 3) == Some(&[0xCD, (bios & 0xFF) as u8, (bios >> 8) as u8][..])
    })
}

/// Patch a raw MG1 ROM for Yamanooto flash saves: repoint the 20 tape calls
/// at the bank-F stubs, install the shim, append the 8KB driver as relative
/// bank 0x10. Returns the 0x22000-byte image, or None if `rom` isn't a
/// convertible raw MG1 (validated by is_raw_mg1 — never patches blind).
pub fn mg1_to_yamanooto(rom: &[u8]) -> Option<Vec<u8>> {
    if !is_raw_mg1(rom) { return None; }
    let mut out = rom.to_vec();
    for &(off, bios) in MG1_SITES {
        let stub = MG1_STUB_BASE + mg1_fn_id(bios) * MG1_STUB_STRIDE;
        out[off + 1] = (stub & 0xFF) as u8;
        out[off + 2] = (stub >> 8) as u8;
    }
    out[MG1_SHIM_OFFSET..MG1_SHIM_OFFSET + MG1_SHIM.len()].copy_from_slice(MG1_SHIM);
    out.extend_from_slice(MG1_DRIVER);
    Some(out)
}

// --- Metal Gear 2: two touch-point patches + appended GM2-shaped driver -----
const MG2_P1_OFF: usize = 0x5DD4;
const MG2_P1_OLD: [u8; 7] = [0x01, 0x00, 0x04, 0x21, 0xC1, 0xFC, 0xC5];
const MG2_P1_NEW: [u8; 7] = [0x3A, 0x99, 0xC3, 0x32, 0x8A, 0xC3, 0xC9];
const MG2_P2_OFF: usize = 0x186D4;
const MG2_P2_OLD: [u8; 33] = [
    0xC5, 0x3A, 0x8A, 0xC3, 0x26, 0x80, 0xCD, 0x24, 0x00,
    0x3E, 0x04, 0x32, 0x00, 0x80,
    0xC1, 0xED, 0x5B, 0x90, 0xC3,
    0xCD, 0x00, 0x80,
    0xF5, 0x3A, 0x99, 0xC3, 0x26, 0x80, 0xCD, 0x24, 0x00,
    0xF1, 0xC9,
];
const MG2_P2_NEW: [u8; 33] = [
    0x3A, 0x82, 0xC3, 0xF5, 0x3E, 0x40, 0x32, 0x00, 0x90,
    0xED, 0x5B, 0x90, 0xC3, 0xCD, 0x00, 0x80, 0x08, 0xF1,
    0x32, 0x00, 0x90, 0x08, 0xC9,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// Is this a RAW (unpatched) Metal Gear 2 ROM we can convert? 512KB with both
/// original touch-point byte sequences intact.
pub fn is_raw_mg2(rom: &[u8]) -> bool {
    rom.len() == 512 * 1024
        && rom.get(MG2_P1_OFF..MG2_P1_OFF + 7) == Some(&MG2_P1_OLD[..])
        && rom.get(MG2_P2_OFF..MG2_P2_OFF + 33) == Some(&MG2_P2_OLD[..])
}

/// Patch a raw MG2 ROM for Yamanooto flash saves. Returns the 0x82000-byte
/// image (512KB game + 8KB driver at relative bank 0x40), or None if not a
/// convertible raw MG2.
pub fn mg2_to_yamanooto(rom: &[u8]) -> Option<Vec<u8>> {
    if !is_raw_mg2(rom) { return None; }
    let mut out = rom.to_vec();
    out[MG2_P1_OFF..MG2_P1_OFF + 7].copy_from_slice(&MG2_P1_NEW);
    out[MG2_P2_OFF..MG2_P2_OFF + 33].copy_from_slice(&MG2_P2_NEW);
    out.extend_from_slice(MG2_DRIVER);
    Some(out)
}

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

#[cfg(test)]
mod mg_tests {
    use super::*;

    // A synthetic 128KB "MG1": AB header, the 20 tape calls at their offsets,
    // 0xFF bank-F tail. Exercises the exact patch the GUI applies on drop.
    fn fake_raw_mg1() -> Vec<u8> {
        let mut rom = vec![0u8; 0x20000];
        rom[0] = b'A'; rom[1] = b'B';
        for &(off, bios) in MG1_SITES {
            rom[off] = 0xCD;
            rom[off + 1] = (bios & 0xFF) as u8;
            rom[off + 2] = (bios >> 8) as u8;
        }
        for b in &mut rom[MG1_SHIM_OFFSET..0x20000] { *b = 0xFF; }
        rom
    }

    #[test]
    fn mg1_patch_repoints_calls_and_appends_driver() {
        let raw = fake_raw_mg1();
        assert!(is_raw_mg1(&raw));
        let out = mg1_to_yamanooto(&raw).expect("convertible");
        assert_eq!(out.len(), 0x22000, "128KB game + 8KB driver");
        // SearchFile TAPION (0x1FB9A) -> stub 0 (0xBFA7): CD A7 BF
        assert_eq!(&out[0x1FB9A..0x1FB9D], &[0xCD, 0xA7, 0xBF]);
        // TAPOUT site (fn id 4 -> stub 0xBFA7 + 20 = 0xBFBB)
        assert_eq!(&out[0x1F98D..0x1F990], &[0xCD, 0xBB, 0xBF]);
        // shim installed, driver appended, re-detected as patched
        assert_eq!(&out[MG1_SHIM_OFFSET..MG1_SHIM_OFFSET + 2], &MG1_SHIM[..2]);
        assert_eq!(&out[0x20000..0x20002], &MG1_DRIVER[..2]);
        assert_eq!(super::super::mapper::detect_patched_mg(&out),
                   Some(super::super::mapper::MapperKind::Mg1));
        // a random 128KB blob must NOT be mistaken for MG1
        assert!(!is_raw_mg1(&vec![0u8; 0x20000]));
        assert!(mg1_to_yamanooto(&vec![0u8; 0x20000]).is_none());
    }

    #[test]
    fn mg2_patch_matches_touchpoints_and_appends_driver() {
        let mut raw = vec![0u8; 512 * 1024];
        raw[MG2_P1_OFF..MG2_P1_OFF + 7].copy_from_slice(&MG2_P1_OLD);
        raw[MG2_P2_OFF..MG2_P2_OFF + 33].copy_from_slice(&MG2_P2_OLD);
        assert!(is_raw_mg2(&raw));
        let out = mg2_to_yamanooto(&raw).expect("convertible");
        assert_eq!(out.len(), 0x82000, "512KB game + 8KB driver");
        assert_eq!(&out[MG2_P1_OFF..MG2_P1_OFF + 7], &MG2_P1_NEW);
        assert_eq!(&out[MG2_P2_OFF..MG2_P2_OFF + 33], &MG2_P2_NEW);
        assert_eq!(&out[0x80000..0x80002], &MG2_DRIVER[..2]);
        assert!(!is_raw_mg2(&vec![0u8; 512 * 1024]));
    }
}
