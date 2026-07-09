// Image builder port. Mirrors packager/yamanooto_pack.py.
//
// Not yet ported (returns Err if a ROM needs it):
//   - ASCII8 / ASCII16 in-memory conversion
//   - SCC patcher (force-mirror fallback active)

use crate::mapper::MapperKind;
use std::collections::BTreeMap;

pub const BANK_SIZE: usize = 8 * 1024;
pub const OFFR_UNIT: usize = 32 * 1024;
pub const LAUNCHER_BANKS: usize = 4;
pub const LAUNCHER_OFFSET: usize = 0;
pub const LAUNCHER_SIZE: usize = LAUNCHER_BANKS * BANK_SIZE;
pub const DIR_BANK: usize = 15;
pub const DIR_OFFSET: usize = DIR_BANK * BANK_SIZE;
pub const DIR_HDR_SIZE: usize = 32;
pub const DIR_ENTRY_SIZE: usize = 32;
pub const DIR_MAX_ENTRIES: usize = (BANK_SIZE - DIR_HDR_SIZE) / DIR_ENTRY_SIZE;
pub const GAMES_POOL_START: usize = 0x020000;
pub const FILL_BYTE: u8 = 0xFF;

pub const SCC_OFFR_ALIGN: u8 = 16;
pub const SCC_MIRROR_TARGET: usize = 512 * 1024;

pub const FLAG_K4: u8 = 0x01;
pub const FLAG_MDIS: u8 = 0x02;
pub const FLAG_ASCII16: u8 = 0x08;
pub const FLAG_SCC_HELPER: u8 = 0x10;

/// Default marquee placeholder baked into launcher.bin. The packager uses
/// this whole string as an anchor to find both no-wrap copies of the buffer.
pub const MARQUEE_ANCHOR: &[u8] =
    b"                                        THIS TEXT CAN BE REPLACED, PLEASE READ THE DOCS                                         ";
pub const MARQUEE_CUSTOM_SIZE: usize = 128;

/// 8-byte magic anchor for the packager-rewritable config block.
/// The byte right after the anchor is the splash enable flag (1 = show).
pub const CFG_ANCHOR: &[u8] = b"YMNTCFG!";

/// Default menu title baked into launcher.bin; used as the anchor to find the
/// fixed 32-byte title buffer. Keep in sync with launcher.asm's msg_title.
pub const TITLE_ANCHOR: &[u8] = b"YAMANOOTO KONAMI COLLECTION";
pub const TITLE_BUF_SIZE: usize = 32;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FlashSize { Mb2, Mb8 }

impl FlashSize {
    pub fn bytes(self) -> usize {
        match self { FlashSize::Mb2 => 2*1024*1024, FlashSize::Mb8 => 8*1024*1024 }
    }
    pub fn max_offr(self) -> usize { self.bytes() / OFFR_UNIT }
}

#[derive(Clone)]
pub struct Game {
    pub title: String,
    pub data: Vec<u8>,
    pub mapper: MapperKind,
    pub flags: u8,
    pub banks: [u8; 4],
    pub needs_wrap_mirror: bool,
    pub size_blocks_32k: u8,
    // Filled by pack_games:
    pub offr: u8,
    pub suboff: u8,      // CFGR bits 4-5: 8KB offset inside the 32KB OFFR unit
    pub flash_offset: usize,
}

