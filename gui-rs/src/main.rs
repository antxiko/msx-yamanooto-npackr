// MSX Yamanooto nPackR — GUI (Rust port)
//
// Functional features so far:
//   - Drag-drop / file picker of ROMs
//   - SHA1 → mapper detection via embedded openMSX softwaredb.xml
//   - Editable title per ROM (also seeded with the canonical softdb title)
//   - Marquee customization (max 64 chars, uppercased)
//   - Flash size 2MB / 8MB
//   - Build the .rom image (launcher embedded) and save via native dialog
//
// Not yet ported from packager/yamanooto_pack.py (main branch):
//   - ASCII8 / ASCII16 in-memory conversion (those ROMs come up "unsupported")
//   - SCC patcher (we fall back to 4× mirror for <512K SCC games)

mod convert;
mod mapper;
mod pack;
mod softdb;

use eframe::egui;
use mapper::MapperKind;
use pack::FlashSize;
use softdb::Softdb;
use std::sync::OnceLock;

const SOFTDB_XML: &[u8] = include_bytes!("../data/softwaredb.xml");
const LAUNCHER_BIN: &[u8] = include_bytes!("../data/launcher.bin");
/// 6x8 launcher font: 64 glyphs (ASCII 0x20-0x5F), 8 bytes each, bit7 = leftmost.
const FONT6X8: &[u8] = include_bytes!("../data/font6x8.bin");

// Manual mapper overrides for the per-row dropdown. scc/k5/k4/plain are pure
// re-tags (ROM packed as-is, only CFGR/bank setup differs). ascii8/ascii16 run
// the converter on the raw ROM, so ASCII games whose SHA1 is not in the softdb
// can still be forced through — same result as the CLI --auto-convert.
const MAPPER_CHOICES: &[&str] = &["scc", "k5", "k4", "plain", "ascii8", "ascii16"];

fn apply_mapper_choice(g: &mut GameEntry, choice: &str) {
    g.unsupported_reason = None;
    match choice {
        "scc"   => { g.data = g.raw.clone(); g.mapper = Some(MapperKind::Scc); }
        "k5"    => { g.data = g.raw.clone(); g.mapper = Some(MapperKind::K5); }
        "k4"    => { g.data = g.raw.clone(); g.mapper = Some(MapperKind::K4); }
        "plain" => { g.data = g.raw.clone(); g.mapper = Some(MapperKind::Plain); }
        "ascii8" => {
            let (patched, n) = convert::ascii8_to_k5(&g.raw);
            if n > 0 {
                g.data = patched;
                g.mapper = Some(MapperKind::K5);
            } else {
                g.mapper = None;
                g.unsupported_reason = Some("ASCII8: no patchable bank writes".into());
            }
        }
        "ascii16" => {
            let (patched, s0, s1) = convert::ascii16_to_k5(&g.raw);
            if s0 + s1 > 0 {
                g.data = patched;
                g.mapper = Some(MapperKind::Ascii16K5);
            } else {
                g.mapper = None;
                g.unsupported_reason = Some("ASCII16: no patchable bank writes".into());
            }
        }
        _ => {}
    }
}

fn softdb() -> &'static Softdb {
    static DB: OnceLock<Softdb> = OnceLock::new();
    DB.get_or_init(|| Softdb::parse(SOFTDB_XML))
}

#[derive(Clone)]
struct GameEntry {
    filename: String,
    title: String,
    size: usize,
    mapper: Option<MapperKind>,
    softdb_type: String,
    data: Vec<u8>,              // bytes to pack (possibly converted)
    unsupported_reason: Option<String>,
    raw: Vec<u8>,              // pristine ROM, for re-converting via the dropdown
}

struct App {
    marquee: String,
    title: String,
    flash_size: FlashSize,
    show_splash: bool,
    colors: pack::MenuColors,
    games: Vec<GameEntry>,
    status: String,
}

impl Default for App {
    fn default() -> Self {
        Self {
            marquee: String::new(),
            title: String::new(),
            flash_size: FlashSize::Mb8,
            show_splash: true,
            colors: pack::MenuColors::default(),
            games: Vec::new(),
            status: String::new(),
        }
    }
}

