use std::cell::RefCell;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{
    COLORREF, ERROR_ALREADY_EXISTS, GetLastError, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM,
};
use windows::Win32::Graphics::Direct2D::Common::{D2D_SIZE_U, D2D1_ALPHA_MODE_IGNORE, D2D1_PIXEL_FORMAT};
use windows::Win32::Graphics::Direct2D::{
    D2D1_FEATURE_LEVEL_DEFAULT, D2D1_HWND_RENDER_TARGET_PROPERTIES, D2D1_PRESENT_OPTIONS_NONE,
    D2D1_RENDER_TARGET_PROPERTIES, D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE,
    ID2D1HwndRenderTarget, ID2D1RenderTarget,
};
use windows::Win32::Graphics::Dwm::{
    DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND, DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_UNKNOWN;
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BLENDFUNCTION, BeginPaint, CreateBitmap, DeleteObject, EndPaint, GetMonitorInfoW,
    InvalidateRect, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromRect, PAINTSTRUCT,
};
use windows::Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, GetDpiForWindow, GetSystemMetricsForDpi, SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent, VK_ESCAPE};
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW, NOTIFYICONIDENTIFIER,
    Shell_NotifyIconGetRect, Shell_NotifyIconW, ShellExecuteW,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{BOOL, Interface, PCWSTR, w};

use super::render::{PANEL_WIDTH, Painter, Palette, panel_height};
use super::taskbar::{Taskbar, dump_tree};
use super::util::{hwnd_id, init_log, light_taskbar, log, log_path, os_description, to_rect, wide};
use crate::layout::{Edge, Rect, panel_rect, widget_rect};
use crate::model::{Entry, demo_sets};

const HOST_CLASS: PCWSTR = w!("BurnSpikeHost");
const WIDGET_CLASS: PCWSTR = w!("BurnSpikeWidget");
const PANEL_CLASS: PCWSTR = w!("BurnSpikePanel");

const WM_APP_TRAY: u32 = WM_APP + 1;
const WM_APP_REFRESH: u32 = WM_APP + 2;
const WM_APP_HIDE_PANEL: u32 = WM_APP + 3;

const TIMER_ID: usize = 1;
const TRAY_ID: u32 = 1;

const CMD_NEXT_DEMO: usize = 1;
const CMD_OPEN_LOG: usize = 2;
const CMD_QUIT: usize = 3;

// Distances in DIPs.
const WIDGET_GAP: f32 = 4.0;
/// Room kept for the tray when Explorer doesn't expose TrayNotifyWnd.
const FALLBACK_TRAY: f32 = 220.0;
/// Space between the panel and the taskbar / screen edges, like Windows 11 flyouts.
const PANEL_GAP: f32 = 12.0;

type WndProc = unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT;

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// Runs `f` on the app state, unless a window message arrived while it is already in use
/// (Win32 sends some messages synchronously from inside API calls). Returns None then.
fn with_app<R>(f: impl FnOnce(&mut App) -> R) -> Option<R> {
    APP.with(|cell| cell.try_borrow_mut().ok().and_then(|mut app| app.as_mut().map(f)))
}

/// What the widget was last drawn for; nothing is redrawn while it stays the same.
#[derive(Clone, Copy, PartialEq)]
struct DrawKey {
    taskbar: Taskbar,
    light: bool,
    hovered: bool,
    demo: usize,
}

struct App {
    instance: HINSTANCE,
    host: HWND,
    panel: HWND,
    widget: Option<HWND>,
    painter: Painter,
    demo: usize,
    sets: Vec<Vec<Entry>>,
    hovered: bool,
    drawn: Option<DrawKey>,
    /// Screen rect of the widget as last placed.
    widget_rect: Option<Rect>,
    taskbar: Option<Taskbar>,
    icon: HICON,
    panel_visible: bool,
    panel_hidden_at: Option<Instant>,
    panel_rt: Option<ID2D1HwndRenderTarget>,
    restacks: u32,
}

