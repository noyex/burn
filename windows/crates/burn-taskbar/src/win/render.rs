//! Direct2D/DirectWrite drawing: the taskbar widget into a premultiplied 32-bit DIB (for
//! `UpdateLayeredWindow`), the placeholder panel into any render target.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;
use std::rc::Rc;

use windows::Win32::Foundation::RECT;
use windows::Win32::Graphics::Direct2D::Common::{
    D2D_RECT_F, D2D_SIZE_U, D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT,
};
use windows::Win32::Graphics::Direct2D::{
    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, D2D1_BITMAP_PROPERTIES, D2D1_DRAW_TEXT_OPTIONS_NONE, D2D1_FACTORY_OPTIONS,
    D2D1_FACTORY_TYPE_SINGLE_THREADED, D2D1_FEATURE_LEVEL_DEFAULT, D2D1_RENDER_TARGET_PROPERTIES,
    D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_ROUNDED_RECT,
    D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE, D2D1CreateFactory, ID2D1Factory, ID2D1RenderTarget,
};
use windows::Win32::Graphics::DirectWrite::{
    DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_FEATURE, DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES,
    DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_WEIGHT, DWRITE_FONT_WEIGHT_MEDIUM,
    DWRITE_FONT_WEIGHT_REGULAR, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_TEXT_METRICS, DWRITE_TEXT_RANGE,
    DWriteCreateFactory, IDWriteFactory, IDWriteTextFormat, IDWriteTextLayout,
};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject,
    HBITMAP, HDC, HGDIOBJ, SelectObject,
};
use windows::core::{BOOL, PCWSTR, Result, w};
use windows_numerics::Vector2;

use crate::model::{Entry, Level, Provider, label, remaining, reset};

// ---- Colours ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
pub struct Rgba(pub f32, pub f32, pub f32, pub f32);

impl Rgba {
    const fn hex(v: u32) -> Rgba {
        Rgba(((v >> 16) & 0xff) as f32 / 255.0, ((v >> 8) & 0xff) as f32 / 255.0, (v & 0xff) as f32 / 255.0, 1.0)
    }
    fn alpha(self, a: f32) -> Rgba {
        Rgba(self.0, self.1, self.2, self.3 * a)
    }
    fn d2d(self) -> D2D1_COLOR_F {
        D2D1_COLOR_F { r: self.0, g: self.1, b: self.2, a: self.3 }
    }
    fn svg(self) -> String {
        let c = |v: f32| (v * 255.0).round() as u8;
        format!("#{:02x}{:02x}{:02x}", c(self.0), c(self.1), c(self.2))
    }
}

pub struct Palette {
    pub text: Rgba,
    pub muted: Rgba,
    pub warn: Rgba,
    pub full: Rgba,
    pub hover: Rgba,
    pub track: Rgba,
    pub panel: Rgba,
}

impl Palette {
    pub fn new(light: bool) -> Palette {
        if light {
            Palette {
                text: Rgba::hex(0x1a1a1a),
                muted: Rgba::hex(0x1a1a1a).alpha(0.62),
                warn: Rgba::hex(0xb65400),
                full: Rgba::hex(0xc42b1c),
                hover: Rgba(0.0, 0.0, 0.0, 0.05),
                track: Rgba(0.0, 0.0, 0.0, 0.10),
                panel: Rgba::hex(0xf3f3f3),
            }
        } else {
            Palette {
                text: Rgba::hex(0xffffff),
                muted: Rgba::hex(0xffffff).alpha(0.62),
                warn: Rgba::hex(0xff9f0a),
                full: Rgba::hex(0xff5a4f),
                hover: Rgba(1.0, 1.0, 1.0, 0.07),
                track: Rgba(1.0, 1.0, 1.0, 0.12),
                panel: Rgba::hex(0x202020),
            }
        }
    }

    fn level(&self, level: Level) -> Rgba {
        match level {
            Level::Normal => self.text,
            Level::Warn => self.warn,
            Level::Full => self.full,
        }
    }

    /// Brand tint for bars, as on the Mac.
    fn tint(&self, provider: Provider) -> Rgba {
        match provider {
            Provider::Claude => Rgba::hex(0xd97757),
            Provider::Codex => self.text.alpha(0.8),
            Provider::Cursor => Rgba::hex(0xa5b0ff),
        }
    }
}

// ---- Logos -----------------------------------------------------------------------------

fn logo_svg(provider: Provider) -> &'static str {
    match provider {
        Provider::Claude => include_str!("../../assets/claude.svg"),
        Provider::Codex => include_str!("../../assets/openai.svg"),
        Provider::Cursor => include_str!("../../assets/cursor.svg"),
    }
}