/// MSX1 (TMS9918) palette, indices 1-15 (0 = transparent, not offered).
const MSX_PALETTE: &[(u8, &str)] = &[
    (1, "Black"), (2, "Medium green"), (3, "Light green"), (4, "Dark blue"),
    (5, "Light blue"), (6, "Dark red"), (7, "Cyan"), (8, "Medium red"),
    (9, "Light red"), (10, "Dark yellow"), (11, "Light yellow"), (12, "Dark green"),
    (13, "Magenta"), (14, "Gray"), (15, "White"),
];

fn msx_color_name(idx: u8) -> &'static str {
    MSX_PALETTE.iter().find(|(i, _)| *i == idx).map(|(_, n)| *n).unwrap_or("?")
}

/// Blit one uppercased glyph string from the real 6x8 font into the painter at
/// MSX-pixel (x_msx, y_msx), scaled. Advances 6px/char (proportional). Returns
/// the end X in MSX px. `ink` paints set bits; unset bits are left transparent.
fn blit_glyphs(
    painter: &egui::Painter, origin: egui::Pos2, scale: f32,
    x_msx: f32, y_msx: f32, text: &str, ink: egui::Color32,
) -> f32 {
    let mut x = x_msx;
    for ch in text.chars() {
        let c = ch.to_ascii_uppercase() as u32;
        let gi = if (0x20..=0x5F).contains(&c) { (c - 0x20) as usize } else { 0 };
        let glyph = &FONT6X8[gi * 8..gi * 8 + 8];
        for (row, bits) in glyph.iter().enumerate() {
            for col in 0..6u32 {
                if bits & (0x80 >> col) != 0 {
                    let px = origin.x + (x + col as f32) * scale;
                    let py = origin.y + (y_msx + row as f32) * scale;
                    painter.rect_filled(
                        egui::Rect::from_min_size(egui::pos2(px, py), egui::vec2(scale, scale)),
                        0.0, ink);
                }
            }
        }
        x += 6.0;
    }
    x
}

fn str_width_px(text: &str) -> f32 { text.chars().count() as f32 * 6.0 }

/// Live simulation of the SCREEN 2 cart menu with the chosen colours, drawn with
/// the real font so it matches what boots on the MSX.
fn draw_menu_preview(ui: &mut egui::Ui, colors: pack::MenuColors,
                     title: &str, marquee: &str, rows: &[String]) {
    const MSX_W: f32 = 256.0;
    let n_rows = rows.len().min(5);
    // Layout in MSX px: title box (rows 0..2 = 0..24), list from 24, marquee last.
    let list_top = 24.0;
    let marq_y = list_top + n_rows as f32 * 8.0 + 4.0;
    let msx_h = marq_y + 8.0 + 1.0;

    // ~25% of the previous full-width size: half the linear scale (quarter area).
    let scale = (ui.available_width() / MSX_W).clamp(1.0, 3.0) * 0.5;
    let (rect, _) = ui.allocate_exact_size(
        egui::vec2(MSX_W * scale, msx_h * scale), egui::Sense::hover());
    let painter = ui.painter_at(rect);
    let origin = rect.min;

    let text_c = msx_color_rgb(colors.text);
    let bg_c = msx_color_rgb(colors.bg);
    let box_c = msx_color_rgb(colors.box_);

    // Background
    painter.rect_filled(rect, 0.0, bg_c);

    // Title centred on row 1 (y=8), inside a box hugging it (rows 0..2).
    let tw = str_width_px(title);
    let tx = ((MSX_W - tw) / 2.0).max(2.0);
    blit_glyphs(&painter, origin, scale, tx, 8.0, title, text_c);
    let box_min = egui::pos2(origin.x + (tx - 4.0) * scale, origin.y);
    let box_max = egui::pos2(origin.x + (tx + tw + 2.0) * scale, origin.y + 23.0 * scale);
    painter.rect_stroke(egui::Rect::from_min_max(box_min, box_max),
        2.0, egui::Stroke::new(scale.max(1.0), box_c));

    // List rows; row 0 is the selected one (inverse bar hugging the title width).
    let name_x = 8.0;
    for (i, name) in rows.iter().take(5).enumerate() {
        let y = list_top + i as f32 * 8.0;
        if i == 0 {
            let w = str_width_px(name);
            let bar = egui::Rect::from_min_size(
                egui::pos2(origin.x + name_x * scale, origin.y + y * scale),
                egui::vec2((w + 1.0) * scale, 8.0 * scale));
            painter.rect_filled(bar, 0.0, text_c);            // inverse: bar in text colour
            blit_glyphs(&painter, origin, scale, name_x, y, name, bg_c); // text in bg colour
        } else {
            blit_glyphs(&painter, origin, scale, name_x, y, name, text_c);
        }
    }

    // Marquee line (blank when empty, matching the launcher).
    if !marquee.is_empty() {
        blit_glyphs(&painter, origin, scale, name_x, marq_y, marquee, text_c);
    }
}

