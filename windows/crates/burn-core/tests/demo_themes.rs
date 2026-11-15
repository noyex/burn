//! Keeps `ui/src/lib/demo-themes.json` in step with the themes that ship with Burn. The panel
//! reads it when it runs in a plain browser (`npm run dev`), where there is no app to ask.
//!
//! After changing a built-in theme or the shape of `ThemeState`, rewrite it with
//! `BURN_UPDATE_DEMO_THEMES=1 cargo test -p burn-core --test demo_themes`.

use burn_core::theme::{Loaded, ThemeDirs};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn fixture() -> String {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    // A folder that doesn't exist: only the built-in themes are listed.
    let dirs = ThemeDirs { user: PathBuf::from("no-such-themes-folder"), built_in: Some(repo.join("assets/Themes")) };
    let loaded = dirs.load(&|_| true);
    let mut state = loaded.state(&dirs);
    // Paths differ per system; the demo shows fixed ones.
    state.folder = r"C:\Users\you\AppData\Local\Burn\themes".into();
    state.agent_prompt = "Make me a theme for Burn (demo prompt). What I want: ".into();
    state.ideas_prompt = "Design 4 themes for Burn (demo prompt).".into();
    let looks: BTreeMap<&str, _> = loaded
        .available
        .iter()
        .map(|entry| {
            let one = Loaded {
                theme: entry.look.clone(),
                available: Vec::new(),
                selected: None,
                issues: Vec::new(),
                theme_dir: None,
            };
            (entry.id.as_str(), one.state(&dirs).look)
        })
        .collect();
    let mut json = serde_json::to_string_pretty(&serde_json::json!({ "state": state, "looks": looks })).unwrap();
    json.push('\n');
    json
}

#[test]
fn demo_themes_match_the_built_in_themes() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../ui/src/lib/demo-themes.json");
    let fresh = fixture();
    if std::env::var_os("BURN_UPDATE_DEMO_THEMES").is_some() {
        std::fs::write(&path, &fresh).unwrap();
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_default().replace("\r\n", "\n");
    assert!(
        committed == fresh,
        "ui/src/lib/demo-themes.json is out of date: run BURN_UPDATE_DEMO_THEMES=1 cargo test -p burn-core --test demo_themes"
    );
}