type LogoKey = (Provider, [u8; 4], u32);

thread_local! {
    /// Rasterized logos, so a redraw (every hover change) doesn't re-parse the SVGs.
    static LOGOS: RefCell<HashMap<LogoKey, Option<Rc<Vec<u8>>>>> = RefCell::new(HashMap::new());
}

fn cached_logo(provider: Provider, color: Rgba, px: u32) -> Option<Rc<Vec<u8>>> {
    let c = |v: f32| (v * 255.0).round() as u8;
    let key = (provider, [c(color.0), c(color.1), c(color.2), c(color.3)], px);
    LOGOS.with(|cache| {
        cache.borrow_mut().entry(key).or_insert_with(|| logo_pixels(provider, color, px).map(Rc::new)).clone()
    })
}

/// The logo at `px`×`px`, filled with `color`, as premultiplied BGRA rows.
fn logo_pixels(provider: Provider, color: Rgba, px: u32) -> Option<Vec<u8>> {
    let svg = logo_svg(provider).replacen("<svg ", &format!("<svg fill=\"{}\" ", color.svg()), 1);
    let tree = resvg::usvg::Tree::from_str(&svg, &resvg::usvg::Options::default()).ok()?;
    let mut pixmap = tiny_skia::Pixmap::new(px, px)?;
    let scale = px as f32 / tree.size().width();
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    let mut data = pixmap.take();
    let alpha = color.3;
    for p in data.as_chunks_mut::<4>().0 {
        p.swap(0, 2);
        if alpha < 1.0 {
            p.iter_mut().for_each(|v| *v = (*v as f32 * alpha).round() as u8);
        }
    }
    Some(data)
}

/// Draws a logo with its top-left corner at (`x`, `y`) DIPs, snapped to device pixels.
fn draw_logo(rt: &ID2D1RenderTarget, provider: Provider, color: Rgba, x: f32, y: f32, size: f32, scale: f32) {
    let px = (size * scale).round().max(1.0) as u32;
    let Some(pixels) = cached_logo(provider, color, px) else { return };
    let dpi = 96.0 * scale;
    let props = D2D1_BITMAP_PROPERTIES {
        pixelFormat: D2D1_PIXEL_FORMAT { format: DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED },
        dpiX: dpi,
        dpiY: dpi,
    };
    let snap = |v: f32| (v * scale).round() / scale;
    unsafe {
        let Ok(bitmap) = rt.CreateBitmap(
            D2D_SIZE_U { width: px, height: px },
            Some(pixels.as_ptr() as *const c_void),
            px * 4,
            &props,
        ) else {
            return;
        };
        let (x, y) = (snap(x), snap(y));
        let side = px as f32 / scale;
        let dest = D2D_RECT_F { left: x, top: y, right: x + side, bottom: y + side };
        rt.DrawBitmap(&bitmap, Some(&dest), 1.0, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, None);
    }
}

// ---- Painter ---------------------------------------------------------------------------

/// A 32-bit premultiplied DIB selected into a memory DC, ready for `UpdateLayeredWindow`.
pub struct Frame {
    pub width: i32,
    pub height: i32,
    pub dc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
}

impl Drop for Frame {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            let _ = DeleteObject(self.bitmap.into());
            let _ = DeleteDC(self.dc);
        }
    }
}

// Widget metrics, in DIPs.
const TEXT_SIZE: f32 = 12.5;
const ICON: f32 = 14.0;
const ICON_GAP: f32 = 5.0;
const ENTRY_GAP: f32 = 12.0;
const PAD_X: f32 = 8.0;
const HOVER_HEIGHT: f32 = 40.0;

pub struct Painter {
    d2d: ID2D1Factory,
    dwrite: IDWriteFactory,
    family: PCWSTR,
    formats: RefCell<HashMap<(u32, i32), IDWriteTextFormat>>,
}