/// A labelled MSX-palette dropdown with colour swatches, editing `current`.
fn color_picker(ui: &mut egui::Ui, id: &str, label: &str, current: &mut u8) {
    ui.horizontal(|ui| {
        ui.label(label);
        let (rect, _) = ui.allocate_exact_size(egui::vec2(16.0, 16.0), egui::Sense::hover());
        ui.painter().rect_filled(rect, 2.0, msx_color_rgb(*current));
        egui::ComboBox::from_id_source(id)
            .selected_text(msx_color_name(*current))
            .show_ui(ui, |ui| {
                for (idx, name) in MSX_PALETTE {
                    ui.horizontal(|ui| {
                        let (r, _) = ui.allocate_exact_size(egui::vec2(14.0, 14.0), egui::Sense::hover());
                        ui.painter().rect_filled(r, 2.0, msx_color_rgb(*idx));
                        ui.selectable_value(current, *idx, *name);
                    });
                }
            });
    });
}

/// egui swatch RGB for each MSX palette index (approx. TMS9918 colours).
fn msx_color_rgb(idx: u8) -> egui::Color32 {
    let (r, g, b) = match idx {
        1 => (0, 0, 0), 2 => (33, 200, 66), 3 => (94, 220, 120), 4 => (84, 85, 237),
        5 => (125, 118, 252), 6 => (212, 82, 77), 7 => (66, 235, 245), 8 => (252, 85, 84),
        9 => (255, 121, 120), 10 => (212, 193, 84), 11 => (230, 206, 128), 12 => (33, 176, 59),
        13 => (201, 91, 186), 14 => (204, 204, 204), 15 => (255, 255, 255), _ => (128, 128, 128),
    };
    egui::Color32::from_rgb(r, g, b)
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let dropped: Vec<std::path::PathBuf> = ctx.input(|i| {
            i.raw.dropped_files.iter()
                .filter_map(|f| f.path.clone())
                .collect()
        });
        for p in dropped { self.add_rom(p); }

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("MSX Yamanooto nPackR");
            ui.label("Build a Yamanooto flash image from your own ROMs.");
            ui.separator();

            // SETTINGS
            ui.group(|ui| {
                ui.label(egui::RichText::new("SETTINGS").strong()
                    .color(egui::Color32::from_rgb(255, 204, 102)));
                ui.horizontal(|ui| {
                    ui.label("Marquee text:");
                    ui.add(egui::TextEdit::singleline(&mut self.marquee)
                        .hint_text("Leave empty for default placeholder")
                        .desired_width(f32::INFINITY));
                });
                ui.label(egui::RichText::new("Max 64 chars. Uppercased automatically. Anti-scam notice is always shown before it.")
                    .small().color(egui::Color32::GRAY));

                ui.horizontal(|ui| {
                    ui.label("Menu title: ");
                    ui.add(egui::TextEdit::singleline(&mut self.title)
                        .hint_text("Leave empty for default (YAMANOOTO KONAMI COLLECTION)")
                        .desired_width(f32::INFINITY));
                });
                ui.label(egui::RichText::new("Max 31 chars, uppercased. The red title box auto-fits.")
                    .small().color(egui::Color32::GRAY));

                ui.add_space(4.0);
                ui.label("Menu colours (MSX palette):");
                ui.horizontal(|ui| {
                    color_picker(ui, "col_text", "Text", &mut self.colors.text);
                    color_picker(ui, "col_bg", "Background", &mut self.colors.bg);
                    color_picker(ui, "col_box", "Title box", &mut self.colors.box_);
                });
                ui.label(egui::RichText::new("Selection bar uses text/background swapped automatically.")
                    .small().color(egui::Color32::GRAY));

                // Live simulation of how the cart menu will look.
                ui.add_space(4.0);
                let prev_title = if self.title.trim().is_empty() {
                    "YAMANOOTO KONAMI COLLECTION".to_string()
                } else { self.title.trim().to_uppercase() };
                let prev_marquee = self.marquee.trim().to_uppercase();
                let prev_rows: Vec<String> = if self.games.is_empty() {
                    ["ANTARCTIC ADVENTURE", "GRADIUS 2", "METAL GEAR", "NEMESIS 3", "SALAMANDER"]
                        .iter().map(|s| s.to_string()).collect()
                } else {
                    self.games.iter().take(5).map(|g| g.title.to_uppercase()).collect()
                };
                draw_menu_preview(ui, self.colors, &prev_title, &prev_marquee, &prev_rows);

                ui.horizontal(|ui| {
                    ui.label("Flash size:");
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb2, "2 MB (early units)");
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb8, "8 MB (standard)");
                });

                ui.checkbox(&mut self.show_splash, "Show boot splash (anti-scam notice)");
            });

            ui.add_space(8.0);

            // ROMS
            ui.group(|ui| {
                ui.label(egui::RichText::new("ROMS").strong()
                    .color(egui::Color32::from_rgb(255, 204, 102)));

                ui.horizontal(|ui| {
                    if ui.button("Add ROM files…").clicked() {
                        if let Some(paths) = rfd::FileDialog::new()
                            .add_filter("MSX ROMs", &["rom", "ROM"])
                            .pick_files()
                        {
                            for p in paths { self.add_rom(p); }
                        }
                    }
                    if !self.games.is_empty() && ui.button("Clear").clicked() {
                        self.games.clear();
                    }
                    ui.label(egui::RichText::new("…or drag .rom files into this window")
                        .small().color(egui::Color32::GRAY));
                });

                ui.add_space(6.0);

                if self.games.is_empty() {
                    ui.label(egui::RichText::new("(no ROMs loaded)")
                        .italics().color(egui::Color32::GRAY));
                } else {
                    let mut to_remove: Option<usize> = None;
                    egui::ScrollArea::vertical().max_height(280.0).show(ui, |ui| {
                        for (idx, g) in self.games.iter_mut().enumerate() {
                            ui.horizontal(|ui| {
                                ui.add(egui::TextEdit::singleline(&mut g.title)
                                    .desired_width(280.0));
                                // Mapper is editable per row: an unknown-SHA1 or
                                // misdetected ROM (e.g. a recent "Enhanced" hack of
                                // a Konami-SCC game) can be forced by hand. Picking a
                                // value marks it supported so Build stops skipping it.
                                let selected_text = g.mapper
                                    .map(|m| m.short().to_string())
                                    .unwrap_or_else(|| g.softdb_type.clone());
                                let sel_color = if g.mapper.is_some() {
                                    egui::Color32::from_rgb(255, 204, 102)
                                } else {
                                    egui::Color32::from_rgb(255, 120, 120)
                                };
                                egui::ComboBox::from_id_source(("mapper", idx))
                                    .selected_text(egui::RichText::new(selected_text)
                                        .small().color(sel_color))
                                    .width(104.0)
                                    .show_ui(ui, |ui| {
                                        for &choice in MAPPER_CHOICES {
                                            if ui.selectable_label(false, choice).clicked() {
                                                apply_mapper_choice(g, choice);
                                            }
                                        }
                                    });
                                ui.label(egui::RichText::new(format!("{} KB", g.size / 1024))
                                    .small().color(egui::Color32::GRAY));
                                if ui.small_button("✕").clicked() { to_remove = Some(idx); }
                            });
                            ui.label(egui::RichText::new(&g.filename)
                                .small().color(egui::Color32::DARK_GRAY));
                            if let Some(why) = &g.unsupported_reason {
                                ui.label(egui::RichText::new(format!("  → {}", why))
                                    .small().color(egui::Color32::from_rgb(255, 120, 120)));
                            }
                            ui.add_space(2.0);
                        }
                    });
                    if let Some(idx) = to_remove { self.games.remove(idx); }
                }
            });

            ui.add_space(8.0);

            // FOOTER
            ui.horizontal(|ui| {
                let total_kb: usize = self.games.iter()
                    .filter(|g| g.mapper.is_some())
                    .map(|g| ((g.size + 32767) / 32768) * 32)
                    .sum();
                let flash_kb = self.flash_size.bytes() / 1024;
                let supported = self.games.iter().filter(|g| g.mapper.is_some()).count();
                ui.label(egui::RichText::new(format!("{} supported · {} skipped · ~{} KB / {} KB",
                    supported,
                    self.games.len() - supported,
                    total_kb, flash_kb))
                    .small().color(egui::Color32::GRAY));

                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let enabled = supported > 0;
                    if ui.add_enabled(enabled, egui::Button::new("Build ROM")).clicked() {
                        self.do_build();
                    }
                });
            });

            if !self.status.is_empty() {
                ui.add_space(6.0);
                ui.label(egui::RichText::new(&self.status)
                    .small().color(egui::Color32::LIGHT_GRAY));
            }
        });
    }
}

