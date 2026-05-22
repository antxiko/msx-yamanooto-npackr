// Image builder port. Mirrors packager/yamanooto_pack.py.
//
// Not yet ported (returns Err if a ROM needs it):
//   - ASCII8 / ASCII16 in-memory conversion
//   - SCC patcher (force-mirror fallback active)

use crate::mapper::MapperKind;

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
            offr: 0, flash_offset: 0,
        })
    }

    pub fn size_offr(&self) -> usize {
        (self.data.len() + OFFR_UNIT - 1) / OFFR_UNIT
    }
}

fn align_up(v: usize, a: usize) -> usize { ((v + a - 1) / a) * a }

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

    // Non-SCC: any free slot
    for g in non_scc {
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
        entry[25] = 0;                          // SUBOFF (always 0 in this port)
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
    let Some(text) = custom else { return Ok(()); };
    if text.is_empty() { return Ok(()); }

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

fn find_subslice(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() { return None; }
    hay.windows(needle.len()).position(|w| w == needle)
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

pub fn build_image(
    launcher: &[u8],
    games: &mut Vec<Game>,
    flash: FlashSize,
    marquee: Option<&str>,
    show_splash: bool,
) -> Result<(Vec<u8>, Vec<Game>), String> {
    let mut launcher = launcher.to_vec();
    apply_marquee(&mut launcher, marquee)?;
    apply_splash_flag(&mut launcher, show_splash)?;
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
