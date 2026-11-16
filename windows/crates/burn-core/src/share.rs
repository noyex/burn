//! The share card: an image of the period's spend, copied to the clipboard as PNG. A port of
//! the Mac app's `ShareCard.swift`, drawn as an SVG string and rasterized with resvg. Always the
//! light side of the active theme: its colors, corner radius, block backgrounds and fonts. The
//! bundled fonts stay the fallback, so the result never depends on what is installed.

use crate::model::{Period, ProviderId, UsageBucket, UsageSummary};
use crate::theme::{BlockBackground, Fade, Paint, Pattern, PatternKind, ResolvedTheme, Rgba, Token};
use anyhow::{Result, anyhow};
use chrono::{DateTime, Datelike};
use resvg::{tiny_skia, usvg};
use std::fmt::Write as _;
use std::path::Path;
use std::sync::{Arc, LazyLock, Mutex};

/// Card size in points; the PNG is this times the render scale.
pub const WIDTH: f32 = 600.0;
pub const HEIGHT: f32 = 340.0;

/// Background pictures larger than this are skipped, like in the panel.
const MAX_IMAGE_BYTES: u64 = 25_000_000;

const FONT_MEDIUM: &[u8] = include_bytes!("../../../../assets/Fonts/BricolageGrotesque12pt-Medium.ttf");
const FONT_BOLD: &[u8] = include_bytes!("../../../../assets/Fonts/BricolageGrotesque12pt-Bold.ttf");
const FONT_DISPLAY: &[u8] = include_bytes!("../../../../assets/Fonts/BricolageGrotesque96pt-ExtraBold.ttf");

const GLYPH_CLAUDE: &str = include_str!("../../burn-taskbar/assets/claude.svg");
const GLYPH_OPENAI: &str = include_str!("../../burn-taskbar/assets/openai.svg");
const GLYPH_CURSOR: &str = include_str!("../../burn-taskbar/assets/cursor.svg");

/// Family names inside the font files (checked by a test).
const TEXT: &str = "Bricolage Grotesque 12pt";
const DISPLAY: &str = "Bricolage Grotesque 96pt";

fn bundled_fonts() -> usvg::fontdb::Database {
    let mut db = usvg::fontdb::Database::new();
    for data in [FONT_MEDIUM, FONT_BOLD, FONT_DISPLAY] {
        db.load_font_data(data.to_vec());
    }
    db
}

/// Only the bundled fonts: all a card needs unless the theme names a font.
static FONTS: LazyLock<Arc<usvg::fontdb::Database>> = LazyLock::new(|| Arc::new(bundled_fonts()));

/// The bundled fonts plus everything installed, for a theme that names a font. Built from the
/// scan `theme.rs` keeps, and again only when that scan was redone.
fn fonts_with_system() -> Arc<usvg::fontdb::Database> {
    type Built = (Arc<usvg::fontdb::Database>, Arc<usvg::fontdb::Database>);
    static BUILT: Mutex<Option<Built>> = Mutex::new(None);
    let system = crate::theme::system_fonts();
    let mut built = BUILT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((from, all)) = &*built
        && Arc::ptr_eq(from, &system)
    {
        return all.clone();
    }
    let mut db = (*system).clone();
    for data in [FONT_MEDIUM, FONT_BOLD, FONT_DISPLAY] {
        db.load_font_data(data.to_vec());
    }
    let all = Arc::new(db);
    *built = Some((system, all.clone()));
    all
}

/// What the card is drawn and measured with: the family lists of the two text styles and the font
/// database that holds them.
struct Fonts {
    /// CSS `font-family` values, already escaped for an attribute: the theme's family first, then
    /// the bundled one.
    text: String,
    display: String,
    opts: usvg::Options<'static>,
}

impl Fonts {
    fn new(theme: &ResolvedTheme) -> Fonts {
        let themed = theme.text_font.is_some() || theme.display_font.is_some();
        let db = if themed { fonts_with_system() } else { FONTS.clone() };
        // The font database matches names exactly; the theme may spell one in another case.
        let spelled = |name: &Option<String>| {
            name.as_deref().map(|n| crate::theme::installed_family(n).unwrap_or_else(|| n.to_string()))
        };
        Fonts {
            text: family_list(spelled(&theme.text_font).as_deref(), TEXT),
            display: family_list(spelled(&theme.display_font).as_deref(), DISPLAY),
            opts: usvg::Options { fontdb: db, ..Default::default() },
        }
    }
}

fn family_list(custom: Option<&str>, bundled: &str) -> String {
    let mut list = String::new();
    if let Some(name) = custom.map(|n| n.replace(['\'', '\\'], "")).filter(|n| !n.trim().is_empty()) {
        let _ = write!(list, "'{}', ", escape(&name));
    }
    let _ = write!(list, "'{bundled}'");
    list
}

/// Renders the card at `600x340` points times `scale` and returns PNG bytes. `theme_dir` is the
/// folder the theme's background pictures are read from.
pub fn render_png(
    usage: &UsageSummary,
    theme: &ResolvedTheme,
    theme_dir: Option<&Path>,
    scale: f32,
) -> Result<Vec<u8>> {
    let fonts = Fonts::new(theme);
    let svg = card_svg(usage, theme, theme_dir, &fonts);
    let tree = usvg::Tree::from_str(&svg, &fonts.opts)?;
    let (w, h) = ((WIDTH * scale).round() as u32, (HEIGHT * scale).round() as u32);
    let mut pixmap = tiny_skia::Pixmap::new(w, h).ok_or_else(|| anyhow!("bad card size"))?;
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    Ok(pixmap.encode_png()?)
}

// MARK: formatting