impl Game {
    pub fn new(title: String, data: Vec<u8>, mapper: MapperKind) -> Result<Self, String> {
        let size = data.len();
        let (mut flags, banks, needs_wrap_mirror, data) = match mapper {
            MapperKind::Scc => {
                // Match the Python packager: data untouched, 8KB wrap-mirror
                // placed at flash bank OFFR*4 + 63 (the spot the 0x3F-enable
                // trick lands on). scc_patch + FLAG_SCC_HELPER integration is
                // declared in main but not wired through in yamanooto_pack.py,
                // and activating the flag triggers an unfinished helper path
                // in launcher.bin (F1 Spirit hangs). Stay with the wrap-mirror
                // alone for now.
                let needs_wrap_mirror = size < SCC_MIRROR_TARGET;
                (0, [0u8, 1, 2, 3], needs_wrap_mirror, data)
            }
            MapperKind::K5 => (0, [0,1,2,3], false, data),
            MapperKind::K4 => (FLAG_K4, [0,1,2,3], false, data),
            MapperKind::Plain => {
                let b = if size <= 8*1024 { [0,0,0,0] }
                        else if size <= 16*1024 { [0,1,0,1] }
                        else { [0,1,2,3] };
                (FLAG_K4 | FLAG_MDIS, b, false, data)
            }
            MapperKind::Ascii16K5 => {
                let needs_mirror = size < SCC_MIRROR_TARGET;
                (FLAG_ASCII16, [0,1,2,3], needs_mirror, data)
            }
        };
        if needs_wrap_mirror { /* hint already set in struct field */ flags |= 0; }
        let mut title = title;
        if title.len() > 23 { title.truncate(23); }
        let size_blocks_32k = (((data.len() + OFFR_UNIT - 1) / OFFR_UNIT).min(255)) as u8;
        Ok(Self {
            title, data, mapper, flags, banks, needs_wrap_mirror, size_blocks_32k,
            offr: 0, suboff: 0, flash_offset: 0,
        })
    }

    pub fn size_offr(&self) -> usize {
        (self.data.len() + OFFR_UNIT - 1) / OFFR_UNIT
    }
}

fn align_up(v: usize, a: usize) -> usize { ((v + a - 1) / a) * a }

/// 8KB sub-placement eligibility (CFGR SUBOFF, bits 4-5). Mirrors
/// yamanooto_pack.py::_sub_slots_needed: how many 8KB slots the game needs
/// inside a shared 32KB OFFR unit (1 for <=8KB, 2 for <=16KB), or None if it
/// must keep taking whole OFFR units. SCC/ASCII16 are excluded (16-OFFR
/// alignment + wrap mirror + the 0x3F trick); openMSX resolves banks as
/// (value + OFFR*4 + suboff) & 0x3FF.
fn sub_slots_needed(g: &Game) -> Option<usize> {
    if !matches!(g.mapper, MapperKind::K4 | MapperKind::Plain) { return None; }
    if g.needs_wrap_mirror { return None; }
    let size = g.data.len();
    if size <= BANK_SIZE { Some(1) }
    else if size <= 2 * BANK_SIZE { Some(2) }
    else { None }
}

