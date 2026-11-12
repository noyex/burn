//! The Windows shell of the spike. One UI thread owns every window, including the widget
//! that lives inside Explorer's taskbar: that window's input queue is shared with
//! Explorer, so nothing on this thread may block.

mod app;
mod render;
mod taskbar;
mod util;

pub use app::run;