impl App {
    fn add_rom(&mut self, path: std::path::PathBuf) {
        let filename = path.file_name()
            .and_then(|s| s.to_str()).unwrap_or("?").to_string();
        let raw = match std::fs::read(&path) {
            Ok(d) => d,
            Err(e) => {
                self.status = format!("Read error on {}: {}", filename, e);
                return;
            }
        };
        let size = raw.len();
        let sha1 = softdb::sha1_hex(&raw);
        let entry = softdb().lookup(&sha1);

        let (mapper, softdb_type_raw, suggested_title) = match entry {
            Some(e) => {
                let mut t = e.title.clone();
                if t.len() > 23 { t = e.title.chars().take(23).collect(); }
                (mapper::from_softdb_type(&e.mapper_type), e.mapper_type.clone(), t)
            }
            None => (None, "(unknown SHA1)".into(), strip_known_tags(&filename)),
        };

        // Auto-convert ASCII8 / ASCII16 on the fly so they enter as K5 /
        // ascii16_k5 mappers. Mirrors the Python pack-folder --auto-convert path.
        let raw_pristine = raw.clone();   // kept so the dropdown can re-convert
        let (mapper, softdb_type, data, unsupported_reason) =
            match (mapper, softdb_type_raw.as_str()) {
                (None, "ASCII8") => {
                    let (patched, n) = convert::ascii8_to_k5(&raw);
                    if n > 0 {
                        (Some(MapperKind::K5),
                         format!("ASCII8 → K5 ({} patches)", n),
                         patched, None)
                    } else {
                        (None, softdb_type_raw, raw,
                         Some("ASCII8 with no patchable bank writes".into()))
                    }
                }
                (None, "ASCII16") => {
                    let (patched, s0, s1) = convert::ascii16_to_k5(&raw);
                    if s0 + s1 > 0 {
                        (Some(MapperKind::Ascii16K5),
                         format!("ASCII16 → K5 ({}+{} patches)", s0, s1),
                         patched, None)
                    } else {
                        (None, softdb_type_raw, raw,
                         Some("ASCII16 with no patchable bank writes".into()))
                    }
                }
                (Some(m), st) => (Some(m), st.to_string(), raw, None),
                (None, st) => (None, st.to_string(), raw,
                    Some(format!("mapper '{}' not supported", st))),
            };

        self.games.push(GameEntry {
            filename, title: suggested_title, size, mapper, softdb_type, data, unsupported_reason,
            raw: raw_pristine,
        });
    }