pub fn run() {
    init_log();
    log!("Burn spike {} on {}", env!("CARGO_PKG_VERSION"), os_description());
    log!("log file: {}", log_path().display());

    unsafe {
        let _mutex = CreateMutexW(None, true, w!("Local\\BurnSpikeSingleInstance"));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            log!("another instance is running, exiting");
            return;
        }
        // The manifest already asks for this; it fails harmlessly when that took effect.
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::Relaxed);

        let instance: HINSTANCE = GetModuleHandleW(None).expect("module handle").into();
        let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
        for (class, proc) in [
            (HOST_CLASS, host_proc as WndProc),
            (WIDGET_CLASS, widget_proc as WndProc),
            (PANEL_CLASS, panel_proc as WndProc),
        ] {
            let wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(proc),
                hInstance: instance,
                hCursor: cursor,
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                log!("RegisterClassExW failed: {:?}", windows::core::Error::from_thread());
                return;
            }
        }

        // A hidden top-level window, not a message-only one: only top-level windows get the
        // TaskbarCreated and WM_SETTINGCHANGE broadcasts.
        let host = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            HOST_CLASS,
            w!("Burn"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        )
        .expect("host window");
        let panel = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            PANEL_CLASS,
            w!("Burn"),
            WS_POPUP,
            0,
            0,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        )
        .expect("panel window");
        let round = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(
            panel,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &round as *const _ as *const _,
            size_of_val(&round) as u32,
        );

        let painter = match Painter::new() {
            Ok(p) => p,
            Err(e) => {
                log!("Direct2D/DirectWrite unavailable: {e:?}");
                return;
            }
        };
        let icon = tray_icon(GetDpiForWindow(host).max(96));
        APP.with(|cell| {
            *cell.borrow_mut() = Some(App {
                instance,
                host,
                panel,
                widget: None,
                painter,
                demo: 0,
                sets: demo_sets(),
                hovered: false,
                drawn: None,
                widget_rect: None,
                taskbar: None,
                icon,
                panel_visible: false,
                panel_hidden_at: None,
                panel_rt: None,
                restacks: 0,
            })
        });
        with_app(|app| {
            app.add_tray_icon();
            app.refresh(true);
        });
        SetTimer(Some(host), TIMER_ID, 1000, None);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        log!("exiting");
    }
}

impl App {
    fn entries(&self) -> &[Entry] {
        &self.sets[self.demo]
    }

    // ---- Widget ------------------------------------------------------------------------

    /// Finds the taskbar, (re)creates the widget inside it when needed, and redraws and
    /// re-places it when anything it depends on changed (or always, with `force`).
    fn refresh(&mut self, force: bool) {
        let Some(taskbar) = Taskbar::find() else {
            if self.taskbar.take().is_some() {
                log!("taskbar not found (Explorer restarting?)");
            }
            return;
        };
        let mut force = force;
        if self.taskbar.map(|t| t.hwnd) != Some(taskbar.hwnd) {
            log!(
                "taskbar {:#x}: rect {:?}, client origin {:?}, tray {:?}, edge {:?}, dpi {}",
                hwnd_id(taskbar.hwnd),
                taskbar.rect,
                taskbar.origin,
                taskbar.tray,
                taskbar.edge,
                taskbar.dpi
            );
            dump_tree(taskbar.hwnd);
            force = true;
        }
        self.taskbar = Some(taskbar);

        let alive = self
            .widget
            .is_some_and(|w| unsafe { IsWindow(Some(w)).as_bool() && GetParent(w).ok() == Some(taskbar.hwnd) });
        if !alive {
            self.widget = self.create_widget(taskbar.hwnd);
            force = true;
        }
        let Some(widget) = self.widget else { return };

        let key = DrawKey { taskbar, light: light_taskbar(), hovered: self.hovered, demo: self.demo };
        if !force && self.drawn == Some(key) {
            self.keep_on_top(widget, taskbar.hwnd);
            return;
        }
        if self.drawn.is_some_and(|d| d.taskbar != taskbar) {
            log!("taskbar changed: rect {:?}, tray {:?}, dpi {}", taskbar.rect, taskbar.tray, taskbar.dpi);
        }
        self.draw(widget, key);
    }