/// "$12.34", or "$1,234" from $100 up, like the Mac app's `Format.money`.
pub fn money(v: f64) -> String {
    let digits = if v >= 100.0 { 0 } else { 2 };
    let s = format!("{:.*}", digits, v.abs());
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i.to_string(), format!(".{f}")),
        None => (s.clone(), String::new()),
    };
    let mut grouped = String::new();
    for (i, c) in int.chars().enumerate() {
        if i > 0 && (int.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(c);
    }
    format!("{}${grouped}{frac}", if v < 0.0 && s.chars().any(|c| c.is_ascii_digit() && c != '0') { "-" } else { "" })
}

/// "1.3B", "245M", "12K", "999".
pub fn tokens(v: i64) -> String {
    let d = v as f64;
    // Thresholds after rounding, so 999,600 reads "1M", not "1000K".
    if d >= 999_950_000.0 {
        format!("{:.1}B", d / 1e9)
    } else if d >= 999_500.0 {
        format!("{:.0}M", d / 1e6)
    } else if d >= 1e3 {
        format!("{:.0}K", d / 1e3)
    } else {
        v.to_string()
    }
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

/// "Today", "Last 7 days", "Last 30 days", "Since November 2026".
pub fn period_phrase(usage: &UsageSummary) -> String {
    match usage.period {
        Period::Today => "Today".into(),
        Period::Week => "Last 7 days".into(),
        Period::Month => "Last 30 days".into(),
        Period::All => {
            let first = usage.buckets.first().and_then(|b| DateTime::from_timestamp_millis(b.start));
            match first {
                Some(d) => {
                    let d = d.with_timezone(&chrono::Local);
                    format!("Since {} {}", MONTHS[d.month0() as usize], d.year())
                }
                None => "All time".into(),
            }
        }
    }
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

// MARK: layout

struct Card {
    /// The theme block the card is filled with, which also picks its background.
    slot: Token,
    fill: Rgba,
    ink: Rgba,
}

/// A provider's card in its brand slot, like `ProviderID.brandColor` on the Mac.
fn card_colors(theme: &ResolvedTheme, p: ProviderId) -> Card {
    let (slot, ink) = match p {
        ProviderId::Claude => (Token::Coral, Token::CoralInk),
        ProviderId::Codex => (Token::Mono, Token::MonoInk),
        ProviderId::Cursor => (Token::Lavender, Token::LavenderInk),
    };
    Card { slot, fill: light(theme, slot), ink: light(theme, ink) }
}

/// The light side of a token. The color a token has no value for stays visible as gray, like the Mac.
fn light(theme: &ResolvedTheme, token: Token) -> Rgba {
    theme.color(token, false).unwrap_or(Rgba::from_hex(0x808080))
}

fn resolve(theme: &ResolvedTheme, paint: &Paint) -> Rgba {
    match paint {
        Paint::Color(c) => *c,
        Paint::Token(t) => light(theme, *t),
    }
}

fn glyph_path(p: ProviderId) -> &'static str {
    let src = match p {
        ProviderId::Claude => GLYPH_CLAUDE,
        ProviderId::Codex => GLYPH_OPENAI,
        ProviderId::Cursor => GLYPH_CURSOR,
    };
    let start = src.find(" d=\"").map(|i| i + 4).unwrap_or(0);
    let end = src[start..].find('"').map(|i| start + i).unwrap_or(start);
    &src[start..end]
}

/// Width of `text` laid out at `size` in the display face, measured by parsing a one-line SVG.
fn text_width(fonts: &Fonts, text: &str, weight: u32, size: f32, spacing: f32) -> f32 {
    let svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="4000" height="400"><text id="t" x="0" y="200" font-family="{}" font-weight="{weight}" font-size="{size}" letter-spacing="{spacing}">{}</text></svg>"#,
        fonts.display,
        escape(text)
    );
    usvg::Tree::from_str(&svg, &fonts.opts).map(|t| t.root().bounding_box().map_or(0.0, |r| r.width())).unwrap_or(0.0)
}

/// Font size that keeps `text` within `avail`, down to `min_factor` of `size` (SwiftUI's
/// `minimumScaleFactor`). Kerning scales with the size.
fn fit(fonts: &Fonts, text: &str, size: f32, spacing: f32, avail: f32, min_factor: f32) -> (f32, f32) {
    let w = text_width(fonts, text, 800, size, spacing);
    if w <= avail || w == 0.0 {
        return (size, spacing);
    }
    let f = (avail / w).max(min_factor);
    (size * f, spacing * f)
}

/// `#RRGGBB`; the alpha is written separately, as an opacity attribute.
fn rgb(c: Rgba) -> String {
    let byte = |v: f64| (v * 255.0).round() as u8;
    format!("#{:02X}{:02X}{:02X}", byte(c.r), byte(c.g), byte(c.b))
}