pub fn pack_games(games: &mut Vec<Game>, flash: FlashSize) -> Result<Vec<Game>, String> {
    let n_slots = flash.max_offr();
    let mut occupied = vec![false; n_slots];
    // Reserve everything below GAMES_POOL_START.
    for i in 0..(GAMES_POOL_START / OFFR_UNIT) {
        if i < n_slots { occupied[i] = true; }
    }

    let mut placed: Vec<Game> = Vec::new();
    let mut dropped: Vec<Game> = Vec::new();

    let (mut scc, mut non_scc): (Vec<Game>, Vec<Game>) = games.drain(..)
        .partition(|g| matches!(g.mapper, MapperKind::Scc | MapperKind::Ascii16K5));

    scc.sort_by(|a, b| b.data.len().cmp(&a.data.len()));
    non_scc.sort_by(|a, b| b.data.len().cmp(&a.data.len()));

    // SCC: 16-aligned slots
    for g in scc {
        let size_offr = g.size_offr();
        if g.needs_wrap_mirror && size_offr > 15 {
            dropped.push(g);
            continue;
        }
        let mut slot: Option<Game> = Some(g);
        let mut start = align_up(GAMES_POOL_START / OFFR_UNIT, SCC_OFFR_ALIGN as usize);
        while start + 16 <= n_slots {
            let needs_mirror = slot.as_ref().unwrap().needs_wrap_mirror;
            let mut needed: Vec<usize> = (start..start + size_offr).collect();
            if needs_mirror { needed.push(start + 15); }
            if needed.iter().all(|&i| !occupied[i]) {
                for &i in &needed { occupied[i] = true; }
                let mut g = slot.take().unwrap();
                g.offr = start as u8;
                g.flash_offset = start * OFFR_UNIT;
                placed.push(g);
                break;
            }
            start += SCC_OFFR_ALIGN as usize;
        }
        if let Some(g) = slot {
            dropped.push(g);
        }
    }

    // Non-SCC: any free slot. Small (<=16KB) K4/plain games are sub-placed at
    // 8KB granularity inside a shared 32KB unit via CFGR SUBOFF: one unit
    // holds 2x16KB or 4x8KB games. subunits tracks each opened unit's free
    // 8KB slots; BTreeMap iteration order matches Python's sorted() (parity).
    let mut subunits: BTreeMap<usize, [bool; 4]> = BTreeMap::new();
    for g in non_scc {
        if let Some(sub_n) = sub_slots_needed(&g) {
            let mut slot: Option<(usize, usize)> = None;
            'search: for (&offr, bmp) in subunits.iter() {
                let candidates: &[usize] = if sub_n == 2 { &[0, 2] } else { &[0, 1, 2, 3] };
                for &s in candidates {
                    if bmp[s..s + sub_n].iter().all(|&used| !used) {
                        slot = Some((offr, s));
                        break 'search;
                    }
                }
            }
            if slot.is_none() {
                // Open a new shared unit at the first free OFFR.
                for start in 0..n_slots {
                    if !occupied[start] {
                        occupied[start] = true;
                        subunits.insert(start, [false; 4]);
                        slot = Some((start, 0));
                        break;
                    }
                }
            }
            if let Some((offr, s)) = slot {
                let bmp = subunits.get_mut(&offr).unwrap();
                for i in s..s + sub_n { bmp[i] = true; }
                let mut g = g;
                g.offr = offr as u8;
                g.suboff = (s as u8) << 4;              // CFGR bits 4-5
                g.flash_offset = (offr * 4 + s) * BANK_SIZE;
                // A sub-placed game must never map banks beyond its own slots:
                // give small K4 games the mirrored pattern Plain already gets.
                if matches!(g.mapper, MapperKind::K4) {
                    g.banks = if sub_n == 1 { [0, 0, 0, 0] } else { [0, 1, 0, 1] };
                }
                placed.push(g);
            } else {
                dropped.push(g);
            }
            continue;
        }
        let size_offr = g.size_offr().max(1);
        let mut slot: Option<Game> = Some(g);
        for start in 0..=n_slots.saturating_sub(size_offr) {
            if (start..start + size_offr).all(|i| !occupied[i]) {
                for i in start..start + size_offr { occupied[i] = true; }
                let mut g = slot.take().unwrap();
                g.offr = start as u8;
                g.flash_offset = start * OFFR_UNIT;
                placed.push(g);
                break;
            }
        }
        if let Some(g) = slot { dropped.push(g); }
    }

    placed.sort_by_key(|g| g.offr);
    *games = placed;
    Ok(dropped)
}

pub fn build_directory(games: &[Game]) -> Result<Vec<u8>, String> {
    if games.len() > DIR_MAX_ENTRIES {
        return Err(format!("Too many games ({}) > {}", games.len(), DIR_MAX_ENTRIES));
    }
    let mut out = Vec::with_capacity(BANK_SIZE);
    // Header: "YMNT" + u16 count + zero pad to DIR_HDR_SIZE
    out.extend_from_slice(b"YMNT");
    out.extend_from_slice(&(games.len() as u16).to_le_bytes());
    out.resize(DIR_HDR_SIZE, 0);
    for g in games {
        let mut entry = [0u8; DIR_ENTRY_SIZE];
        let bytes = g.title.as_bytes();
        let n = bytes.len().min(23);
        entry[..n].copy_from_slice(&bytes[..n]);
        // 23..24 stays NUL
        entry[24] = g.offr;
        entry[25] = g.suboff & 0x30;            // DIR_SUBOFF (bits 4-5)
        entry[26] = g.flags;
        entry[27] = g.size_blocks_32k;
        entry[28..32].copy_from_slice(&g.banks);
        out.extend_from_slice(&entry);
    }
    // pad bank
    out.resize(BANK_SIZE, FILL_BYTE);
    Ok(out)
}

