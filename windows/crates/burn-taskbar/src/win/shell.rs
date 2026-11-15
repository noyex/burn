//! The native part of Burn's Windows shell: the widget inside Explorer's taskbar and the
//! notification-area icon that replaces it when it can't be embedded (or the user asks for it).
//!
//! Everything runs on the app's UI thread, whose message loop belongs to the host application
//! (Tauri's event loop dispatches to these window procedures). The widget's input queue is
//! shared with Explorer, so nothing here may block.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicU32, Ordering};

use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BLENDFUNCTION, CreateBitmap, DeleteObject, GetMonitorInfoW, MONITOR_DEFAULTTONEAREST,
    MONITORINFO, MonitorFromRect,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent};
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW, NOTIFYICONIDENTIFIER,
    Shell_NotifyIconGetRect, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use windows::core::{PCWSTR, w};

use super::clipboard::{self, ClipboardImage, ImageFile};
use super::render::Painter;
use super::taskbar::{Taskbar, dump_tree};
use super::util::{hwnd_id, light_taskbar, log, to_rect, wide};
use crate::layout::{Edge, Rect, widget_rect, work_clear_of_taskbar};
use crate::model::Entry;

const HOST_CLASS: PCWSTR = w!("BurnHost");
const WIDGET_CLASS: PCWSTR = w!("BurnWidget");

const WM_APP_TRAY: u32 = WM_APP + 1;
const WM_APP_REFRESH: u32 = WM_APP + 2;

const TIMER_ID: usize = 1;
const TRAY_ID: u32 = 1;

const CMD_OPEN: usize = 1;
const CMD_OPEN_LOG: usize = 2;
const CMD_QUIT: usize = 3;

/// Space between the widget and the notification area, in DIPs.
const WIDGET_GAP: f32 = 4.0;
/// Room kept for the tray when Explorer doesn't expose TrayNotifyWnd.
const FALLBACK_TRAY: f32 = 220.0;
/// Seconds without a placed widget before the tray icon stands in for it.
const TRAY_FALLBACK_TICKS: u32 = 3;

type WndProc = unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT;

static TASKBAR_CREATED: AtomicU32 = AtomicU32::new(0);

/// Where the user clicked Burn, in screen pixels, and the space the panel may use.
#[derive(Clone, Copy, Debug)]
pub struct Anchor {
    pub rect: Rect,
    /// The screen edge the taskbar sits on; the panel opens away from it.
    pub edge: Edge,
    /// Work area of the monitor (the screen minus the taskbar, auto-hidden or not).
    pub work: Rect,
    pub dpi: u32,
}

/// What the application does in response to the shell. Called on the UI thread, never while
/// the shell's own state is borrowed, so it may call back into this module.
pub trait Host {
    /// Left click on the widget or the tray icon, or "Open Burn" in the menu.
    fn activate(&self, anchor: Option<Anchor>);
    /// Right click menu opened: the panel should get out of the way.
    fn menu_opened(&self);
    fn open_log(&self);
    fn quit(&self);
    /// Someone copied an image the shelf should keep.
    fn clipboard_image(&self, image: ClipboardImage);
}

thread_local! {
    static SHELL: RefCell<Option<Shell>> = const { RefCell::new(None) };
    static HOST: RefCell<Option<Rc<dyn Host>>> = const { RefCell::new(None) };
}

/// Runs `f` on the shell state, unless a window message arrived while it is already in use
/// (Win32 sends some messages synchronously from inside API calls). Returns None then.
fn with_shell<R>(f: impl FnOnce(&mut Shell) -> R) -> Option<R> {
    SHELL.with(|cell| cell.try_borrow_mut().ok().and_then(|mut s| s.as_mut().map(f)))
}

fn host() -> Option<Rc<dyn Host>> {
    HOST.with(|h| h.borrow().clone())
}

/// What the widget was last drawn for; nothing is redrawn while it stays the same.
#[derive(Clone, PartialEq)]
struct DrawKey {
    taskbar: Taskbar,
    light: bool,
    hovered: bool,
    entries: Vec<Entry>,
}

