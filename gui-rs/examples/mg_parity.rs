//! Byte-for-byte parity check: the GUI's Rust Metal Gear patchers must produce
//! exactly what packager/mg{1,2}_to_yamanooto.py produce.
//!
//! Usage: cargo run --example mg_parity -- <raw> <python_out> <mg1|mg2>
use std::path::PathBuf;

#[path = "../src/convert.rs"]
mod convert;
#[path = "../src/mapper.rs"]
mod mapper;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 4 {
        eprintln!("usage: mg_parity <raw.rom> <python_out.rom> <mg1|mg2>");
        std::process::exit(2);
    }
    let raw = std::fs::read(PathBuf::from(&a[1])).unwrap();
    let py = std::fs::read(PathBuf::from(&a[2])).unwrap();
    let rust = match a[3].as_str() {
        "mg1" => convert::mg1_to_yamanooto(&raw),
        "mg2" => convert::mg2_to_yamanooto(&raw),
        other => { eprintln!("unknown kind {other}"); std::process::exit(2); }
    };
    let rust = match rust {
        Some(v) => v,
        None => { eprintln!("FAIL: Rust refused to patch this ROM"); std::process::exit(1); }
    };
    if rust.len() != py.len() {
        eprintln!("FAIL: length {} (rust) != {} (python)", rust.len(), py.len());
        std::process::exit(1);
    }
    let diffs: Vec<usize> = (0..rust.len()).filter(|&i| rust[i] != py[i]).collect();
    if diffs.is_empty() {
        println!("PARITY OK: {} bytes identical (rust == python)", rust.len());
    } else {
        eprintln!("FAIL: {} differing bytes, first at 0x{:X} (rust {:02X} vs py {:02X})",
                  diffs.len(), diffs[0], rust[diffs[0]], py[diffs[0]]);
        std::process::exit(1);
    }
}
