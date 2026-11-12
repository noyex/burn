//! Finding Explorer's taskbar and the free spot next to its notification area.

use windows::Win32::Foundation::{HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Gdi::ClientToScreen;
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Shell::{
    ABE_BOTTOM, ABE_LEFT, ABE_RIGHT, ABE_TOP, ABM_GETTASKBARPOS, APPBARDATA, SHAppBarMessage,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumChildWindows, FindWindowExW, FindWindowW, GetClassNameW, GetParent, GetWindowRect, IsWindowVisible,
};
use windows::core::{BOOL, w};

use super::util::{hwnd_id, log, to_rect};
use crate::layout::{Edge, Rect};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Taskbar {
    pub hwnd: HWND,
    /// Screen rect of the bar.
    pub rect: Rect,
    /// Screen position of the bar's client origin, for converting child coordinates.
    pub origin: (i32, i32),
    /// Screen rect of the notification area (tray icons and clock), if Explorer exposes it.
    pub tray: Option<Rect>,
    pub edge: Edge,
    pub dpi: u32,
}

impl Taskbar {
    /// The primary taskbar, or None while Explorer isn't running.
    pub fn find() -> Option<Taskbar> {
        unsafe {
            let hwnd = FindWindowW(w!("Shell_TrayWnd"), None).ok()?;
            let mut r = RECT::default();
            GetWindowRect(hwnd, &mut r).ok()?;
            let rect = to_rect(r);
            let mut origin = POINT::default();
            let _ = ClientToScreen(hwnd, &mut origin);
            let tray = FindWindowExW(Some(hwnd), None, w!("TrayNotifyWnd"), None).ok().and_then(|t| {
                let mut tr = RECT::default();
                GetWindowRect(t, &mut tr).ok().map(|_| to_rect(tr))
            });
            let dpi = match GetDpiForWindow(hwnd) {
                0 => 96,
                d => d,
            };
            Some(Taskbar { hwnd, rect, origin: (origin.x, origin.y), tray, edge: edge(hwnd, rect), dpi })
        }
    }

    /// Thickness across the bar, in pixels.
    pub fn thickness(&self) -> i32 {
        if self.edge.is_horizontal() { self.rect.height() } else { self.rect.width() }
    }
}

fn edge(hwnd: HWND, rect: Rect) -> Edge {
    let mut data = APPBARDATA { cbSize: size_of::<APPBARDATA>() as u32, hWnd: hwnd, ..Default::default() };
    if unsafe { SHAppBarMessage(ABM_GETTASKBARPOS, &mut data) } != 0 {
        match data.uEdge {
            ABE_LEFT => return Edge::Left,
            ABE_TOP => return Edge::Top,
            ABE_RIGHT => return Edge::Right,
            ABE_BOTTOM => return Edge::Bottom,
            _ => {}
        }
    }
    // Guess from the shape: a wide bar is horizontal, and most bars are at the bottom.
    if rect.width() >= rect.height() { Edge::Bottom } else { Edge::Left }
}

/// Logs every child window of the taskbar, to see what a given Windows build exposes.
pub fn dump_tree(taskbar: HWND) {
    log!("taskbar children of {:#x}:", hwnd_id(taskbar));
    unsafe extern "system" fn visit(hwnd: HWND, _: LPARAM) -> BOOL {
        unsafe {
            let mut class = [0u16; 128];
            let len = GetClassNameW(hwnd, &mut class) as usize;
            let mut r = RECT::default();
            let _ = GetWindowRect(hwnd, &mut r);
            let parent = GetParent(hwnd).map(hwnd_id).unwrap_or(0);
            log!(
                "  {:#x} parent {:#x} {:<48} {:?} visible={}",
                hwnd_id(hwnd),
                parent,
                String::from_utf16_lossy(&class[..len]),
                to_rect(r),
                IsWindowVisible(hwnd).as_bool()
            );
        }
        BOOL(1)
    }
    unsafe {
        let _ = EnumChildWindows(Some(taskbar), Some(visit), LPARAM(0));
    }
}