struct Shell {
    instance: HINSTANCE,
    host: HWND,
    widget: Option<HWND>,
    painter: Painter,
    entries: Vec<Entry>,
    tray_only: bool,
    hovered: bool,
    drawn: Option<DrawKey>,
    /// Screen rect of the widget as last placed.
    widget_rect: Option<Rect>,
    taskbar: Option<Taskbar>,
    icon: HICON,
    tray_shown: bool,
    /// Timer ticks since the widget was last placed.
    ticks_without_widget: u32,
    restacks: u32,
}

/// Creates the shell's windows. Call once, on the thread that runs the message loop.
pub fn start(host: Rc<dyn Host>, entries: Vec<Entry>, tray_only: bool) -> windows::core::Result<()> {
    unsafe {
        TASKBAR_CREATED.store(RegisterWindowMessageW(w!("TaskbarCreated")), Ordering::Relaxed);
        let instance: HINSTANCE = GetModuleHandleW(None)?.into();
        let cursor = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
        for (class, proc) in [(HOST_CLASS, host_proc as WndProc), (WIDGET_CLASS, widget_proc as WndProc)] {
            let wc = WNDCLASSEXW {
                cbSize: size_of::<WNDCLASSEXW>() as u32,
                lpfnWndProc: Some(proc),
                hInstance: instance,
                hCursor: cursor,
                lpszClassName: class,
                ..Default::default()
            };
            if RegisterClassExW(&wc) == 0 {
                return Err(windows::core::Error::from_thread());
            }
        }
        // A hidden top-level window, not a message-only one: only top-level windows get the
        // TaskbarCreated and WM_SETTINGCHANGE broadcasts.
        let hwnd = CreateWindowExW(
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
        )?;
        let painter = Painter::new()?;
        let icon = tray_icon(GetDpiForWindow(hwnd).max(96));
        HOST.with(|h| *h.borrow_mut() = Some(host));
        SHELL.with(|cell| {
            *cell.borrow_mut() = Some(Shell {
                instance,
                host: hwnd,
                widget: None,
                painter,
                entries,
                tray_only,
                hovered: false,
                drawn: None,
                widget_rect: None,
                taskbar: None,
                icon,
                tray_shown: false,
                ticks_without_widget: 0,
                restacks: 0,
            })
        });
        with_shell(|s| s.refresh(true));
        SetTimer(Some(hwnd), TIMER_ID, 1000, None);
        clipboard::listen(hwnd);
    }
    Ok(())
}

/// New values for the widget.
pub fn set_entries(entries: Vec<Entry>) {
    with_shell(|s| {
        if s.entries != entries {
            s.entries = entries;
            s.refresh(false);
        }
    });
}

/// Tray icon instead of the widget.
pub fn set_tray_only(on: bool) {
    with_shell(|s| {
        if s.tray_only != on {
            s.tray_only = on;
            log!("tray only: {on}");
            s.refresh(true);
        }
    });
}

/// Where Burn sits right now, for opening the panel without a click (e.g. a second launch).
pub fn current_anchor() -> Option<Anchor> {
    with_shell(|s| s.anchor()).flatten()
}

/// Puts shelf images on the clipboard (on the UI thread, which owns the clipboard window).
pub fn copy_images(images: &[ImageFile]) -> bool {
    with_shell(|s| s.host).is_some_and(|hwnd| clipboard::write_images(hwnd, images))
}

/// Removes the widget and the tray icon. Call before the process exits.
pub fn shutdown() {
    with_shell(|s| {
        s.hide_tray();
        if let Some(widget) = s.widget.take() {
            unsafe {
                let _ = DestroyWindow(widget);
            }
        }
        unsafe {
            let _ = KillTimer(Some(s.host), TIMER_ID);
        }
    });
}

impl Shell {
    // ---- Widget ------------------------------------------------------------------------

    /// Finds the taskbar, (re)creates the widget inside it when needed, redraws and re-places
    /// it when anything it depends on changed (or always, with `force`), and shows the tray
    /// icon while there is no widget.
    fn refresh(&mut self, force: bool) {
        let placed = self.refresh_widget(force);
        if placed {
            self.ticks_without_widget = 0;
        } else {
            self.ticks_without_widget = self.ticks_without_widget.saturating_add(1);
        }
        let want_tray = self.tray_only || self.ticks_without_widget >= TRAY_FALLBACK_TICKS;
        if want_tray && !self.tray_shown {
            self.show_tray();
        } else if !want_tray && self.tray_shown {
            self.hide_tray();
        }
    }