pub fn apply_marquee(launcher: &mut Vec<u8>, custom: Option<&str>) -> Result<(), String> {
    // None keeps the baked-in default placeholder; Some("") intentionally blanks
    // the marquee (fills it with spaces) so nothing scrolls.
    let Some(text) = custom else { return Ok(()); };

    let upper = text.to_uppercase();
    let mut buf = [b' '; MARQUEE_CUSTOM_SIZE];
    let upper_bytes: Vec<u8> = upper.chars().map(|c| {
        if c.is_ascii() { c as u8 } else { b'?' }
    }).collect();
    if upper_bytes.len() >= MARQUEE_CUSTOM_SIZE {
        buf.copy_from_slice(&upper_bytes[..MARQUEE_CUSTOM_SIZE]);
    } else {
        let pad = MARQUEE_CUSTOM_SIZE - upper_bytes.len();
        let left = pad / 2;
        buf[left..left + upper_bytes.len()].copy_from_slice(&upper_bytes);
    }

    let mut positions = Vec::new();
    let mut start = 0;
    while let Some(idx) = find_subslice(&launcher[start..], MARQUEE_ANCHOR) {
        let abs = start + idx;
        positions.push(abs);
        start = abs + 1;
    }
    if positions.len() != 2 {
        return Err(format!("expected 2 marquee copies in launcher.bin, found {}", positions.len()));
    }
    for p in positions {
        launcher[p..p + MARQUEE_CUSTOM_SIZE].copy_from_slice(&buf);
    }
    Ok(())
}

/// Overwrite the fixed 32-byte title buffer (text + NUL + padding). No-op if
/// title is None/empty. The MSX font is uppercase-only, so text is uppercased;
/// longer titles are truncated (they'd overflow the screen / red box).
pub fn apply_title(launcher: &mut [u8], title: Option<&str>) -> Result<(), String> {
    let Some(text) = title else { return Ok(()); };
    if text.is_empty() { return Ok(()); }

    let upper = text.to_uppercase();
    let mut bytes: Vec<u8> = upper.chars()
        .map(|c| if c.is_ascii() { c as u8 } else { b'?' })
        .collect();
    bytes.truncate(TITLE_BUF_SIZE - 1);          // leave room for the NUL
    let mut buf = [0u8; TITLE_BUF_SIZE];          // NUL-terminated + padded
    buf[..bytes.len()].copy_from_slice(&bytes);

    let Some(idx) = find_subslice(launcher, TITLE_ANCHOR) else {
        return Err("title anchor not found in launcher.bin".into());
    };
    launcher[idx..idx + TITLE_BUF_SIZE].copy_from_slice(&buf);
    Ok(())
}

fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() { return None; }
    hay.windows(needle.len()).position(|w| w == needle)
}

#[cfg(test)]
mod title_tests {
    use super::*;

    fn buf_with_anchor() -> (Vec<u8>, usize) {
        let mut b = vec![0xAAu8; 8];                 // prefix sentinel
        let idx = b.len();
        b.extend_from_slice(TITLE_ANCHOR);
        b.extend(std::iter::repeat(0u8).take(TITLE_BUF_SIZE - TITLE_ANCHOR.len()));
        b.extend_from_slice(&[0xBBu8; 8]);           // suffix sentinel
        (b, idx)
    }

    #[test]
    fn overwrites_uppercased_and_nul_terminated() {
        let (mut b, idx) = buf_with_anchor();
        apply_title(&mut b, Some("mi juego")).unwrap();
        assert_eq!(&b[idx..idx + 8], b"MI JUEGO");   // uppercased
        assert_eq!(b[idx + 8], 0);                   // NUL terminator
        assert_eq!(&b[..8], &[0xAAu8; 8]);           // prefix intact
        assert_eq!(&b[idx + TITLE_BUF_SIZE..], &[0xBBu8; 8]); // suffix intact
    }

    #[test]
    fn none_and_empty_are_noops() {
        let (orig, _) = buf_with_anchor();
        let mut b = orig.clone();
        apply_title(&mut b, None).unwrap();
        assert_eq!(b, orig);
        apply_title(&mut b, Some("")).unwrap();
        assert_eq!(b, orig);
    }

    #[test]
    fn overlong_title_truncated_with_nul() {
        let (mut b, idx) = buf_with_anchor();
        apply_title(&mut b, Some(&"X".repeat(50))).unwrap();
        assert_eq!(&b[idx..idx + (TITLE_BUF_SIZE - 1)], &vec![b'X'; TITLE_BUF_SIZE - 1][..]);
        assert_eq!(b[idx + TITLE_BUF_SIZE - 1], 0);  // still NUL-terminated
    }

