//! The Windows side: the widget inside Explorer's taskbar and the tray icon fallback.

pub mod autostart;
pub mod clipboard;
pub mod console;
mod render;
mod shell;
mod taskbar;
mod util;

pub use shell::{
    Anchor, Host, copy_images, current_anchor, set_alert_colors, set_entries, set_tray_only, shutdown, start,
};
pub use util::{init_log, light_taskbar, log_path, os_description, write_log};
