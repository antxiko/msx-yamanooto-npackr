// MSX Yamanooto nPackR — GUI (Rust port)
//
// Iteration 1: skeleton UI only. No real packaging logic yet — that comes
// in next iterations as we port:
//   - softdb XML parsing + SHA1 detect
//   - marquee replacement
//   - build_image (mapper layout, OFFR alignment, wrap mirror)
//   - ASCII8 / ASCII16 converters
//   - SCC patcher
//
// Reference implementation: ../packager/yamanooto_pack.py (Python, in main
// branch). Once this Rust GUI reaches feature parity we merge to main.

use eframe::egui;

#[derive(Clone, Copy, PartialEq, Eq)]
enum FlashSize {
    Mb2,
    Mb8,
}

impl FlashSize {
    fn label(self) -> &'static str {
        match self {
            FlashSize::Mb2 => "2 MB (early units)",
            FlashSize::Mb8 => "8 MB (standard)",
        }
    }
    fn bytes(self) -> usize {
        match self {
            FlashSize::Mb2 => 2 * 1024 * 1024,
            FlashSize::Mb8 => 8 * 1024 * 1024,
        }
    }
}

struct GameEntry {
    filename: String,
    title: String,
    size: usize,
    mapper: String,
}

struct App {
    marquee: String,
    flash_size: FlashSize,
    games: Vec<GameEntry>,
}

impl Default for App {
    fn default() -> Self {
        Self {
            marquee: String::new(),
            flash_size: FlashSize::Mb8,
            games: Vec::new(),
        }
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Accept drag-and-drop from the desktop
        let dropped: Vec<std::path::PathBuf> = ctx.input(|i| {
            i.raw.dropped_files.iter()
                .filter_map(|f| f.path.clone())
                .collect()
        });
        for p in dropped {
            self.add_rom(p);
        }

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("MSX Yamanooto nPackR");
            ui.label("Build a Yamanooto flash image from your own ROMs.");
            ui.separator();

            // Settings
            ui.group(|ui| {
                ui.label(egui::RichText::new("SETTINGS").strong().color(egui::Color32::from_rgb(255, 204, 102)));
                ui.horizontal(|ui| {
                    ui.label("Marquee text:");
                    ui.add(egui::TextEdit::singleline(&mut self.marquee)
                        .hint_text("Leave empty for default repo URL")
                        .desired_width(f32::INFINITY));
                });
                ui.label(egui::RichText::new("Max 64 chars. Uppercased automatically. Anti-scam notice is always shown before it.")
                    .small().color(egui::Color32::GRAY));

                ui.horizontal(|ui| {
                    ui.label("Flash size:");
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb2, FlashSize::Mb2.label());
                    ui.radio_value(&mut self.flash_size, FlashSize::Mb8, FlashSize::Mb8.label());
                });
            });

            ui.add_space(8.0);

            // ROMs panel
            ui.group(|ui| {
                ui.label(egui::RichText::new("ROMS").strong().color(egui::Color32::from_rgb(255, 204, 102)));

                ui.horizontal(|ui| {
                    if ui.button("Add ROM files…").clicked() {
                        if let Some(paths) = rfd::FileDialog::new()
                            .add_filter("MSX ROMs", &["rom", "ROM"])
                            .pick_files()
                        {
                            for p in paths {
                                self.add_rom(p);
                            }
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
                                ui.label(egui::RichText::new(&g.mapper)
                                    .small().color(egui::Color32::from_rgb(255, 204, 102)));
                                ui.label(egui::RichText::new(format!("{} KB", g.size / 1024))
                                    .small().color(egui::Color32::GRAY));
                                if ui.small_button("✕").clicked() {
                                    to_remove = Some(idx);
                                }
                            });
                            ui.label(egui::RichText::new(&g.filename)
                                .small().color(egui::Color32::DARK_GRAY));
                            ui.add_space(2.0);
                        }
                    });
                    if let Some(idx) = to_remove {
                        self.games.remove(idx);
                    }
                }
            });

            ui.add_space(8.0);

            // Footer
            ui.horizontal(|ui| {
                let total_kb: usize = self.games.iter()
                    .map(|g| ((g.size + 32767) / 32768) * 32)
                    .sum();
                let flash_kb = self.flash_size.bytes() / 1024;
                ui.label(egui::RichText::new(format!("{} games · ~{} KB / {} KB flash",
                    self.games.len(), total_kb, flash_kb))
                    .small().color(egui::Color32::GRAY));

                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let enabled = !self.games.is_empty();
                    if ui.add_enabled(enabled, egui::Button::new("Build ROM")).clicked() {
                        // Iteration 1: stub. Real builder lands in next iterations.
                        eprintln!("Build clicked (not implemented yet)");
                    }
                });
            });
        });
    }
}

impl App {
    fn add_rom(&mut self, path: std::path::PathBuf) {
        let filename = path.file_name()
            .and_then(|s| s.to_str()).unwrap_or("?").to_string();
        let size = std::fs::metadata(&path).map(|m| m.len() as usize).unwrap_or(0);
        let title = strip_known_tags(&filename);
        self.games.push(GameEntry {
            filename,
            title,
            size,
            mapper: "?".to_string(),
        });
    }
}

/// Best-effort short title from a filename. Real implementation will look up
/// the SHA1 in openMSX's softwaredb and use the canonical title.
fn strip_known_tags(name: &str) -> String {
    let stem = name.trim_end_matches(".ROM").trim_end_matches(".rom");
    let cut = stem.find(" (").or_else(|| stem.find(" [")).unwrap_or(stem.len());
    let title = &stem[..cut];
    title.trim().to_string()
}

fn main() -> Result<(), eframe::Error> {
    let opts = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([720.0, 600.0])
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
