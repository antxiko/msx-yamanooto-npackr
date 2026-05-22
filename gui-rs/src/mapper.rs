// Yamanooto mapper kinds + mapping from openMSX softdb types.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MapperKind {
    Scc,       // KonamiSCC, needs 16-OFFR alignment + wrap-mirror for <512K
    K5,        // K5 hardware, no SCC sound (no alignment)
    K4,        // Konami-4
    Plain,     // Mirrored / linear
    Ascii16K5, // patched ASCII16 (needs RAM helper — not packable here yet)
}

impl MapperKind {
    pub fn short(&self) -> &'static str {
        match self {
            MapperKind::Scc => "scc",
            MapperKind::K5 => "k5",
            MapperKind::K4 => "k4",
            MapperKind::Plain => "plain",
            MapperKind::Ascii16K5 => "ascii16_k5",
        }
    }
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