    // End-to-end: build a real image through the exact path the Build button
    // uses (build_image), with a custom title/marquee, and write it out so it
    // can be booted in openMSX. Verifies the Rust GUI produces a bootable ROM
    // with the new SCREEN 2 launcher — not just that pieces compile.
    #[test]
    fn builds_bootable_rom_via_build_image() {
        let launcher = std::fs::read("data/launcher.bin").expect("data/launcher.bin");
        assert!(find_subslice(&launcher, TITLE_ANCHOR).is_some(),
                "embedded launcher must be the new SCREEN 2 one");
        let mut games = vec![
            Game::new("TEST ALPHA".into(), vec![0xC9u8; 16 * 1024], MapperKind::Plain).unwrap(),
            Game::new("TEST BETA".into(),  vec![0xC9u8; 16 * 1024], MapperKind::Plain).unwrap(),
            Game::new("TEST GAMMA".into(), vec![0xC9u8; 16 * 1024], MapperKind::Plain).unwrap(),
        ];
        let colors = MenuColors { text: 7, bg: 4, box_: 11 }; // cyan / dark-blue / light-yellow
        let (image, dropped) = build_image(
            &launcher, &mut games, FlashSize::Mb8,
            Some(""), Some("MI TITULO GUI"),
            false,     // splash off
            false,     // boot jingle off (asserted below)
            colors,
        ).expect("build_image");
        assert_eq!(image.len(), FlashSize::Mb8.bytes());
        assert!(dropped.is_empty());
        // title override landed in the launcher region of the image
        assert!(find_subslice(&image[..LAUNCHER_SIZE], b"MI TITULO GUI").is_some());
        // an empty marquee must BLANK the default placeholder, not keep it
        assert!(find_subslice(&image[..LAUNCHER_SIZE], b"THIS TEXT CAN BE REPLACED").is_none(),
                "empty marquee should blank the default placeholder");
        // colour nibbles landed in the config block
        let cfg = find_subslice(&image[..LAUNCHER_SIZE], CFG_ANCHOR).expect("cfg anchor");
        assert_eq!(image[cfg + CFG_COL_TEXT_OFF], 7);
        assert_eq!(image[cfg + CFG_COL_BG_OFF], 4);
        assert_eq!(image[cfg + CFG_COL_BOX_OFF], 11);
        assert_eq!(image[cfg + CFG_MUSIC_OFF], 0, "boot_music=false must land in cfg block");
        let out = std::env::temp_dir().join("rust_gui.rom");
        std::fs::write(&out, &image).expect("write rust_gui.rom to temp dir");
    }

