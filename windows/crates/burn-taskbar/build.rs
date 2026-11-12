use embed_manifest::manifest::DpiAwareness;
use embed_manifest::{embed_manifest, new_manifest};

fn main() {
    // The default manifest declares Windows 8+ support, which layered child windows need
    // (the widget is one, parented into the taskbar).
    if std::env::var_os("CARGO_CFG_WINDOWS").is_some() {
        embed_manifest(new_manifest("Burn").dpi_awareness(DpiAwareness::PerMonitorV2))
            .expect("embed the Windows manifest");
    }
    println!("cargo:rerun-if-changed=build.rs");
}