    fn do_build(&mut self) {
        // Convert UI rows into pack::Game
        let mut games = Vec::new();
        for g in &self.games {
            let Some(mapper) = g.mapper else { continue; };
            match pack::Game::new(g.title.clone(), g.data.clone(), mapper) {
                Ok(pg) => games.push(pg),
                Err(e) => {
                    self.status = format!("Game {:?}: {}", g.title, e);
                    return;
                }
            }
        }

        // Always apply the marquee field: empty -> blank marquee (not the default).
        let marquee_opt = Some(self.marquee.trim());
        let title_opt = if self.title.trim().is_empty() { None } else { Some(self.title.trim()) };
        let result = pack::build_image(LAUNCHER_BIN, &mut games, self.flash_size, marquee_opt, title_opt, self.show_splash, self.colors);
        let (image, dropped) = match result {
            Ok(r) => r,
            Err(e) => { self.status = format!("Build failed: {}", e); return; }
        };

        let default_name = format!("yamanooto-{}.rom",
            match self.flash_size { FlashSize::Mb2 => "2mb", FlashSize::Mb8 => "8mb" });
        let Some(save_path) = rfd::FileDialog::new()
            .set_file_name(&default_name)
            .add_filter("ROM image", &["rom"])
            .save_file() else {
            self.status = "Save cancelled.".into();
            return;
        };

        match std::fs::write(&save_path, &image) {
            Ok(_) => {
                let summary = format!(
                    "Wrote {} ({:.2} MB, {} games placed, {} dropped)",
                    save_path.file_name().and_then(|s| s.to_str()).unwrap_or("?"),
                    image.len() as f64 / (1024.0 * 1024.0),
                    games.len(),
                    dropped.len()
                );
                self.status = if dropped.is_empty() {
                    summary
                } else {
                    let names: Vec<String> = dropped.iter().map(|g| g.title.clone()).collect();
                    format!("{} — dropped: {}", summary, names.join(", "))
                };
            }
            Err(e) => self.status = format!("Write failed: {}", e),
        }
    }
}

