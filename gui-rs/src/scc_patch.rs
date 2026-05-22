// Port of packager/scc_patch.py.
//
// Rewrites the SCC-enable instruction sequence
//     LD A, imm           3E XX           with XX in {0x3F, 0x7F, 0xBF, 0xFF}
//     LD (0x9LL), A       32 LL HH        with HH in {0x90..0x97}
// into
//     LD A, imm           3E XX           (unchanged — A still carries XX)
//     CALL helper         CD lo hi
//
// The helper at SCC_HELPER_ADDR (set up by the launcher at FLAG_SCC_HELPER)
// performs the bank-2 write while temporarily compensating OFFR so the
// written 0x3F lands on the cart's actual last bank.

pub const SCC_HELPER_ADDR: u16 = 0xF020;

const SCC_ENABLE_VALUES: [u8; 4] = [0x3F, 0x7F, 0xBF, 0xFF];

/// Returns (patched_rom, num_patches).
pub fn convert(rom: &[u8]) -> (Vec<u8>, usize) {
    let mut out = rom.to_vec();
    let helper_lo = (SCC_HELPER_ADDR & 0xFF) as u8;
    let helper_hi = ((SCC_HELPER_ADDR >> 8) & 0xFF) as u8;
    let mut n = 0usize;
    if out.len() < 5 { return (out, 0); }
    let end = out.len() - 4;
    let mut i = 0;
    while i < end {
        if out[i] == 0x3E && SCC_ENABLE_VALUES.contains(&out[i + 1])
            && out[i + 2] == 0x32
            && (0x90..=0x97).contains(&out[i + 4])
        {
            out[i + 2] = 0xCD;
            out[i + 3] = helper_lo;
            out[i + 4] = helper_hi;
            n += 1;
            i += 5;
            continue;
        }
        i += 1;
    }
    (out, n)
}
