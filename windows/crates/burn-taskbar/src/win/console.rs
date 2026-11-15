//! Printing from `burn.exe`, a GUI-subsystem program that has no console of its own.

use std::fs::OpenOptions;
use std::io::Write;
use std::os::windows::io::AsRawHandle;

use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::Console::{
    ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_OUTPUT_HANDLE, WriteConsoleW,
};

/// Prints a line to stdout. When stdout is a pipe or a file (how coding agents run Burn) it is
/// written there. Started from an interactive console, a GUI program has no stdout: the parent's
/// console is attached and written to directly.
pub fn print_line(text: &str) {
    if unsafe { GetStdHandle(STD_OUTPUT_HANDLE) }.is_ok() {
        let mut out = std::io::stdout().lock();
        let _ = writeln!(out, "{text}");
        let _ = out.flush();
        return;
    }
    if unsafe { AttachConsole(ATTACH_PARENT_PROCESS) }.is_err() {
        return;
    }
    let Ok(console) = OpenOptions::new().write(true).open("CONOUT$") else { return };
    let wide: Vec<u16> = format!("{text}\r\n").encode_utf16().collect();
    let _ = unsafe { WriteConsoleW(HANDLE(console.as_raw_handle()), &wide, None, None) };
}