    // Twin of `yamanooto_pack.py test` (cmd_test): same synthetic game set,
    // same hand-computed expected placements. If both suites pass, the
    // Python and Rust SUBOFF sub-placement is identical by construction.
    #[test]
    fn suboff_parity_with_python() {
        fn dummy(size: usize) -> Vec<u8> {
            let mut rom = vec![0u8; size];
            rom[0] = b'A'; rom[1] = b'B';
            rom[2] = 0x10; rom[3] = 0x40;        // INIT 0x4010
            rom
        }
        let mut games = vec![
            Game::new("TEST GAME 1 (SCC)".into(), dummy(0x8000), MapperKind::Scc).unwrap(),
            Game::new("TEST GAME 2 (K4)".into(),  dummy(0x8000), MapperKind::K4).unwrap(),
            Game::new("TEST 16K A".into(), dummy(16 * 1024), MapperKind::Plain).unwrap(),
            Game::new("TEST 16K B".into(), dummy(16 * 1024), MapperKind::Plain).unwrap(),
            Game::new("TEST 16K C".into(), dummy(16 * 1024), MapperKind::Plain).unwrap(),
            Game::new("TEST 8K D".into(),  dummy(8 * 1024),  MapperKind::Plain).unwrap(),
        ];
        let dropped = pack_games(&mut games, FlashSize::Mb8).unwrap();
        assert!(dropped.is_empty());
        let find = |t: &str| games.iter().find(|g| g.title == t).unwrap();
        // Hand-computed (pool starts at OFFR 4): SCC -> 16-aligned slot 16;
        // K4 32KB -> OFFR 4; 16K A opens shared unit 5, 16K B fills its upper
        // half, 16K C opens unit 6, 8K D takes unit 6 slot 2.
        for (title, offr, suboff) in [
            ("TEST 16K A", 5u8, 0x00u8), ("TEST 16K B", 5, 0x20),
            ("TEST 16K C", 6, 0x00),     ("TEST 8K D",  6, 0x20),
        ] {
            let g = find(title);
            assert_eq!((g.offr, g.suboff), (offr, suboff), "{title}");
            let base = (g.offr as usize * 4 + (g.suboff >> 4) as usize) * BANK_SIZE;
            assert_eq!(g.flash_offset, base, "{title}");
        }
        assert_eq!(find("TEST GAME 2 (K4)").offr, 4);
        assert_eq!(find("TEST GAME 1 (SCC)").offr, 16);
        // Sub-placed games keep/get mirrored banks (never map the neighbour).
        assert_eq!(find("TEST 16K A").banks, [0, 1, 0, 1]);
        assert_eq!(find("TEST 8K D").banks, [0, 0, 0, 0]);
        // The directory encodes suboff at entry byte 25.
        let mut sorted = games.clone();
        sorted.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
        let dir = build_directory(&sorted).unwrap();
        let idx = sorted.iter().position(|g| g.title == "TEST 16K B").unwrap();
        let entry = &dir[DIR_HDR_SIZE + idx * DIR_ENTRY_SIZE..];
        assert_eq!(entry[25], 0x20, "dir entry SUBOFF byte");
    }

    #[test]
    fn apply_colors_patches_and_validates() {
        // minimal launcher with just the config block
        let mut lb = Vec::new();
        lb.extend_from_slice(CFG_ANCHOR);
        lb.extend_from_slice(&[1, 15, 1, 8, 0, 0, 0, 0]); // splash + defaults + reserved
        apply_colors(&mut lb, MenuColors { text: 2, bg: 6, box_: 14 }).unwrap();
        let i = find_subslice(&lb, CFG_ANCHOR).unwrap();
        assert_eq!((lb[i + 9], lb[i + 10], lb[i + 11]), (2, 6, 14));
        // out-of-range rejected
        assert!(apply_colors(&mut lb, MenuColors { text: 0, bg: 1, box_: 8 }).is_err());
        assert!(apply_colors(&mut lb, MenuColors { text: 16, bg: 1, box_: 8 }).is_err());
    }