    fn draw(&mut self, widget: HWND, key: DrawKey) {
        let taskbar = key.taskbar;
        let scale = taskbar.dpi as f32 / 96.0;
        let thickness = if taskbar.edge.is_horizontal() { taskbar.thickness() } else { (48.0 * scale) as i32 };
        let frame = match self.painter.widget(self.entries(), taskbar.dpi, thickness, key.light, key.hovered) {
            Ok(f) => f,
            Err(e) => {
                log!("rendering the widget failed: {e:?}");
                return;
            }
        };
        let size = if taskbar.edge.is_horizontal() { (frame.width, frame.height) } else { (frame.height, frame.width) };
        let rect = widget_rect(
            taskbar.rect,
            taskbar.tray,
            taskbar.edge,
            size,
            (WIDGET_GAP * scale).round() as i32,
            (FALLBACK_TRAY * scale).round() as i32,
        );
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        unsafe {
            // Content first, then show, so the widget never appears empty.
            if let Err(e) = UpdateLayeredWindow(
                widget,
                None,
                None,
                Some(&SIZE { cx: rect.width(), cy: rect.height() }),
                Some(frame.dc),
                Some(&POINT { x: 0, y: 0 }),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            ) {
                log!("UpdateLayeredWindow failed: {e:?}");
            }
            if let Err(e) = SetWindowPos(
                widget,
                Some(HWND_TOP),
                rect.left - taskbar.origin.0,
                rect.top - taskbar.origin.1,
                rect.width(),
                rect.height(),
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            ) {
                log!("SetWindowPos failed: {e:?}");
            }
        }
        if self.widget_rect != Some(rect) || self.drawn.map(|d| d.light) != Some(key.light) {
            log!(
                "widget at {:?} ({}x{}), dpi {}, light taskbar {}",
                rect,
                rect.width(),
                rect.height(),
                taskbar.dpi,
                key.light
            );
        }
        self.widget_rect = Some(rect);
        self.drawn = Some(key);
    }