fn strip_known_tags(name: &str) -> String {
    let stem = name.trim_end_matches(".ROM").trim_end_matches(".rom");
    let cut = stem.find(" (").or_else(|| stem.find(" [")).unwrap_or(stem.len());
    stem[..cut].trim().to_string()
}

fn main() -> Result<(), eframe::Error> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([760.0, 640.0])
            .with_min_inner_size([520.0, 400.0])
            .with_title("MSX Yamanooto nPackR"),
        ..Default::default()
    };
    eframe::run_native(
        "yamanooto-gui",
        opts,
        Box::new(|_cc| Ok(Box::<App>::default())),
    )
}

#[cfg(test)]
mod choice_tests {
    use super::*;

    fn unsupported_entry(raw: Vec<u8>) -> GameEntry {
        GameEntry {
            filename: "x.rom".into(), title: "X".into(), size: raw.len(),
            mapper: None, softdb_type: "(unknown SHA1)".into(),
            data: raw.clone(), unsupported_reason: Some("mapper not supported".into()),
            raw,
        }
    }

    // A ROM with a single `LD (0x6000),A` (ASCII8 seg-0 bank write): 32 00 60.
    #[test]
    fn ascii8_choice_converts_unknown_rom() {
        let mut g = unsupported_entry(vec![0x32, 0x00, 0x60, 0xC9]);
        apply_mapper_choice(&mut g, "ascii8");
        assert_eq!(g.mapper, Some(MapperKind::K5));
        assert!(g.unsupported_reason.is_none());
        assert_eq!(g.data[2], 0x50); // 0x60 -> K5 seg0 (0x50)
    }

    #[test]
    fn ascii16_choice_converts_unknown_rom() {
        let mut g = unsupported_entry(vec![0x32, 0x00, 0x60, 0xC9]);
        apply_mapper_choice(&mut g, "ascii16");
        assert_eq!(g.mapper, Some(MapperKind::Ascii16K5));
        assert!(g.unsupported_reason.is_none());
        assert_eq!(g.data[0], 0xCD); // rewritten to CALL 0xF000
    }

    // Plain re-tag must start from the pristine raw, not previously-mangled data.
    #[test]
    fn plain_choice_retags_from_pristine_raw() {
        let raw = vec![0xC9u8; 64];
        let mut g = unsupported_entry(raw.clone());
        g.data = vec![0xAA; 8]; // pretend an earlier conversion happened
        apply_mapper_choice(&mut g, "plain");
        assert_eq!(g.mapper, Some(MapperKind::Plain));
        assert_eq!(g.data, raw);
    }
}
