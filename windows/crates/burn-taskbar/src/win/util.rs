use std::ffi::c_void;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_DWORD, RRF_RT_REG_SZ, RegGetValueW,
};
use windows::core::{PCWSTR, w};

use crate::layout::Rect;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

pub fn to_rect(r: RECT) -> Rect {
    Rect::new(r.left, r.top, r.right, r.bottom)
}

pub fn hwnd_id(hwnd: HWND) -> usize {
    hwnd.0 as usize
}

// ---- Log -------------------------------------------------------------------------------

static LOG: Mutex<Option<File>> = Mutex::new(None);
static START: OnceLock<Instant> = OnceLock::new();

pub fn log_path() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    base.join("Burn").join("spike.log")
}

pub fn init_log() {
    START.get_or_init(Instant::now);
    let path = log_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(file) = File::create(&path) {
        *LOG.lock().unwrap() = Some(file);
    }
}

pub fn write_log(line: &str) {
    let secs = START.get_or_init(Instant::now).elapsed().as_secs_f64();
    if let Some(file) = LOG.lock().unwrap().as_mut() {
        let _ = writeln!(file, "[{secs:>9.3}] {line}");
        let _ = file.flush();
    }
}

macro_rules! log {
    ($($t:tt)*) => { $crate::win::util::write_log(&format!($($t)*)) };
}
pub(crate) use log;

// ---- Registry --------------------------------------------------------------------------

fn reg_dword(root: HKEY, path: PCWSTR, name: PCWSTR) -> Option<u32> {
    let mut data = 0u32;
    let mut size = 4u32;
    let status = unsafe {
        RegGetValueW(
            root,
            path,
            name,
            RRF_RT_REG_DWORD,
            None,
            Some(&mut data as *mut u32 as *mut c_void),
            Some(&mut size),
        )
    };
    status.is_ok().then_some(data)
}

fn reg_string(root: HKEY, path: PCWSTR, name: PCWSTR) -> Option<String> {
    let mut buf = [0u16; 256];
    let mut size = (buf.len() * 2) as u32;
    let status = unsafe {
        RegGetValueW(root, path, name, RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut c_void), Some(&mut size))
    };
    if status.is_err() {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(String::from_utf16_lossy(&buf[..len]))
}

/// The taskbar follows the "Windows mode" setting, not the app mode.
pub fn light_taskbar() -> bool {
    reg_dword(
        HKEY_CURRENT_USER,
        w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        w!("SystemUsesLightTheme"),
    ) == Some(1)
}

pub fn os_description() -> String {
    let key = w!("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion");
    let build = reg_string(HKEY_LOCAL_MACHINE, key, w!("CurrentBuild")).unwrap_or_default();
    let ubr = reg_dword(HKEY_LOCAL_MACHINE, key, w!("UBR")).unwrap_or(0);
    let version = reg_string(HKEY_LOCAL_MACHINE, key, w!("DisplayVersion")).unwrap_or_default();
    let edition = reg_string(HKEY_LOCAL_MACHINE, key, w!("EditionID")).unwrap_or_default();
    // ProductName still says "Windows 10" on Windows 11, so go by the build number.
    let name = if build.parse::<u32>().unwrap_or(0) >= 22_000 { "Windows 11" } else { "Windows 10" };
    format!("{name} {edition} {version} (build {build}.{ubr})")
}