/// ` fill-opacity="a"` for a color that is not opaque, nothing otherwise.
fn alpha_attr(attr: &str, c: Rgba) -> String {
    if c.a < 1.0 { format!(r#" {attr}="{}""#, c.a as f32) } else { String::new() }
}

#[allow(clippy::too_many_arguments)]
fn text(
    out: &mut String,
    fonts: &Fonts,
    x: f32,
    y: f32,
    size: f32,
    weight: u32,
    fill: Rgba,
    opacity: f32,
    anchor: &str,
    body: &str,
) {
    let _ = write!(
        out,
        r#"<text x="{x}" y="{y}" font-family="{}" font-weight="{weight}" font-size="{size}" fill="{}" fill-opacity="{}" text-anchor="{anchor}">{}</text>"#,
        fonts.text,
        rgb(fill),
        opacity * fill.a as f32,
        escape(body)
    );
}

#[allow(clippy::too_many_arguments)]
fn display(out: &mut String, fonts: &Fonts, x: f32, y: f32, size: f32, spacing: f32, fill: Rgba, body: &str) {
    let _ = write!(
        out,
        r#"<text x="{x}" y="{y}" font-family="{}" font-weight="800" font-size="{size}" letter-spacing="{spacing}" fill="{}"{}>{}</text>"#,
        fonts.display,
        rgb(fill),
        alpha_attr("fill-opacity", fill),
        escape(body)
    );
}

fn glyph(out: &mut String, p: ProviderId, x: f32, y: f32, size: f32, ink: Rgba) {
    let k = size / 24.0;
    let _ = write!(
        out,
        r#"<path transform="translate({x} {y}) scale({k})" fill="{}"{} d="{}"/>"#,
        rgb(ink),
        alpha_attr("fill-opacity", ink),
        glyph_path(p)
    );
}

fn flame(out: &mut String, x: f32, y: f32, size: f32, fill: Rgba) {
    // SF Symbols' flame.fill is not available, so a simple flame silhouette on a 24 grid.
    let k = size / 24.0;
    let _ = write!(
        out,
        r#"<path transform="translate({x} {y}) scale({k})" fill="{}"{} d="M12.6 1.2c.4 3.3-1.3 5.2-3 7.2C7.9 10.4 6 12.4 6 15.6 6 19.4 8.7 22.5 12 22.5s6-3.1 6-6.9c0-2.5-1-4.4-2.2-5.9-.3 1.3-1 2.2-1.9 2.7.5-3.9-.4-8.5-1.3-11.2z"/>"#,
        rgb(fill),
        alpha_attr("fill-opacity", fill)
    );
}

fn bars(out: &mut String, usage: &UsageSummary, x: f32, y: f32, w: f32, h: f32, ink: Rgba) {
    const SHADES: [(ProviderId, f32); 3] =
        [(ProviderId::Claude, 1.0), (ProviderId::Codex, 0.45), (ProviderId::Cursor, 0.25)];
    let buckets: &[UsageBucket] = &usage.buckets;
    if buckets.is_empty() {
        return;
    }
    let peak = buckets.iter().map(UsageBucket::total).fold(0.0_f64, f64::max).max(f64::MIN_POSITIVE);
    let n = buckets.len() as f32;
    let slot = w / n;
    let spacing = if slot > 6.0 {
        2.0
    } else if slot > 3.0 {
        1.0
    } else {
        0.0
    };
    let bw = (w - spacing * (n - 1.0)) / n;
    for (i, b) in buckets.iter().enumerate() {
        let bx = x + i as f32 * (bw + spacing);
        let mut segs: Vec<(f32, f32)> = Vec::new(); // (height, opacity), bottom first
        for (p, shade) in SHADES {
            let c = b.cost.get(&p).copied().unwrap_or(0.0);
            if c > 0.0 {
                segs.push(((((h as f64) * c / peak) as f32).max(1.0), shade));
            }
        }
        if b.total() == 0.0 {
            segs.push((1.0, 0.15));
        }
        let total: f32 = segs.iter().map(|s| s.0).sum::<f32>().min(h);
        let top = y + h - total;
        let id = format!("c{i}");
        let r = 1.5_f32.min(bw / 2.0).min(total);
        let _ = write!(
            out,
            r#"<clipPath id="{id}"><path d="M{bx} {bot}V{t1}Q{bx} {top} {x1} {top}H{x2}Q{xr} {top} {xr} {t1}V{bot}Z"/></clipPath><g clip-path="url(#{id})">"#,
            bot = y + h,
            t1 = top + r,
            x1 = bx + r,
            x2 = bx + bw - r,
            xr = bx + bw,
        );
        let mut bottom = y + h;
        for (sh, op) in segs {
            bottom -= sh;
            let _ = write!(
                out,
                r#"<rect x="{bx}" y="{bottom}" width="{bw}" height="{sh}" fill="{}" fill-opacity="{}"/>"#,
                rgb(ink),
                op * ink.a as f32
            );
        }
        out.push_str("</g>");
    }
}

fn rrect(out: &mut String, x: f32, y: f32, w: f32, h: f32, r: f32, fill: Rgba) {
    let _ = write!(
        out,
        r#"<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{}"{}/>"#,
        rgb(fill),
        alpha_attr("fill-opacity", fill)
    );
}

// MARK: block backgrounds

/// Where a block sits, and the unique ids its clip, gradient and mask take.
struct Rect {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: f32,
}

/// A block filled with its theme color and the background the theme gives it: gradient, then image,
/// then pattern, clipped to the rounded rectangle. Like `themedFill` on the Mac.
fn block(
    card: &mut String,
    ids: &mut u32,
    theme: &ResolvedTheme,
    dir: Option<&Path>,
    slot: Token,
    b: &Rect,
    fill: Rgba,
) {
    rrect(card, b.x, b.y, b.w, b.h, b.r, fill);
    let Some(background) = theme.backgrounds.get(&slot) else { return };
    if *background == BlockBackground::default() {
        return;
    }
    let id = *ids;
    let out = &mut String::new();
    if let Some(gradient) = &background.gradient {
        // Same start and end as `BlockDecoration`, in fractions of the block.
        let radians = gradient.angle.to_radians();
        let (dx, dy) = (radians.sin() / 2.0, -radians.cos() / 2.0);
        let _ = write!(
            out,
            r#"<linearGradient id="g{id}" x1="{}" y1="{}" x2="{}" y2="{}">"#,
            (0.5 - dx) as f32,
            (0.5 - dy) as f32,
            (0.5 + dx) as f32,
            (0.5 + dy) as f32
        );
        let last = (gradient.colors.len().max(2) - 1) as f32;
        for (i, paint) in gradient.colors.iter().enumerate() {
            let c = resolve(theme, paint);
            let _ = write!(
                out,
                r#"<stop offset="{}" stop-color="{}" stop-opacity="{}"/>"#,
                i as f32 / last,
                rgb(c),
                c.a as f32
            );
        }
        let _ = write!(
            out,
            r#"</linearGradient><rect x="{}" y="{}" width="{}" height="{}" fill="url(#g{id})"/>"#,
            b.x, b.y, b.w, b.h
        );
    }
    if let Some(image) = &background.image
        && let Some(uri) = dir.and_then(|d| picture_uri(d, &image.file))
    {
        let _ = write!(
            out,
            r#"<image x="{}" y="{}" width="{}" height="{}" preserveAspectRatio="xMidYMid slice" opacity="{}" href="{uri}"/>"#,
            b.x, b.y, b.w, b.h, image.opacity as f32
        );
    }
    if let Some(pattern) = &background.pattern {
        pattern_svg(out, id, pattern, resolve(theme, &pattern.color), b);
    }
    // A picture that can't be read leaves nothing to draw.
    if out.is_empty() {
        return;
    }
    *ids += 1;
    let _ = write!(
        card,
        r#"<clipPath id="k{id}"><rect x="{}" y="{}" width="{}" height="{}" rx="{}"/></clipPath><g clip-path="url(#k{id})">{out}</g>"#,
        b.x, b.y, b.w, b.h, b.r
    );
}

/// The marks of a pattern in block coordinates, as one path, laid out like `PatternCanvas`: dots and
/// grid lines start half a step in, diagonals start one block height to the left.
fn pattern_path(kind: PatternKind, step: f64, mark: f64, w: f64, h: f64) -> String {
    let marks = |start: f64, limit: f64| {
        (0..).map(move |i| start + f64::from(i) * step).take_while(move |v| *v < limit).map(|v| v as f32)
    };
    let mut d = String::new();
    match kind {
        // The share image is a still: animated kinds show their dot field at rest.
        PatternKind::Dots | PatternKind::Wave | PatternKind::Level | PatternKind::Halftone | PatternKind::Rain => {
            let (r, diameter) = ((mark / 2.0) as f32, mark as f32);
            for x in marks(step / 2.0, w) {
                for y in marks(step / 2.0, h) {
                    let _ = write!(d, "M{} {y}a{r} {r} 0 1 0 {diameter} 0a{r} {r} 0 1 0 -{diameter} 0", x - r);
                }
            }
        }
        PatternKind::Grid => {
            for x in marks(step / 2.0, w) {
                let _ = write!(d, "M{x} 0V{}", h as f32);
            }
            for y in marks(step / 2.0, h) {
                let _ = write!(d, "M0 {y}H{}", w as f32);
            }
        }
        PatternKind::Lines => {
            for x in marks(-h, w) {
                let _ = write!(d, "M{x} {}L{} 0", h as f32, x + h as f32);
            }
        }
    }
    d
}

/// A pattern at its point size (the Mac draws the card at 1x too), faded toward one edge by a mask.
fn pattern_svg(out: &mut String, id: u32, pattern: &Pattern, color: Rgba, b: &Rect) {
    let opacity = (pattern.opacity * color.a) as f32;
    let mask = match pattern.fade {
        None => String::new(),
        Some(fade) => {
            // Fading toward the top means opaque at the bottom, and the other way around.
            let (from, to) = match fade {
                Fade::Top => (0, 1),
                Fade::Bottom => (1, 0),
            };
            let _ = write!(
                out,
                r##"<linearGradient id="f{id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF" stop-opacity="{from}"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="{to}"/></linearGradient><mask id="m{id}" maskUnits="userSpaceOnUse" x="{}" y="{}" width="{}" height="{}"><rect x="{}" y="{}" width="{}" height="{}" fill="url(#f{id})"/></mask>"##,
                b.x, b.y, b.w, b.h, b.x, b.y, b.w, b.h
            );
            format!(r#" mask="url(#m{id})""#)
        }
    };
    let d = pattern_path(pattern.kind, pattern.spacing, pattern.size, f64::from(b.w), f64::from(b.h));
    let paint = match pattern.kind {
        PatternKind::Grid | PatternKind::Lines => {
            format!(r#"fill="none" stroke="{}" stroke-width="{}""#, rgb(color), pattern.size as f32)
        }
        _ => format!(r#"fill="{}""#, rgb(color)),
    };
    let _ = write!(
        out,
        r#"<g opacity="{opacity}"{mask}><path transform="translate({} {})" {paint} d="{d}"/></g>"#,
        b.x, b.y
    );
}

/// The picture as a data URI, when it is a regular PNG or JPEG file of a sensible size. Anything
/// else (missing, a folder, too big, another format, a path out of the folder) is skipped.
fn picture_uri(dir: &Path, file: &str) -> Option<String> {
    if file.is_empty() || file.contains(['/', '\\', ':']) || file.starts_with('.') {
        return None;
    }
    let path = dir.join(file);
    let meta = std::fs::metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_IMAGE_BYTES {
        return None;
    }
    let data = std::fs::read(&path).ok()?;
    let mime = if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if data.starts_with(b"\xFF\xD8\xFF") {
        "image/jpeg"
    } else {
        return None;
    };
    Some(format!("data:{mime};base64,{}", base64(&data)))
}

fn base64(data: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | u32::from(*b) << (16 - 8 * i));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

// MARK: card

fn card_svg(usage: &UsageSummary, theme: &ResolvedTheme, dir: Option<&Path>, fonts: &Fonts) -> String {
    let split: Vec<(ProviderId, f64)> = ProviderId::ALL
        .into_iter()
        .filter_map(|p| usage.by_provider.get(&p).copied().filter(|c| *c > 0.0).map(|c| (p, c)))
        .collect();

    let pad = 14.0;
    let footer_h = 16.0;
    let row_h = HEIGHT - 2.0 * pad - 10.0 - footer_h;
    let side_w = 196.0;
    let total_w = if split.len() > 1 { WIDTH - 2.0 * pad - 8.0 - side_w } else { WIDTH - 2.0 * pad };
    // The card is drawn larger than the panel, so its corners scale with the theme's.
    let radius = (theme.radius * 20.0 / 14.0) as f32;
    let (base, secondary) = (light(theme, Token::Base), light(theme, Token::Secondary));
    let (accent, accent_ink) = (light(theme, Token::Accent), light(theme, Token::AccentInk));
    let mut ids = 0;

    let mut s = String::new();
    let _ = write!(
        s,
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" viewBox="0 0 {WIDTH} {HEIGHT}"><rect width="{WIDTH}" height="{HEIGHT}" fill="{}"{}/>"#,
        rgb(base),
        alpha_attr("fill-opacity", base)
    );

    // Total block.
    let (bx, by) = (pad, pad);
    let total = Rect { x: bx, y: by, w: total_w, h: row_h, r: radius };
    block(&mut s, &mut ids, theme, dir, Token::Accent, &total, accent);
    let (ix, inner_w) = (bx + 18.0, total_w - 36.0);
    text(&mut s, fonts, ix, by + 18.0 + 14.0, 15.0, 700, accent_ink, 1.0, "start", "Burned at API prices");
    let phrase = if split.len() == 1 {
        format!("{} · {}", period_phrase(usage), split[0].0.name())
    } else {
        period_phrase(usage)
    };
    text(&mut s, fonts, ix, by + 18.0 + 18.0 + 12.0, 13.0, 500, accent_ink, 0.65, "start", &phrase);
    let bars_y = by + row_h - 18.0 - 52.0;
    bars(&mut s, usage, ix, bars_y, inner_w, 52.0, accent_ink);
    let tokens_base = bars_y - 14.0 - 4.0;
    text(
        &mut s,
        fonts,
        ix,
        tokens_base,
        13.0,
        500,
        accent_ink,
        0.7,
        "start",
        &format!("{} tokens", tokens(usage.tokens)),
    );
    let m = money(usage.cost);
    let (size, spacing) = fit(fonts, &m, 72.0, -2.2, inner_w, 0.5);
    display(&mut s, fonts, ix, tokens_base - 16.0 - size * 0.2, size, spacing, accent_ink, &m);

    // Provider blocks.
    if split.len() > 1 {
        let n = split.len() as f32;
        let h = (row_h - 8.0 * (n - 1.0)) / n;
        let x = pad + total_w + 8.0;
        for (i, (p, cost)) in split.iter().enumerate() {
            let y = pad + i as f32 * (h + 8.0);
            let c = card_colors(theme, *p);
            block(&mut s, &mut ids, theme, dir, c.slot, &Rect { x, y, w: side_w, h, r: radius }, c.fill);
            let ix = x + 16.0;
            glyph(&mut s, *p, ix, y + 16.0 + 1.0, 14.0, c.ink);
            text(&mut s, fonts, ix + 20.0, y + 16.0 + 12.0, 14.0, 700, c.ink, 1.0, "start", p.name());
            let share = if usage.cost > 0.0 { (cost / usage.cost * 100.0).round() as i64 } else { 0 };
            let bottom = y + h - 16.0;
            text(&mut s, fonts, ix, bottom - 3.0, 12.0, 500, c.ink, 0.75, "start", &format!("{share}% of spend"));
            let m = money(*cost);
            let (size, spacing) = fit(fonts, &m, 32.0, -0.9, side_w - 32.0, 0.6);
            display(&mut s, fonts, ix, bottom - 17.0, size, spacing, c.ink, &m);
        }
    }

    // Footer.
    let fy = pad + row_h + 10.0;
    flame(&mut s, pad + 6.0, fy + 2.0, 11.0, secondary);
    text(&mut s, fonts, pad + 6.0 + 16.0, fy + 12.0, 12.0, 700, secondary, 1.0, "start", "Burn");
    text(&mut s, fonts, WIDTH - pad - 6.0, fy + 12.0, 12.0, 500, secondary, 1.0, "end", "github.com/noyex/burn");

    s.push_str("</svg>");
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::BucketUnit;
    use crate::theme::{Gradient, Image};
    use sha2::{Digest, Sha256};
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    const DAY: i64 = 86_400_000;
    // 2026-11-02 12:00 UTC
    const T0: i64 = 1_793_620_800_000;

    fn summary(period: Period, providers: &[(ProviderId, f64)], days: i64) -> UsageSummary {
        let buckets = (0..days)
            .map(|i| UsageBucket {
                start: T0 + i * DAY,
                cost: providers
                    .iter()
                    .filter(|_| i % 4 != 3)
                    .map(|(p, c)| (*p, c * (1.0 + (i % 5) as f64) / 10.0))
                    .collect(),
            })
            .collect();
        UsageSummary {
            period,
            cost: providers.iter().map(|p| p.1).sum(),
            tokens: 1_300_000_000,
            by_provider: providers.iter().copied().collect::<BTreeMap<_, _>>(),
            buckets,
            unit: BucketUnit::Day,
        }
    }

    fn multi() -> UsageSummary {
        summary(Period::Week, &[(ProviderId::Claude, 612.4), (ProviderId::Codex, 88.15), (ProviderId::Cursor, 12.0)], 7)
    }

    fn single() -> UsageSummary {
        summary(Period::All, &[(ProviderId::Claude, 1234.5)], 40)
    }

    fn decode(png: &[u8]) -> tiny_skia::Pixmap {
        tiny_skia::Pixmap::decode_png(png).unwrap()
    }

    fn standard() -> ResolvedTheme {
        ResolvedTheme::standard()
    }

    fn svg_of(usage: &UsageSummary, theme: &ResolvedTheme, dir: Option<&Path>) -> String {
        card_svg(usage, theme, dir, &Fonts::new(theme))
    }

    fn hash(text: &str) -> String {
        format!("{:x}", Sha256::digest(text.as_bytes()))
    }

    /// A folder in the temp dir that is removed afterwards.
    struct Tmp(PathBuf);

    impl Tmp {
        fn new(name: &str) -> Tmp {
            let dir = std::env::temp_dir().join(format!("burn-share-test-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Tmp(dir)
        }

        /// A solid-color PNG, `w` by `h` pixels.
        fn png(&self, file: &str, w: u32, h: u32, rgba: (u8, u8, u8, u8)) {
            let mut pixmap = tiny_skia::Pixmap::new(w, h).unwrap();
            pixmap.fill(tiny_skia::Color::from_rgba8(rgba.0, rgba.1, rgba.2, rgba.3));
            std::fs::write(self.0.join(file), pixmap.encode_png().unwrap()).unwrap();
        }
    }

    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn hex(v: u32) -> Rgba {
        Rgba::from_hex(v)
    }

    /// Loud on purpose: every color changed, square corners, and every kind of background.
    fn loud_theme() -> ResolvedTheme {
        let mut theme = ResolvedTheme { radius: 0.0, ..standard() };
        for (token, color) in [
            (Token::Base, 0x102030),
            (Token::Secondary, 0xFFAA00),
            (Token::Accent, 0x7C5CFF),
            (Token::AccentInk, 0xFFFFFF),
            (Token::Coral, 0x203040),
            (Token::CoralInk, 0xFFE0B0),
            (Token::Mono, 0x304050),
            (Token::Lavender, 0x405060),
        ] {
            theme.light.insert(token, hex(color));
        }
        theme.backgrounds.insert(
            Token::Accent,
            BlockBackground {
                gradient: Some(Gradient {
                    colors: vec![
                        Paint::Color(hex(0xFF5C8A)),
                        Paint::Token(Token::Accent),
                        Paint::Color(hex(0x000000).with_alpha(0.5)),
                    ],
                    angle: 90.0,
                }),
                image: None,
                pattern: Some(Pattern {
                    fade: Some(Fade::Top),
                    ..Pattern::new(PatternKind::Dots, Paint::Color(hex(0xFFFFFF)))
                }),
            },
        );
        theme.backgrounds.insert(
            Token::Coral,
            BlockBackground {
                gradient: Some(Gradient {
                    colors: vec![Paint::Token(Token::Coral), Paint::Token(Token::Accent)],
                    angle: 0.0,
                }),
                image: None,
                pattern: Some(Pattern {
                    fade: Some(Fade::Bottom),
                    ..Pattern::new(PatternKind::Grid, Paint::Token(Token::CoralInk))
                }),
            },
        );
        theme.backgrounds.insert(
            Token::Mono,
            BlockBackground {
                gradient: None,
                image: None,
                pattern: Some(Pattern::new(PatternKind::Lines, Paint::Token(Token::MonoInk))),
            },
        );
        theme.backgrounds.insert(
            Token::Lavender,
            BlockBackground {
                gradient: None,
                image: Some(Image { file: "bg.png".into(), opacity: 0.5 }),
                pattern: None,
            },
        );
        theme
    }

    /// The theme file `assets/Themes/<name>.json`, read with the fonts of this computer.
    fn built_in(name: &str) -> ResolvedTheme {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../../assets/Themes/{name}.json"));
        ResolvedTheme::parse(&std::fs::read(path).unwrap(), name, &crate::theme::font_installed, &|_| true).0
    }

    #[test]
    fn fonts_resolve_to_bundled_families() {
        let families: Vec<String> = FONTS.faces().flat_map(|f| f.families.iter().map(|(n, _)| n.clone())).collect();
        assert!(families.iter().any(|f| f == TEXT), "{families:?}");
        assert!(families.iter().any(|f| f == DISPLAY), "{families:?}");
    }

    #[test]
    fn renders_multi_provider_week() {
        let img = decode(&render_png(&multi(), &standard(), None, 2.0).unwrap());
        assert_eq!((img.width(), img.height()), (1200, 680));
        let first = img.pixels()[0];
        assert!(img.pixels().iter().any(|p| *p != first), "card is blank");
    }

    #[test]
    fn renders_single_provider_all_time() {
        let img = decode(&render_png(&single(), &standard(), None, 2.0).unwrap());
        assert_eq!((img.width(), img.height()), (1200, 680));
        let first = img.pixels()[0];
        assert!(img.pixels().iter().any(|p| *p != first), "card is blank");
    }

    #[test]
    fn money_formats_like_the_mac_app() {
        assert_eq!(money(0.0), "$0.00");
        assert_eq!(money(12.3), "$12.30");
        assert_eq!(money(99.99), "$99.99");
        assert_eq!(money(100.0), "$100");
        assert_eq!(money(1234.6), "$1,235");
        assert_eq!(money(1_234_567.0), "$1,234,567");
    }

    #[test]
    fn tokens_format_like_the_mac_app() {
        assert_eq!(tokens(999), "999");
        assert_eq!(tokens(12_345), "12K");
        assert_eq!(tokens(245_000_000), "245M");
        assert_eq!(tokens(1_300_000_000), "1.3B");
        assert_eq!(tokens(999_600), "1M");
        assert_eq!(tokens(999_970_000), "1.0B");
    }

    #[test]
    fn period_phrases() {
        assert_eq!(period_phrase(&summary(Period::Today, &[], 1)), "Today");
        assert_eq!(period_phrase(&summary(Period::Week, &[], 7)), "Last 7 days");
        assert_eq!(period_phrase(&summary(Period::Month, &[], 30)), "Last 30 days");
        assert_eq!(period_phrase(&summary(Period::All, &[], 0)), "All time");
        let p = period_phrase(&single());
        assert!(p.starts_with("Since November 2026") || p.starts_with("Since October 2026"), "{p}");
    }

    #[test]
    fn long_money_shrinks_to_fit() {
        let (size, _) = fit(&Fonts::new(&standard()), "$123,456,789", 72.0, -2.2, 100.0, 0.5);
        assert!((36.0..72.0).contains(&size), "{size}");
    }

    /// The SVG of the built-in look, recorded before themes reached the card. If one of these
    /// changes, the standard card changed.
    #[test]
    fn standard_card_is_what_it_was_before_themes() {
        let one = summary(Period::Month, &[(ProviderId::Claude, 1234.5)], 40);
        let two = summary(Period::Today, &[(ProviderId::Codex, 3.2), (ProviderId::Cursor, 1.0)], 1);
        let hashes = [
            (multi(), "befcdd1087b64fd5531dc63ff0f79c6bdb8ce8e931ec4c49b716d02914bad2aa"),
            (one, "8cc1d9a5ce5b09d4ba40c89e059cfccbbe1037cf85ef39091e15cfedde78722d"),
            (two, "419770993be3a52afc1d4230b72c6b2842369375c678c1736c1bb46dfdfe26cf"),
        ];
        for (usage, expected) in hashes {
            assert_eq!(hash(&svg_of(&usage, &standard(), None)), expected);
            // A directory changes nothing when the theme has no picture.
            assert_eq!(svg_of(&usage, &standard(), None), svg_of(&usage, &standard(), Some(Path::new("."))));
        }
    }

    #[test]
    fn colors_radius_and_backgrounds_follow_the_theme() {
        let tmp = Tmp::new("loud");
        tmp.png("bg.png", 8, 4, (255, 0, 0, 255));
        let theme = loud_theme();
        let svg = svg_of(&multi(), &theme, Some(&tmp.0));

        assert!(svg.contains(r##"<rect width="600" height="340" fill="#102030"/>"##));
        // The spend block and the Claude card, square.
        assert!(svg.contains(r##"rx="0" fill="#7C5CFF"/>"##), "{svg}");
        assert!(svg.contains(r##"rx="0" fill="#203040"/>"##));
        assert!(!svg.contains(r#"rx="20""#));
        // Corners scale with the theme the way the Mac card does.
        let round = ResolvedTheme { radius: 7.0, ..standard() };
        assert!(svg_of(&multi(), &round, None).contains(r#"rx="10""#));

        // Gradient: 90 degrees runs left to right, 0 runs bottom to top; the third stop has alpha.
        assert!(svg.contains(r#"<linearGradient id="g0" x1="0" y1="0.5" x2="1" y2="0.5">"#), "{svg}");
        assert!(svg.contains(r##"<stop offset="0.5" stop-color="#7C5CFF" stop-opacity="1"/>"##));
        assert!(svg.contains(r##"<stop offset="1" stop-color="#000000" stop-opacity="0.5"/>"##));
        assert!(svg.contains(r#"<linearGradient id="g1" x1="0.5" y1="1" x2="0.5" y2="0">"#));
        // Everything is clipped to the block, and the faded patterns carry a mask.
        assert!(svg.contains(r#"<clipPath id="k0">"#) && svg.contains(r##"clip-path="url(#k0)""##));
        assert!(svg.contains(r##"mask="url(#m0)""##) && svg.contains(r##"mask="url(#m1)""##));
        assert!(!svg.contains(r##"mask="url(#m2)""##), "lines have no fade");
        // Fading toward the top is transparent at the top; toward the bottom, at the bottom.
        assert!(svg.contains(r##"<stop offset="0" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="1"/>"##));
        assert!(svg.contains(r##"<stop offset="0" stop-color="#FFFFFF" stop-opacity="1"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>"##));
        // Dots fill, grid and lines stroke, and the pattern ink defaults to the block's.
        assert!(svg.contains(r##"fill="#FFFFFF" d="M"##));
        assert!(svg.contains(r##"fill="none" stroke="#FFE0B0" stroke-width="1.5""##));
        assert!(svg.contains(r##"fill="none" stroke="#FFFFFF" stroke-width="1.5""##));
        assert!(svg.contains(r#"<g opacity="0.25""#));
        // The picture sits on the lavender card, scaled to fill.
        assert!(svg.contains(r#"preserveAspectRatio="xMidYMid slice" opacity="0.5" href="data:image/png;base64,"#));
        assert_eq!(svg.matches("<image").count(), 1);

        let themed = render_png(&multi(), &theme, Some(&tmp.0), 1.0).unwrap();
        let plain = render_png(&multi(), &standard(), None, 1.0).unwrap();
        let (themed, plain) = (decode(&themed), decode(&plain));
        assert_eq!((themed.width(), themed.height()), (600, 340));
        assert_ne!(themed.data(), plain.data());
        // The corner of the card is the themed base.
        let at = |img: &tiny_skia::Pixmap, x: u32, y: u32| img.pixel(x, y).map(|p| (p.red(), p.green(), p.blue()));
        assert_eq!(at(&themed, 2, 2), Some((0x10, 0x20, 0x30)));
        assert_eq!(at(&plain, 2, 2), Some((0xF7, 0xF5, 0xF2)));
    }

    #[test]
    fn a_picture_changes_the_block_it_is_on() {
        let tmp = Tmp::new("image");
        tmp.png("bg.png", 8, 4, (255, 0, 0, 255));
        let mut theme = standard();
        theme.backgrounds.insert(
            Token::Accent,
            BlockBackground { image: Some(Image { file: "bg.png".into(), opacity: 1.0 }), ..Default::default() },
        );
        let with = decode(&render_png(&single(), &theme, Some(&tmp.0), 1.0).unwrap());
        let without = decode(&render_png(&single(), &theme, None, 1.0).unwrap());
        // Opaque and scaled to fill: a pixel far from any text is the picture's red.
        let p = with.pixel(300, 40).unwrap();
        assert_eq!((p.red(), p.green(), p.blue()), (255, 0, 0));
        assert_ne!(with.data(), without.data());
    }

    #[test]
    fn unusable_pictures_are_skipped() {
        let tmp = Tmp::new("skip");
        std::fs::create_dir(tmp.0.join("folder.png")).unwrap();
        std::fs::write(tmp.0.join("vector.png"), "<svg xmlns=\"http://www.w3.org/2000/svg\"/>").unwrap();
        std::fs::write(tmp.0.join("empty.png"), "").unwrap();
        tmp.png("fine.png", 2, 2, (0, 0, 255, 255));
        let uri = |f: &str| picture_uri(&tmp.0, f);
        assert!(uri("fine.png").is_some_and(|u| u.starts_with("data:image/png;base64,")));
        for bad in ["missing.png", "folder.png", "vector.png", "empty.png", "../fine.png", "..", "a/b.png", ""] {
            assert_eq!(uri(bad), None, "{bad}");
        }
        // A theme pointing at one of them still renders, as the standard card.
        let mut theme = standard();
        theme.backgrounds.insert(
            Token::Accent,
            BlockBackground { image: Some(Image { file: "vector.png".into(), opacity: 1.0 }), ..Default::default() },
        );
        assert_eq!(svg_of(&multi(), &theme, Some(&tmp.0)), svg_of(&multi(), &standard(), None));
    }

    #[test]
    fn base64_matches_the_standard_alphabet() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foob"), "Zm9vYg==");
        assert_eq!(base64(b"\xFF\xD8\xFF\xE0"), "/9j/4A==");
    }

    #[test]
    fn patterns_start_where_the_mac_starts_them() {
        // 25 x 15 block, marks every 10 points: centers at 5 and 15 across, 5 down.
        let dots = pattern_path(PatternKind::Dots, 10.0, 2.0, 25.0, 15.0);
        assert_eq!(dots.matches('M').count(), 2);
        assert!(dots.starts_with("M4 5a1 1 0 1 0 2 0a1 1 0 1 0 -2 0M14 5"), "{dots}");
        let grid = pattern_path(PatternKind::Grid, 10.0, 1.0, 25.0, 15.0);
        assert_eq!(grid, "M5 0V15M15 0V15M0 5H25");
        // Diagonals start one block height to the left and lean to the right.
        let lines = pattern_path(PatternKind::Lines, 10.0, 1.0, 25.0, 15.0);
        assert_eq!(lines, "M-15 15L0 0M-5 15L10 0M5 15L20 0M15 15L30 0");
    }

    #[test]
    fn theme_fonts_come_first_and_the_bundled_ones_back_them_up() {
        let plain = Fonts::new(&standard());
        assert_eq!(plain.text, "'Bricolage Grotesque 12pt'");
        assert_eq!(plain.display, "'Bricolage Grotesque 96pt'");

        let theme = ResolvedTheme {
            text_font: Some("No Such Family".into()),
            display_font: Some("It's \"Odd\" <Sans>".into()),
            ..standard()
        };
        let fonts = Fonts::new(&theme);
        assert_eq!(fonts.text, "'No Such Family', 'Bricolage Grotesque 12pt'");
        assert_eq!(fonts.display, "'Its &quot;Odd&quot; &lt;Sans&gt;', 'Bricolage Grotesque 96pt'");
        let svg = svg_of(&multi(), &theme, None);
        assert!(svg.contains(r#"font-family="'No Such Family', 'Bricolage Grotesque 12pt'""#));
        // A family that isn't there falls back to the bundled face, so the card looks the same.
        let (a, b) =
            (render_png(&multi(), &theme, None, 1.0).unwrap(), render_png(&multi(), &standard(), None, 1.0).unwrap());
        assert_eq!(decode(&a).data(), decode(&b).data());
    }

    #[test]
    fn built_in_themes_render() {
        for name in ["aurora", "circuit", "ember", "frost", "glow-dots", "obsidian", "prism", "titanium"] {
            let theme = built_in(name);
            let png = render_png(&multi(), &theme, None, 1.0).unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_ne!(
                decode(&png).data(),
                decode(&render_png(&multi(), &standard(), None, 1.0).unwrap()).data(),
                "{name}"
            );
        }
    }

    #[test]
    #[ignore = "writes sample PNGs to the temp dir for inspection"]
    fn write_samples() {
        let tmp = Tmp::new("samples");
        tmp.png("bg.png", 96, 64, (255, 80, 120, 255));
        let mut picture = loud_theme();
        picture.backgrounds.remove(&Token::Accent);
        let samples = [
            ("multi", multi(), standard()),
            ("single", single(), standard()),
            ("glow-dots", multi(), built_in("glow-dots")),
            ("circuit", multi(), built_in("circuit")),
            ("circuit-single", single(), built_in("circuit")),
            ("loud", multi(), loud_theme()),
        ];
        for (name, u, theme) in samples {
            let path = std::env::temp_dir().join(format!("burn-share-{name}.png"));
            let t = std::time::Instant::now();
            let png = render_png(&u, &theme, Some(&tmp.0), 2.0).unwrap();
            println!("{} ({} bytes, {:?})", path.display(), png.len(), t.elapsed());
            std::fs::write(&path, png).unwrap();
        }
    }
}