    fn create_widget(&mut self, taskbar: HWND) -> Option<HWND> {
        if let Some(old) = self.widget.take() {
            unsafe {
                if IsWindow(Some(old)).as_bool() {
                    let _ = DestroyWindow(old);
                }
            }
        }
        self.hovered = false;
        let created = unsafe {
            CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                WIDGET_CLASS,
                w!("Burn"),
                WS_CHILD | WS_CLIPSIBLINGS,
                0,
                0,
                0,
                0,
                Some(taskbar),
                None,
                Some(self.instance),
                None,
            )
        };
        match created {
            Ok(hwnd) => {
                log!("widget {:#x} created inside taskbar {:#x}", hwnd_id(hwnd), hwnd_id(taskbar));
                Some(hwnd)
            }
            Err(e) => {
                log!("creating the widget inside the taskbar failed: {e:?} (tray icon only)");
                None
            }
        }
    }

    /// Keeps the widget above the taskbar's own content, in case Explorer restacks it.
    fn keep_on_top(&mut self, widget: HWND, taskbar: HWND) {
        unsafe {
            if GetWindow(taskbar, GW_CHILD).ok() == Some(widget) {
                return;
            }
            self.restacks += 1;
            if self.restacks <= 5 {
                log!("widget was below other taskbar content, moving it to the top ({})", self.restacks);
            }
            let _ = SetWindowPos(widget, Some(HWND_TOP), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    fn set_hovered(&mut self, hovered: bool) {
        if self.hovered != hovered {
            self.hovered = hovered;
            self.refresh(false);
        }
    }

    // ---- Tray icon and menu ------------------------------------------------------------

    fn tray_data(&self) -> NOTIFYICONDATAW {
        let mut data = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.host,
            uID: TRAY_ID,
            uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
            uCallbackMessage: WM_APP_TRAY,
            hIcon: self.icon,
            ..Default::default()
        };
        let tip = wide("Burn (taskbar test)");
        data.szTip[..tip.len()].copy_from_slice(&tip);
        data
    }

    fn add_tray_icon(&self) {
        let ok = unsafe { Shell_NotifyIconW(NIM_ADD, &self.tray_data()) }.as_bool();
        log!("tray icon added: {ok}");
    }

    fn tray_rect(&self) -> Option<Rect> {
        let id = NOTIFYICONIDENTIFIER {
            cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32,
            hWnd: self.host,
            uID: TRAY_ID,
            ..Default::default()
        };
        unsafe { Shell_NotifyIconGetRect(&id).ok().map(to_rect) }
    }

    fn show_menu(&mut self) {
        unsafe {
            let Ok(menu) = CreatePopupMenu() else { return };
            let _ = AppendMenuW(menu, MF_STRING, CMD_NEXT_DEMO, w!("Next demo values"));
            let _ = AppendMenuW(menu, MF_STRING, CMD_OPEN_LOG, w!("Open log"));
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
            let _ = AppendMenuW(menu, MF_STRING, CMD_QUIT, w!("Quit Burn"));
            let mut pt = POINT::default();
            let _ = GetCursorPos(&mut pt);
            // Required for the menu to close when clicking elsewhere.
            let _ = SetForegroundWindow(self.host);
            let vertical =
                if self.taskbar.is_some_and(|t| t.edge == Edge::Top) { TPM_TOPALIGN } else { TPM_BOTTOMALIGN };
            let cmd = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | vertical,
                pt.x,
                pt.y,
                None,
                self.host,
                None,
            );
            let _ = PostMessageW(Some(self.host), WM_NULL, WPARAM(0), LPARAM(0));
            let _ = DestroyMenu(menu);
            match cmd.0 as usize {
                CMD_NEXT_DEMO => {
                    self.demo = (self.demo + 1) % self.sets.len();
                    log!("demo values set {}", self.demo);
                    self.refresh(true);
                    if self.panel_visible {
                        let _ = InvalidateRect(Some(self.panel), None, false);
                    }
                }
                CMD_OPEN_LOG => {
                    let path = wide(&log_path().to_string_lossy());
                    ShellExecuteW(None, w!("open"), PCWSTR(path.as_ptr()), None, None, SW_SHOWNORMAL);
                }
                CMD_QUIT => self.quit(),
                _ => {}
            }
        }
    }

    fn quit(&mut self) {
        log!("quit");
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.tray_data());
            if let Some(widget) = self.widget.take() {
                let _ = DestroyWindow(widget);
            }
            let _ = DestroyWindow(self.host);
        }
    }

    fn on_taskbar_created(&mut self) {
        log!("TaskbarCreated: Explorer restarted, re-adding the tray icon and the widget");
        self.add_tray_icon();
        self.widget = None;
        self.taskbar = None;
        self.refresh(true);
    }

    // ---- Panel -------------------------------------------------------------------------

    fn toggle_panel(&mut self, anchor: Option<Rect>, from: &str) {
        if self.panel_visible {
            self.hide_panel();
            return;
        }
        // The click that closed the panel by taking focus away shouldn't reopen it.
        if self.panel_hidden_at.is_some_and(|t| t.elapsed() < Duration::from_millis(300)) {
            return;
        }
        let Some(anchor) = anchor else {
            log!("no anchor to open the panel from ({from})");
            return;
        };
        let taskbar = self.taskbar.or_else(Taskbar::find);
        let edge = taskbar.map_or(Edge::Bottom, |t| t.edge);
        let dpi = taskbar.map_or(96, |t| t.dpi);
        let scale = dpi as f32 / 96.0;
        let work = unsafe {
            let r = RECT { left: anchor.left, top: anchor.top, right: anchor.right, bottom: anchor.bottom };
            let monitor = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                log!("GetMonitorInfoW failed");
                return;
            }
            to_rect(info.rcWork)
        };
        let size = ((PANEL_WIDTH * scale).ceil() as i32, (panel_height(self.entries().len()) * scale).ceil() as i32);
        let rect = panel_rect(edge, anchor, work, size, (PANEL_GAP * scale).round() as i32);
        log!("panel from {from}: anchor {anchor:?}, edge {edge:?}, work area {work:?} -> {rect:?}");

        let light = light_taskbar();
        unsafe {
            let dark = BOOL::from(!light);
            let _ = DwmSetWindowAttribute(
                self.panel,
                DWMWA_USE_IMMERSIVE_DARK_MODE,
                &dark as *const _ as *const _,
                size_of::<BOOL>() as u32,
            );
            let _ = SetWindowPos(
                self.panel,
                Some(HWND_TOPMOST),
                rect.left,
                rect.top,
                rect.width(),
                rect.height(),
                SWP_SHOWWINDOW,
            );
            if let Some(rt) = &self.panel_rt {
                let _ = rt.Resize(&D2D_SIZE_U { width: rect.width() as u32, height: rect.height() as u32 });
            }
            self.panel_visible = true;
            let focused = SetForegroundWindow(self.panel).as_bool();
            if !focused {
                log!("SetForegroundWindow(panel) refused: it won't close on outside clicks");
            }
            let _ = InvalidateRect(Some(self.panel), None, false);
        }
    }

    fn hide_panel(&mut self) {
        if !self.panel_visible {
            return;
        }
        self.panel_visible = false;
        self.panel_hidden_at = Some(Instant::now());
        unsafe {
            let _ = ShowWindow(self.panel, SW_HIDE);
        }
    }

    fn paint_panel(&mut self) {
        let light = light_taskbar();
        let dpi = unsafe { GetDpiForWindow(self.panel) }.max(96);
        let scale = dpi as f32 / 96.0;
        if self.panel_rt.is_none() {
            let mut r = RECT::default();
            unsafe {
                let _ = GetClientRect(self.panel, &mut r);
            }
            let props = D2D1_RENDER_TARGET_PROPERTIES {
                r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
                pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_UNKNOWN, alphaMode: D2D1_ALPHA_MODE_IGNORE },
                dpiX: dpi as f32,
                dpiY: dpi as f32,
                usage: D2D1_RENDER_TARGET_USAGE_NONE,
                minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
            };
            let hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES {
                hwnd: self.panel,
                pixelSize: D2D_SIZE_U { width: r.right as u32, height: r.bottom as u32 },
                presentOptions: D2D1_PRESENT_OPTIONS_NONE,
            };
            match unsafe { self.painter.d2d().CreateHwndRenderTarget(&props, &hwnd_props) } {
                Ok(rt) => self.panel_rt = Some(rt),
                Err(e) => {
                    log!("panel render target failed: {e:?}");
                    return;
                }
            }
        }
        let Some(rt) = self.panel_rt.clone() else { return };
        let Ok(target) = rt.cast::<ID2D1RenderTarget>() else { return };
        let palette = Palette::new(light);
        unsafe {
            rt.SetDpi(dpi as f32, dpi as f32);
            rt.BeginDraw();
            let drawn = self.painter.panel(&target, self.entries(), light, PANEL_WIDTH, scale, Some(palette.panel));
            if let Err(e) = rt.EndDraw(None, None).and(drawn) {
                log!("panel draw failed: {e:?}");
                self.panel_rt = None;
            }
        }
    }
}

