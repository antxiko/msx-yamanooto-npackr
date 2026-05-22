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
    data: Vec<u8>,
    unsupported_reason: Option<String>,
}

struct App {
    marquee: String,
    flash_size: FlashSize,
    games: Vec<GameEntry>,
    status: String,
}

impl Default for App {
    fn default() -> Self {
        Self {
            marquee: String::new(),
            flash_size: FlashSize::Mb8,
            games: Vec::new(),
            status: String::new(),
        }
    }
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
                    ui.label("Flash size:");
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb2, "2 MB (early units)");
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb8, "8 MB (standard)");
                });
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
                                let mapper_label = g.mapper
                                    .map(|m| m.short().to_string())
                                    .unwrap_or_else(|| g.softdb_type.clone());
                                let color = if g.mapper.is_some() {
                                    egui::Color32::from_rgb(255, 204, 102)
                                } else {
                                    egui::Color32::from_rgb(255, 120, 120)
                                };
                                ui.label(egui::RichText::new(mapper_label).small().color(color));
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
        let data = match std::fs::read(&path) {
            Ok(d) => d,
            Err(e) => {
                self.status = format!("Read error on {}: {}", filename, e);
                return;
            }
        };
        let size = data.len();
        let sha1 = softdb::sha1_hex(&data);
        let entry = softdb().lookup(&sha1);
        let (mapper, softdb_type, suggested_title, unsupported_reason) = match entry {
            Some(e) => {
                let mapper = mapper::from_softdb_type(&e.mapper_type);
                let reason = if mapper.is_none() {
                    Some(format!("mapper '{}' not supported in this Rust port yet", e.mapper_type))
                } else { None };
                let mut t = e.title.clone();
                // ASCII won't keep multi-byte; truncate carefully later.
                if t.len() > 23 { t = e.title.chars().take(23).collect(); }
                (mapper, e.mapper_type.clone(), t, reason)
            }
            None => (None, "(unknown SHA1)".into(),
                strip_known_tags(&filename),
                Some("SHA1 not in openMSX softdb".into())),
        };
        self.games.push(GameEntry {
            filename, title: suggested_title, size, mapper, softdb_type, data, unsupported_reason,
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

        let marquee_opt = if self.marquee.trim().is_empty() { None } else { Some(self.marquee.trim()) };
        let result = pack::build_image(LAUNCHER_BIN, &mut games, self.flash_size, marquee_opt);
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
