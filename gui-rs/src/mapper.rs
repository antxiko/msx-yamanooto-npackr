// Yamanooto mapper kinds + mapping from openMSX softdb types.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapperKind {
    Scc,       // KonamiSCC, needs 16-OFFR alignment + wrap-mirror for <512K
    K5,        // K5 hardware, no SCC sound (no alignment)
    K4,        // Konami-4
    Plain,     // Mirrored / linear
    Ascii16K5, // patched ASCII16 (needs RAM helper — not packable here yet)
    Mg1,       // Metal Gear 1 patched by mg1_to_yamanooto.py (K4 + flash saves)
    Mg2,       // Metal Gear 2 patched by mg2_to_yamanooto.py (SCC + flash saves)
}

impl MapperKind {
    pub fn short(&self) -> &'static str {
        match self {
            MapperKind::Scc => "scc",
            MapperKind::K5 => "k5",
            MapperKind::K4 => "k4",
            MapperKind::Plain => "plain",
            MapperKind::Ascii16K5 => "ascii16_k5",
            MapperKind::Mg1 => "mg1",
            MapperKind::Mg2 => "mg2",
        }
    }
}

/// Structural detection of the *_to_yamanooto.py outputs (their SHA1 is never
/// in the softdb). Byte signatures, not just sizes, so a random ROM can never
/// be mistaken for a patched Metal Gear:
/// - MG1: 128KB game + 8KB driver, and the SearchFile TAPION call at ROM
///   0x1FB9A repointed at the bank-F stub 0xBFA7 (CD A7 BF).
/// - MG2: 512KB game + 8KB driver, and the GM2-detection patch at 0x5DD4
///   (3A 99 C3 = LD A,(0xC399)).
pub fn detect_patched_mg(rom: &[u8]) -> Option<MapperKind> {
    if rom.len() == 0x22000 && rom.get(0x1FB9A..0x1FB9D) == Some(&[0xCD, 0xA7, 0xBF][..]) {
        return Some(MapperKind::Mg1);
    }
    if rom.len() == 0x82000 && rom.get(0x5DD4..0x5DD7) == Some(&[0x3A, 0x99, 0xC3][..]) {
        return Some(MapperKind::Mg2);
    }
    None
}

/// Mapping mirrors SOFTDB_TO_YAMA in packager/yamanooto_pack.py.
/// Returns None when the cart cannot be packed without conversion
/// (ASCII8/16 — pending in the Rust port) or hardware-specific carts.
pub fn from_softdb_type(typ: &str) -> Option<MapperKind> {
    match typ {
        "KonamiSCC" => Some(MapperKind::Scc),
        "Konami" => Some(MapperKind::K4),
        "Mirrored" | "Normal" | "0x0000" | "0x4000" | "0x8000"
            | "8kB" | "16kb" | "Page2" | "Page12" | "Mirrored4000" => Some(MapperKind::Plain),
        "Synthesizer" => Some(MapperKind::Plain),     // 32K linear + DAC (FPGA)
        "Majutsushi" => Some(MapperKind::K4),         // K4 + DAC at 0x5000
        // Not yet supported in this Rust port:
        "ASCII8" | "ASCII16"
            | "ASCII8SRAM8" | "ASCII16SRAM2" | "ASCII8SRAM2"
            | "KoeiSRAM32" | "GameMaster2" | "keyboardmaster"
            | "Page23" | "R-Type" | "Cross Blaim" => None,
        _ => None,
    }
}