/// The app icon at the tray's small-icon size.
fn tray_icon(dpi: u32) -> HICON {
    let fallback = || unsafe { LoadIconW(None, IDI_APPLICATION).unwrap_or_default() };
    let side = unsafe { GetSystemMetricsForDpi(SM_CXSMICON, dpi) }.max(16) as u32;
    let Ok(source) = tiny_skia::Pixmap::decode_png(include_bytes!("../../assets/icon-64.png")) else {
        return fallback();
    };
    let Some(mut pixmap) = tiny_skia::Pixmap::new(side, side) else { return fallback() };
    let s = side as f32 / source.width() as f32;
    pixmap.draw_pixmap(
        0,
        0,
        source.as_ref(),
        &tiny_skia::PixmapPaint { quality: tiny_skia::FilterQuality::Bicubic, ..Default::default() },
        tiny_skia::Transform::from_scale(s, s),
        None,
    );
    // Icons take straight (not premultiplied) BGRA.
    let bgra: Vec<u8> = pixmap
        .pixels()
        .iter()
        .flat_map(|p| {
            let c = p.demultiply();
            [c.blue(), c.green(), c.red(), c.alpha()]
        })
        .collect();
    unsafe {
        let color = CreateBitmap(side as i32, side as i32, 1, 32, Some(bgra.as_ptr() as *const _));
        let mask = CreateBitmap(side as i32, side as i32, 1, 1, None);
        let info = ICONINFO { fIcon: true.into(), xHotspot: 0, yHotspot: 0, hbmMask: mask, hbmColor: color };
        let icon = CreateIconIndirect(&info).unwrap_or_else(|_| fallback());
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        icon
    }
}

