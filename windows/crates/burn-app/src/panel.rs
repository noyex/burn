//! The panel: one frameless, transparent webview window that opens next to the widget, away
//! from the taskbar, and hides on Esc or a click anywhere else.

use crate::model::Model;
use burn_taskbar::layout::{Edge, Rect, panel_rect};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewWindow};

pub const LABEL: &str = "panel";
/// Space between the panel's blocks and the taskbar / screen edges, like Windows 11 flyouts.
/// The window itself carries a transparent margin for the blocks' shadows (see the UI), so the
/// visible gap is this plus that margin.
const GAP: f64 = 2.0;
/// A click on the widget right after the panel lost focus to it must not reopen it.
const REOPEN_GUARD: Duration = Duration::from_millis(300);
/// Hidden this long, the webview is suspended (its renderer frees memory and stops running scripts).
#[cfg(windows)]
const SUSPEND_AFTER: Duration = Duration::from_secs(180);

/// Where the panel hangs, in screen pixels.
#[derive(Clone, Copy, Debug)]
pub struct Placement {
    pub anchor: Rect,
    pub edge: Edge,
    pub work: Rect,
    pub scale: f64,
}

#[derive(Default)]
struct PanelState {
    visible: bool,
    hidden_at: Option<Instant>,
    placement: Option<Placement>,
    /// Content size in CSS pixels, as the page last reported it.
    size: Option<(f64, f64)>,
    /// Counts hides, so a pending suspend knows the panel was opened in between.
    hides: u64,
}

pub struct Panel {
    state: Mutex<PanelState>,
}

impl Panel {
    pub fn new() -> Panel {
        Panel { state: Mutex::new(PanelState::default()) }
    }

    pub fn is_visible(&self) -> bool {
        self.state.lock().map(|s| s.visible).unwrap_or(false)
    }

    /// Opens the panel at `placement`, or closes it when it's open.
    pub fn toggle(&self, app: &AppHandle, placement: Option<Placement>) {
        let Some(window) = app.get_webview_window(LABEL) else { return };
        {
            let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if s.visible {
                drop(s);
                self.hide(app);
                return;
            }
            if s.hidden_at.is_some_and(|t| t.elapsed() < REOPEN_GUARD) {
                return;
            }
            if placement.is_some() {
                s.placement = placement;
            }
            s.visible = true;
        }
        self.place(&window);
        #[cfg(windows)]
        set_webview_active(&window, true);
        let _ = window.show();
        if let Err(e) = window.set_focus() {
            crate::log!("focusing the panel failed: {e}");
        }
        let _ = app.emit_to(LABEL, "panel-shown", ());
        if let Some(model) = app.try_state::<Arc<Model>>() {
            model.panel_opened();
        }
        crate::update::panel_opened(app);
    }

    pub fn hide(&self, app: &AppHandle) {
        {
            let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if !s.visible {
                return;
            }
            s.visible = false;
            s.hidden_at = Some(Instant::now());
            s.hides += 1;
        }
        if let Some(window) = app.get_webview_window(LABEL) {
            let _ = window.hide();
            #[cfg(windows)]
            self.suspend_later(app);
        }
        let _ = app.emit_to(LABEL, "panel-hidden", ());
    }

    /// The page measured its content; resize the window around it.
    pub fn content_resized(&self, app: &AppHandle, width: f64, height: f64) {
        {
            let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if s.size == Some((width, height)) {
                return;
            }
            s.size = Some((width, height));
        }
        if let Some(window) = app.get_webview_window(LABEL) {
            self.place(&window);
        }
    }

    /// Suspends the webview once it has stayed hidden for `SUSPEND_AFTER`.
    #[cfg(windows)]
    fn suspend_later(&self, app: &AppHandle) {
        let hides = self.state.lock().map(|s| s.hides).unwrap_or(0);
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(SUSPEND_AFTER);
            let panel = app.state::<Panel>();
            let still_hidden = panel.state.lock().map(|s| !s.visible && s.hides == hides).unwrap_or(false);
            if still_hidden && let Some(window) = app.get_webview_window(LABEL) {
                set_webview_active(&window, false);
            }
        });
    }

    /// Sizes and positions the window from the last placement and content size.
    fn place(&self, window: &WebviewWindow) {
        let (placement, size) = {
            let s = self.state.lock().unwrap_or_else(|e| e.into_inner());
            (s.placement, s.size)
        };
        let (w, h) = size.unwrap_or((332.0, 480.0));
        let Some(p) = placement else {
            // No anchor (development off Windows): keep wherever the window is.
            let _ = window.set_size(tauri::LogicalSize::new(w, h));
            return;
        };
        let px = ((w * p.scale).ceil() as i32, (h * p.scale).ceil() as i32);
        let rect = panel_rect(p.edge, p.anchor, p.work, px, (GAP * p.scale).round() as i32);
        let _ = window.set_size(PhysicalSize::new(rect.width() as u32, rect.height() as u32));
        let _ = window.set_position(PhysicalPosition::new(rect.left, rect.top));
    }
}

/// Wakes the webview before the panel shows (making it visible resumes a suspended one), or
/// hides and suspends it. WebView2 only suspends an invisible webview.
#[cfg(windows)]
fn set_webview_active(window: &WebviewWindow, active: bool) {
    use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2_3, ICoreWebView2TrySuspendCompletedHandler};
    use windows::core::Interface;
    let _ = window.with_webview(move |webview| unsafe {
        let controller = webview.controller();
        let _ = controller.SetIsVisible(active);
        if !active
            && let Ok(core) = controller.CoreWebView2()
            && let Ok(core) = core.cast::<ICoreWebView2_3>()
        {
            match core.TrySuspend(None::<&ICoreWebView2TrySuspendCompletedHandler>) {
                Ok(()) => crate::log!("panel hidden for a while, webview suspended"),
                Err(e) => crate::log!("suspending the webview failed: {e:?}"),
            }
        }
    });
}