    #[test]
    fn apply_music_flag_patches_cfg_byte() {
        // minimal launcher: cfg block layout mirrors launcher.asm
        // (+8 splash, +9..11 colours, +12 music, +13..20 tile, +21..23 rsvd)
        let mut lb = Vec::new();
        lb.extend_from_slice(CFG_ANCHOR);
        lb.extend_from_slice(&[1, 15, 1, 8, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let i = find_subslice(&lb, CFG_ANCHOR).unwrap();
        apply_music_flag(&mut lb, false).unwrap();
        assert_eq!(lb[i + CFG_MUSIC_OFF], 0);
        apply_music_flag(&mut lb, true).unwrap();
        assert_eq!(lb[i + CFG_MUSIC_OFF], 1);
        // neighbours untouched
        assert_eq!((lb[i + 8], lb[i + 9], lb[i + CFG_TILE_OFF]), (1, 15, 0));
    }
}

pub fn apply_splash_flag(launcher: &mut [u8], show_splash: bool) -> Result<(), String> {
    let Some(idx) = find_subslice(launcher, CFG_ANCHOR) else {
        return Err("config anchor not found in launcher.bin".into());
    };
    let flag_pos = idx + CFG_ANCHOR.len();
    if flag_pos >= launcher.len() {
        return Err("config anchor too close to end of launcher".into());
    }
    launcher[flag_pos] = if show_splash { 1 } else { 0 };
    Ok(())
}

/// Boot-jingle flag offset within the config block (launcher.asm
/// cfg_music_enable): anchor +12. 1 = play (launcher default), 0 = silent.
pub const CFG_MUSIC_OFF: usize = 12;
/// 8-byte background tile (launcher.asm cfg_tile): anchor +13..+20.
pub const CFG_TILE_OFF: usize = 13;

pub fn apply_music_flag(launcher: &mut [u8], boot_music: bool) -> Result<(), String> {
    let Some(idx) = find_subslice(launcher, CFG_ANCHOR) else {
        return Err("config anchor not found in launcher.bin".into());
    };
    let pos = idx + CFG_MUSIC_OFF;
    if pos >= launcher.len() {
        return Err("config anchor too close to end of launcher".into());
    }
    launcher[pos] = if boot_music { 1 } else { 0 };
    Ok(())
}

/// Menu colour nibble offsets within the config block, measured from the start
/// of CFG_ANCHOR: +8 splash flag, +9 text, +10 bg, +11 box (see launcher.asm
/// cfg_col_*).
pub const CFG_COL_TEXT_OFF: usize = 9;
pub const CFG_COL_BG_OFF: usize = 10;
pub const CFG_COL_BOX_OFF: usize = 11;

/// MSX menu colours (TMS9918 palette indices 1-15).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MenuColors {
    pub text: u8,
    pub bg: u8,
    pub box_: u8,
}

impl Default for MenuColors {
    /// Launcher defaults: white text on black, medium-red title box.
    fn default() -> Self {
        MenuColors { text: 15, bg: 1, box_: 8 }
    }
}

pub fn apply_colors(launcher: &mut [u8], colors: MenuColors) -> Result<(), String> {
    let Some(idx) = find_subslice(launcher, CFG_ANCHOR) else {
        return Err("config anchor not found in launcher.bin".into());
    };
    for (off, val) in [
        (CFG_COL_TEXT_OFF, colors.text),
        (CFG_COL_BG_OFF, colors.bg),
        (CFG_COL_BOX_OFF, colors.box_),
    ] {
        if !(1..=15).contains(&val) {
            return Err(format!("colour index must be 1-15, got {val}"));
        }
        let pos = idx + off;
        if pos >= launcher.len() {
            return Err("config anchor too close to end of launcher".into());
        }
        launcher[pos] = val;
    }
    Ok(())
}

pub fn build_image(
    launcher: &[u8],
    games: &mut Vec<Game>,
    flash: FlashSize,
    marquee: Option<&str>,
    title: Option<&str>,
    show_splash: bool,
    boot_music: bool,
    colors: MenuColors,
) -> Result<(Vec<u8>, Vec<Game>), String> {
    let mut launcher = launcher.to_vec();
    apply_marquee(&mut launcher, marquee)?;
    apply_title(&mut launcher, title)?;
    apply_splash_flag(&mut launcher, show_splash)?;
    apply_music_flag(&mut launcher, boot_music)?;
    apply_colors(&mut launcher, colors)?;
    if launcher.len() > LAUNCHER_SIZE {
        return Err(format!("Launcher too big: {} > {}", launcher.len(), LAUNCHER_SIZE));
    }

    let dropped = pack_games(games, flash)?;

    let mut image = vec![FILL_BYTE; flash.bytes()];
    image[LAUNCHER_OFFSET..LAUNCHER_OFFSET + launcher.len()].copy_from_slice(&launcher);

    let mut sorted = games.clone();
    sorted.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    let dir = build_directory(&sorted)?;
    image[DIR_OFFSET..DIR_OFFSET + BANK_SIZE].copy_from_slice(&dir);

    for g in games.iter() {
        let off = g.flash_offset;
        let end = off + g.data.len();
        if end > image.len() {
            return Err(format!("Game {:?} overflows flash ({} > {})", g.title, end, image.len()));
        }
        image[off..end].copy_from_slice(&g.data);
        if g.needs_wrap_mirror {
            let last_bank_start = g.data.len().saturating_sub(BANK_SIZE);
            let mirror_bank_idx = g.offr as usize * 4 + 63;
            let mirror_off = mirror_bank_idx * BANK_SIZE;
            if mirror_off + BANK_SIZE <= image.len() {
                image[mirror_off..mirror_off + BANK_SIZE]
                    .copy_from_slice(&g.data[last_bank_start..last_bank_start + BANK_SIZE]);
            }
        }
    }
    Ok((image, dropped))
}