fn loword(v: usize) -> u32 {
    (v & 0xffff) as u32
}

unsafe extern "system" fn host_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let taskbar_created = TASKBAR_CREATED.load(Ordering::Relaxed);
    match msg {
        m if m == taskbar_created && m != 0 => {
            with_app(|app| app.on_taskbar_created());
        }
        WM_TIMER => {
            with_app(|app| app.refresh(false));
        }
        WM_SETTINGCHANGE | WM_DISPLAYCHANGE | WM_DPICHANGED => unsafe {
            // Let Explorer apply the change first.
            let _ = PostMessageW(Some(hwnd), WM_APP_REFRESH, WPARAM(0), LPARAM(0));
        },
        WM_APP_REFRESH => {
            with_app(|app| app.refresh(true));
        }
        WM_APP_TRAY => match loword(lparam.0 as usize) {
            WM_LBUTTONUP => {
                with_app(|app| {
                    let anchor = app.tray_rect();
                    app.toggle_panel(anchor, "tray icon");
                });
            }
            WM_RBUTTONUP | WM_CONTEXTMENU => {
                with_app(|app| app.show_menu());
            }
            _ => {}
        },
        WM_DESTROY => unsafe { PostQuitMessage(0) },
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}

unsafe extern "system" fn widget_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        // Clicking shouldn't activate the taskbar; the panel takes focus itself.
        WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
        WM_MOUSEMOVE => {
            with_app(|app| {
                if !app.hovered {
                    let mut track = TRACKMOUSEEVENT {
                        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 0,
                    };
                    unsafe {
                        let _ = TrackMouseEvent(&mut track);
                    }
                    app.set_hovered(true);
                }
            });
        }
        WM_MOUSELEAVE => {
            with_app(|app| app.set_hovered(false));
        }
        WM_LBUTTONUP => {
            with_app(|app| {
                let anchor = app.widget_rect;
                app.toggle_panel(anchor, "widget");
            });
        }
        WM_RBUTTONUP => {
            with_app(|app| app.show_menu());
        }
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}

unsafe extern "system" fn panel_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_ACTIVATE if loword(wparam.0) == WA_INACTIVE => {
            // Sent synchronously while the state may be in use (hiding activates something
            // else), so retry from the queue in that case.
            if with_app(|app| app.hide_panel()).is_none() {
                unsafe {
                    let _ = PostMessageW(Some(hwnd), WM_APP_HIDE_PANEL, WPARAM(0), LPARAM(0));
                }
            }
        }
        WM_APP_HIDE_PANEL => {
            with_app(|app| app.hide_panel());
        }
        WM_KEYDOWN if wparam.0 == VK_ESCAPE.0 as usize => {
            with_app(|app| app.hide_panel());
        }
        WM_SIZE => {
            with_app(|app| {
                if let Some(rt) = &app.panel_rt {
                    let (w, h) = (loword(lparam.0 as usize), loword((lparam.0 as usize) >> 16));
                    unsafe {
                        let _ = rt.Resize(&D2D_SIZE_U { width: w, height: h });
                    }
                }
            });
        }
        WM_PAINT => unsafe {
            let mut ps = PAINTSTRUCT::default();
            BeginPaint(hwnd, &mut ps);
            with_app(|app| app.paint_panel());
            let _ = EndPaint(hwnd, &ps);
        },
        WM_ERASEBKGND => return LRESULT(1),
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}