impl Painter {
    pub fn new() -> Result<Painter> {
        let options = D2D1_FACTORY_OPTIONS::default();
        let d2d: ID2D1Factory = unsafe { D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, Some(&options))? };
        let dwrite: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)? };
        let family = if has_family(&dwrite, w!("Segoe UI Variable Text")) {
            w!("Segoe UI Variable Text")
        } else {
            w!("Segoe UI")
        };
        Ok(Painter { d2d, dwrite, family, formats: RefCell::default() })
    }

    fn format(&self, size: f32, weight: DWRITE_FONT_WEIGHT) -> Result<IDWriteTextFormat> {
        let key = (size.to_bits(), weight.0);
        if let Some(format) = self.formats.borrow().get(&key) {
            return Ok(format.clone());
        }
        let format = unsafe {
            self.dwrite.CreateTextFormat(
                self.family,
                None,
                weight,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                size,
                w!("en-us"),
            )?
        };
        self.formats.borrow_mut().insert(key, format.clone());
        Ok(format)
    }

    fn layout(&self, text: &str, size: f32, weight: DWRITE_FONT_WEIGHT, tabular: bool) -> Result<IDWriteTextLayout> {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        unsafe {
            let format = self.format(size, weight)?;
            let layout = self.dwrite.CreateTextLayout(&utf16, &format, 4096.0, 512.0)?;
            if tabular {
                let typography = self.dwrite.CreateTypography()?;
                typography.AddFontFeature(DWRITE_FONT_FEATURE {
                    nameTag: DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES,
                    parameter: 1,
                })?;
                layout
                    .SetTypography(&typography, DWRITE_TEXT_RANGE { startPosition: 0, length: utf16.len() as u32 })?;
            }
            Ok(layout)
        }
    }

    /// Renders the widget. `thickness` is the taskbar's size across the bar in pixels; the
    /// result is that tall and as wide as the content.
    pub fn widget(&self, entries: &[Entry], dpi: u32, thickness: i32, light: bool, hovered: bool) -> Result<Frame> {
        let scale = dpi as f32 / 96.0;
        let palette = Palette::new(light);
        let parts = entries
            .iter()
            .map(|e| {
                let layout = self.layout(&label(e), TEXT_SIZE, DWRITE_FONT_WEIGHT_MEDIUM, true)?;
                let m = metrics(&layout)?;
                Ok((e, layout, m))
            })
            .collect::<Result<Vec<_>>>()?;
        let content: f32 =
            parts.iter().map(|(_, _, m)| ICON + ICON_GAP + m.widthIncludingTrailingWhitespace.ceil()).sum::<f32>()
                + ENTRY_GAP * parts.len().saturating_sub(1) as f32;
        let width = ((content + 2.0 * PAD_X) * scale).ceil() as i32;
        let height = thickness.max(1);
        let height_dip = height as f32 / scale;

        let frame = dib(width, height)?;
        let rt = self.dc_target(&frame, dpi)?;
        let rt: ID2D1RenderTarget = windows::core::Interface::cast(&rt)?;
        unsafe {
            rt.BeginDraw();
            rt.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            // Alpha 0 pixels let clicks through a layered window, so the whole rect gets a
            // barely-there fill to stay one hit target.
            rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 1.0 / 255.0 }));
            if hovered {
                let h = HOVER_HEIGHT.min(height_dip - 4.0);
                let top = (height_dip - h) / 2.0;
                let rect = D2D_RECT_F { left: 2.0, top, right: width as f32 / scale - 2.0, bottom: top + h };
                let brush = rt.CreateSolidColorBrush(&palette.hover.d2d(), None)?;
                rt.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect, radiusX: 4.0, radiusY: 4.0 }, &brush);
            }
            let mut x = PAD_X;
            for (entry, layout, m) in &parts {
                let color = palette.level(Level::from_used(entry.used));
                draw_logo(&rt, entry.provider, color, x, (height_dip - ICON) / 2.0, ICON, scale);
                x += ICON + ICON_GAP;
                let brush = rt.CreateSolidColorBrush(&color.d2d(), None)?;
                let y = ((height_dip - m.height) / 2.0 * scale).round() / scale;
                rt.DrawTextLayout(Vector2 { X: x, Y: y }, layout, &brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
                x += m.widthIncludingTrailingWhitespace.ceil() + ENTRY_GAP;
            }
            rt.EndDraw(None, None)?;
        }
        Ok(frame)
    }

    fn dc_target(&self, frame: &Frame, dpi: u32) -> Result<windows::Win32::Graphics::Direct2D::ID2D1DCRenderTarget> {
        let props = D2D1_RENDER_TARGET_PROPERTIES {
            r#type: D2D1_RENDER_TARGET_TYPE_DEFAULT,
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: dpi as f32,
            dpiY: dpi as f32,
            usage: D2D1_RENDER_TARGET_USAGE_NONE,
            minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
        };
        unsafe {
            let rt = self.d2d.CreateDCRenderTarget(&props)?;
            rt.BindDC(frame.dc, &RECT { left: 0, top: 0, right: frame.width, bottom: frame.height })?;
            Ok(rt)
        }
    }

    pub fn d2d(&self) -> &ID2D1Factory {
        &self.d2d
    }

    /// Placeholder panel content: one row per provider with what's left, a bar and the reset.
    /// Returns nothing; the caller owns BeginDraw/EndDraw.
    pub fn panel(
        &self,
        rt: &ID2D1RenderTarget,
        entries: &[Entry],
        light: bool,
        width: f32,
        scale: f32,
        clear: Option<Rgba>,
    ) -> Result<()> {
        let palette = Palette::new(light);
        unsafe {
            rt.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            rt.Clear(Some(&clear.unwrap_or(Rgba(0.0, 0.0, 0.0, 0.0)).d2d()));
            let mut y = PANEL_PAD;
            for entry in entries {
                let level = Level::from_used(entry.used);
                draw_logo(rt, entry.provider, palette.text, PANEL_PAD, y + 1.0, 16.0, scale);
                let name = self.layout(entry.provider.name(), 13.0, DWRITE_FONT_WEIGHT_SEMI_BOLD, false)?;
                let text = rt.CreateSolidColorBrush(&palette.text.d2d(), None)?;
                rt.DrawTextLayout(Vector2 { X: PANEL_PAD + 24.0, Y: y }, &name, &text, D2D1_DRAW_TEXT_OPTIONS_NONE);

                let value =
                    self.layout(&format!("{} left", remaining(entry.used)), 13.0, DWRITE_FONT_WEIGHT_REGULAR, true)?;
                let vm = metrics(&value)?;
                let value_brush = rt.CreateSolidColorBrush(&palette.level(level).d2d(), None)?;
                rt.DrawTextLayout(
                    Vector2 { X: width - PANEL_PAD - vm.widthIncludingTrailingWhitespace, Y: y },
                    &value,
                    &value_brush,
                    D2D1_DRAW_TEXT_OPTIONS_NONE,
                );

                let bar_top = y + 26.0;
                let track =
                    D2D_RECT_F { left: PANEL_PAD, top: bar_top, right: width - PANEL_PAD, bottom: bar_top + 4.0 };
                let track_brush = rt.CreateSolidColorBrush(&palette.track.d2d(), None)?;
                rt.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: track, radiusX: 2.0, radiusY: 2.0 }, &track_brush);
                let left = ((100.0 - entry.used) / 100.0).clamp(0.0, 1.0) as f32;
                if left > 0.0 {
                    let fill = D2D_RECT_F { right: track.left + (track.right - track.left) * left, ..track };
                    let color =
                        if level == Level::Normal { palette.tint(entry.provider) } else { palette.level(level) };
                    let fill_brush = rt.CreateSolidColorBrush(&color.d2d(), None)?;
                    rt.FillRoundedRectangle(&D2D1_ROUNDED_RECT { rect: fill, radiusX: 2.0, radiusY: 2.0 }, &fill_brush);
                }

                if let Some(secs) = entry.resets_in {
                    let note =
                        self.layout(&format!("Resets in {}", reset(secs)), 11.5, DWRITE_FONT_WEIGHT_REGULAR, true)?;
                    let muted = rt.CreateSolidColorBrush(&palette.muted.d2d(), None)?;
                    rt.DrawTextLayout(
                        Vector2 { X: PANEL_PAD, Y: bar_top + 10.0 },
                        &note,
                        &muted,
                        D2D1_DRAW_TEXT_OPTIONS_NONE,
                    );
                }
                y += PANEL_ROW + PANEL_ROW_GAP;
            }
        }
        Ok(())
    }
}