    /// True when the widget is on the taskbar.
    fn refresh_widget(&mut self, force: bool) -> bool {
        if self.tray_only {
            if let Some(widget) = self.widget.take() {
                unsafe {
                    let _ = DestroyWindow(widget);
                }
                self.drawn = None;
                self.widget_rect = None;
            }
            return false;
        }
        let Some(taskbar) = Taskbar::find() else {
            if self.taskbar.take().is_some() {
                log!("taskbar not found (Explorer restarting?)");
            }
            return false;
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
        let Some(widget) = self.widget else { return false };

        let key = DrawKey { taskbar, light: light_taskbar(), hovered: self.hovered, entries: self.entries.clone() };
        if !force && self.drawn.as_ref() == Some(&key) {
            self.keep_on_top(widget, taskbar.hwnd);
            return true;
        }
        if self.drawn.as_ref().is_some_and(|d| d.taskbar != taskbar) {
            log!("taskbar changed: rect {:?}, tray {:?}, dpi {}", taskbar.rect, taskbar.tray, taskbar.dpi);
        }
        self.draw(widget, key)
    }

    fn draw(&mut self, widget: HWND, key: DrawKey) -> bool {
        let taskbar = key.taskbar;
        let scale = taskbar.dpi as f32 / 96.0;
        if !taskbar.edge.is_horizontal() {
            // Only Windows 10 docks the taskbar sideways; a one-row widget doesn't fit there.
            if self.drawn.is_none() {
                log!("vertical taskbar ({:?}) isn't supported, tray icon only", taskbar.edge);
            }
            unsafe {
                let _ = ShowWindow(widget, SW_HIDE);
            }
            self.drawn = Some(key);
            self.widget_rect = None;
            return false;
        }
        if key.entries.is_empty() {
            // Nothing to show yet (no provider signed in, or limits still loading): no empty pill.
            unsafe {
                let _ = ShowWindow(widget, SW_HIDE);
            }
            self.drawn = Some(key);
            self.widget_rect = None;
            return true;
        }
        let frame = match self.painter.widget(&key.entries, taskbar.dpi, taskbar.thickness(), key.light, key.hovered) {
            Ok(f) => f,
            Err(e) => {
                log!("rendering the widget failed: {e:?}");
                return false;
            }
        };
        let rect = widget_rect(
            taskbar.rect,
            taskbar.tray,
            taskbar.edge,
            (frame.width, frame.height),
            (WIDGET_GAP * scale).round() as i32,
            (FALLBACK_TRAY * scale).round() as i32,
        );
        let blend = BLENDFUNCTION {
            BlendOp: AC_SRC_OVER as u8,
            BlendFlags: 0,
            SourceConstantAlpha: 255,
            AlphaFormat: AC_SRC_ALPHA as u8,
        };
        let mut placed = true;
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
                placed = false;
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
                placed = false;
            }
        }
        if self.widget_rect != Some(rect) || self.drawn.as_ref().map(|d| d.light) != Some(key.light) {
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
        // A failed draw is retried on the next tick.
        self.drawn = placed.then_some(key);
        placed
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
                log!("creating the widget inside the taskbar failed: {e:?} (tray icon instead)");
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

    /// The widget's rect when it's on the taskbar, else the tray icon's.
    fn anchor(&self) -> Option<Anchor> {
        let rect = self.widget_rect.or_else(|| self.tray_rect())?;
        let taskbar = self.taskbar.or_else(Taskbar::find);
        let work = unsafe {
            let r = RECT { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom };
            let monitor = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO { cbSize: size_of::<MONITORINFO>() as u32, ..Default::default() };
            if !GetMonitorInfoW(monitor, &mut info).as_bool() {
                log!("GetMonitorInfoW failed");
                return None;
            }
            let work = to_rect(info.rcWork);
            match taskbar {
                Some(t) => work_clear_of_taskbar(work, to_rect(info.rcMonitor), t.rect, t.edge),
                None => work,
            }
        };
        Some(Anchor { rect, edge: taskbar.map_or(Edge::Bottom, |t| t.edge), work, dpi: taskbar.map_or(96, |t| t.dpi) })
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
        let tip = wide("Burn");
        data.szTip[..tip.len()].copy_from_slice(&tip);
        data
    }

    fn show_tray(&mut self) {
        self.tray_shown = unsafe { Shell_NotifyIconW(NIM_ADD, &self.tray_data()) }.as_bool();
        log!("tray icon shown: {}", self.tray_shown);
    }

    fn hide_tray(&mut self) {
        if self.tray_shown {
            unsafe {
                let _ = Shell_NotifyIconW(NIM_DELETE, &self.tray_data());
            }
            self.tray_shown = false;
            log!("tray icon removed, the widget is back");
        }
    }

    fn tray_rect(&self) -> Option<Rect> {
        if !self.tray_shown {
            return None;
        }
        let id = NOTIFYICONIDENTIFIER {
            cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32,
            hWnd: self.host,
            uID: TRAY_ID,
            ..Default::default()
        };
        unsafe { Shell_NotifyIconGetRect(&id).ok().map(to_rect) }
    }

    /// Shows the menu and returns the chosen command. The menu's modal loop runs while the
    /// state is borrowed, so messages that need it (hover leave) are dropped: the hover is
    /// reset afterwards.
    fn run_menu(&mut self) -> usize {
        unsafe {
            let Ok(menu) = CreatePopupMenu() else { return 0 };
            let _ = AppendMenuW(menu, MF_STRING, CMD_OPEN, w!("Open Burn"));
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
            self.hovered = false;
            self.refresh(false);
            cmd.0 as usize
        }
    }

    fn on_taskbar_created(&mut self) {
        log!("TaskbarCreated: Explorer restarted, re-adding the widget or the tray icon");
        // The old icon went down with Explorer.
        self.tray_shown = false;
        // refresh() replaces the widget if it went down with the old taskbar.
        self.taskbar = None;
        self.refresh(true);
    }
}

/// Left click: opens or closes the panel. Called outside the state borrow.
fn activate() {
    let anchor = with_shell(|s| s.anchor()).flatten();
    if let Some(h) = host() {
        h.activate(anchor);
    }
}

fn menu() {
    if let Some(h) = host() {
        h.menu_opened();
    }
    let cmd = with_shell(|s| s.run_menu()).unwrap_or(0);
    let Some(h) = host() else { return };
    match cmd {
        CMD_OPEN => activate(),
        CMD_OPEN_LOG => h.open_log(),
        CMD_QUIT => h.quit(),
        _ => {}
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
            with_shell(|s| s.on_taskbar_created());
        }
        WM_TIMER => {
            with_shell(|s| s.refresh(false));
        }
        WM_SETTINGCHANGE | WM_DISPLAYCHANGE | WM_DPICHANGED => unsafe {
            // Let Explorer apply the change first.
            let _ = PostMessageW(Some(hwnd), WM_APP_REFRESH, WPARAM(0), LPARAM(0));
        },
        WM_APP_REFRESH => {
            with_shell(|s| s.refresh(true));
        }
        WM_CLIPBOARDUPDATE => {
            if let Some(image) = clipboard::read_image(hwnd)
                && let Some(h) = host()
            {
                h.clipboard_image(image);
            }
        }
        WM_APP_TRAY => match loword(lparam.0 as usize) {
            WM_LBUTTONUP => activate(),
            WM_RBUTTONUP | WM_CONTEXTMENU => menu(),
            _ => {}
        },
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}

unsafe extern "system" fn widget_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        // Clicking shouldn't activate the taskbar; the panel takes focus itself.
        WM_MOUSEACTIVATE => return LRESULT(MA_NOACTIVATE as isize),
        WM_MOUSEMOVE => {
            with_shell(|s| {
                if !s.hovered {
                    let mut track = TRACKMOUSEEVENT {
                        cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                        dwFlags: TME_LEAVE,
                        hwndTrack: hwnd,
                        dwHoverTime: 0,
                    };
                    unsafe {
                        let _ = TrackMouseEvent(&mut track);
                    }
                    s.set_hovered(true);
                }
            });
        }
        WM_MOUSELEAVE => {
            with_shell(|s| s.set_hovered(false));
        }
        WM_LBUTTONUP => activate(),
        WM_RBUTTONUP => menu(),
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}