pub const PANEL_WIDTH: f32 = 320.0;
const PANEL_PAD: f32 = 16.0;
const PANEL_ROW: f32 = 54.0;
const PANEL_ROW_GAP: f32 = 14.0;

pub fn panel_height(rows: usize) -> f32 {
    2.0 * PANEL_PAD + rows as f32 * PANEL_ROW + rows.saturating_sub(1) as f32 * PANEL_ROW_GAP
}

fn metrics(layout: &IDWriteTextLayout) -> Result<DWRITE_TEXT_METRICS> {
    let mut m = DWRITE_TEXT_METRICS::default();
    unsafe { layout.GetMetrics(&mut m)? };
    Ok(m)
}

fn has_family(dwrite: &IDWriteFactory, name: PCWSTR) -> bool {
    unsafe {
        let mut collection = None;
        if dwrite.GetSystemFontCollection(&mut collection, false).is_err() {
            return false;
        }
        let Some(collection) = collection else { return false };
        let mut index = 0u32;
        let mut exists = BOOL(0);
        collection.FindFamilyName(name, &mut index, &mut exists).is_ok() && exists.as_bool()
    }
}

fn dib(width: i32, height: i32) -> Result<Frame> {
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    unsafe {
        let dc = CreateCompatibleDC(None);
        let mut bits: *mut c_void = std::ptr::null_mut();
        let bitmap = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(b) => b,
            Err(e) => {
                let _ = DeleteDC(dc);
                return Err(e);
            }
        };
        let old = SelectObject(dc, bitmap.into());
        Ok(Frame { width, height, dc, bitmap, old })
    }
}
