//! Themes: a port of `ThemeSpec.swift` and the file handling of `ThemeStore.swift`.
//!
//! A theme file is laid over the built-in look. Whatever it leaves out keeps its built-in value,
//! so a theme written for an older Burn keeps working when new tokens appear. The token keys are a
//! public contract shared with the Mac app and `docs/themes.md`: never rename or remove one.

use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::UNIX_EPOCH;

/// An sRGB color with alpha, written in themes as `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Rgba {
    pub fn from_hex(hex: u32) -> Rgba {
        let channel = |shift: u32| f64::from((hex >> shift) & 0xFF) / 255.0;
        Rgba { r: channel(16), g: channel(8), b: channel(0), a: 1.0 }
    }

    pub fn with_alpha(self, a: f64) -> Rgba {
        Rgba { a, ..self }
    }

    pub fn parse(text: &str) -> Option<Rgba> {
        let digits = text.trim_matches(|c| c == ' ' || c == '\t').strip_prefix('#')?;
        if !digits.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let expanded: String;
        let digits = if digits.len() == 3 {
            expanded = digits.chars().flat_map(|c| [c, c]).collect();
            expanded.as_str()
        } else {
            digits
        };
        match digits.len() {
            6 => Some(Rgba::from_hex(u32::from_str_radix(digits, 16).ok()?)),
            8 => {
                let value = u64::from_str_radix(digits, 16).ok()?;
                Some(Rgba::from_hex((value >> 8) as u32).with_alpha((value & 0xFF) as f64 / 255.0))
            }
            _ => None,
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque. Uppercase.
    pub fn hex(&self) -> String {
        let byte = |c: f64| format!("{:02X}", (c * 255.0).round() as i64);
        let mut out = format!("#{}{}{}", byte(self.r), byte(self.g), byte(self.b));
        if self.a < 1.0 {
            out.push_str(&byte(self.a));
        }
        out
    }

    /// WCAG relative luminance.
    pub fn luminance(&self) -> f64 {
        let linear = |c: f64| if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) };
        0.2126 * linear(self.r) + 0.7152 * linear(self.g) + 0.0722 * linear(self.b)
    }

    pub fn is_light(&self) -> bool {
        self.luminance() > 0.5
    }

    /// Near-black or white, whichever reads better on this fill.
    pub fn readable_ink(&self) -> Rgba {
        let dark = Rgba::from_hex(0x141414);
        let on_dark = (self.luminance() + 0.05) / (dark.luminance() + 0.05);
        let on_white = 1.05 / (self.luminance() + 0.05);
        if on_dark >= on_white { dark } else { Rgba::from_hex(0xFFFFFF) }
    }
}

/// Every color a theme can set. The key is the name in theme files and the CSS variable in the
/// panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Token {
    Base,
    Neutral,
    NeutralHover,
    Raised,
    Text,
    Secondary,
    Surface,
    Switcher,
    SwitcherInk,
    Hairline,
    Shadow,
    Accent,
    AccentInk,
    Coral,
    CoralInk,
    Mono,
    MonoInk,
    Lavender,
    LavenderInk,
    Sky,
    SkyInk,
    WarnOnLight,
    FullOnLight,
    WarnOnDark,
    FullOnDark,
    Danger,
    MenuBarWarn,
    MenuBarFull,
    Selection,
}

impl Token {
    pub const ALL: [Token; 29] = [
        Token::Base,
        Token::Neutral,
        Token::NeutralHover,
        Token::Raised,
        Token::Text,
        Token::Secondary,
        Token::Surface,
        Token::Switcher,
        Token::SwitcherInk,
        Token::Hairline,
        Token::Shadow,
        Token::Accent,
        Token::AccentInk,
        Token::Coral,
        Token::CoralInk,
        Token::Mono,
        Token::MonoInk,
        Token::Lavender,
        Token::LavenderInk,
        Token::Sky,
        Token::SkyInk,
        Token::WarnOnLight,
        Token::FullOnLight,
        Token::WarnOnDark,
        Token::FullOnDark,
        Token::Danger,
        Token::MenuBarWarn,
        Token::MenuBarFull,
        Token::Selection,
    ];

    /// Fills whose text color is derived when a theme changes the fill but not the ink.
    pub const INK_PAIRS: [(Token, Token); 6] = [
        (Token::Accent, Token::AccentInk),
        (Token::Switcher, Token::SwitcherInk),
        (Token::Coral, Token::CoralInk),
        (Token::Mono, Token::MonoInk),
        (Token::Lavender, Token::LavenderInk),
        (Token::Sky, Token::SkyInk),
    ];

    pub fn key(self) -> &'static str {
        match self {
            Token::Base => "base",
            Token::Neutral => "neutral",
            Token::NeutralHover => "neutral-hover",
            Token::Raised => "raised",
            Token::Text => "text",
            Token::Secondary => "secondary",
            Token::Surface => "surface",
            Token::Switcher => "switcher",
            Token::SwitcherInk => "switcher-ink",
            Token::Hairline => "hairline",
            Token::Shadow => "shadow",
            Token::Accent => "accent",
            Token::AccentInk => "accent-ink",
            Token::Coral => "coral",
            Token::CoralInk => "coral-ink",
            Token::Mono => "mono",
            Token::MonoInk => "mono-ink",
            Token::Lavender => "lavender",
            Token::LavenderInk => "lavender-ink",
            Token::Sky => "sky",
            Token::SkyInk => "sky-ink",
            Token::WarnOnLight => "warn-on-light",
            Token::FullOnLight => "full-on-light",
            Token::WarnOnDark => "warn-on-dark",
            Token::FullOnDark => "full-on-dark",
            Token::Danger => "danger",
            Token::MenuBarWarn => "menubar-warn",
            Token::MenuBarFull => "menubar-full",
            Token::Selection => "selection",
        }
    }

    pub fn from_key(key: &str) -> Option<Token> {
        Token::ALL.into_iter().find(|t| t.key() == key)
    }

    /// Built-in value; `None` means "the system color" (taskbar alerts, the selection ring).
    pub fn standard(self, dark: bool) -> Option<Rgba> {
        let pick = |light: u32, dark_hex: u32| Rgba::from_hex(if dark { dark_hex } else { light });
        let hex = Rgba::from_hex;
        Some(match self {
            Token::Base => pick(0xF7F5F2, 0x161514),
            Token::Neutral => pick(0xECE9E4, 0x252321),
            Token::NeutralHover => pick(0xE3DFD9, 0x302D2B),
            Token::Raised => pick(0xFFFFFF, 0x3D3936),
            Token::Text => pick(0x1C1A17, 0xF2EFEA),
            Token::Secondary => pick(0x7A746C, 0x9C958C),
            Token::Surface => pick(0xFBFAF8, 0x1F1D1B),
            Token::Switcher => pick(0x1C1A17, 0x2E2B28),
            Token::SwitcherInk => hex(0xFFFFFF),
            Token::Hairline => {
                if dark {
                    hex(0xFFFFFF).with_alpha(0.08)
                } else {
                    hex(0x000000).with_alpha(0.04)
                }
            }
            Token::Shadow => hex(0x000000).with_alpha(if dark { 0.4 } else { 0.16 }),
            Token::Accent => hex(0xDFF26B),
            Token::AccentInk => hex(0x1A1D06),
            Token::Coral => hex(0xD97757),
            Token::CoralInk => hex(0xFFFFFF),
            Token::Mono => pick(0x141414, 0xF2F1EE),
            Token::MonoInk => pick(0xFFFFFF, 0x141414),
            Token::Lavender => hex(0xC9C5FF),
            Token::LavenderInk => hex(0x1B1840),
            Token::Sky => hex(0xB4DDF7),
            Token::SkyInk => hex(0x0C2C42),
            Token::WarnOnLight => hex(0xC25E00),
            Token::FullOnLight => hex(0xD92D20),
            Token::WarnOnDark => hex(0xFFB340),
            Token::FullOnDark => hex(0xFF6B5E),
            Token::Danger => pick(0xFF3B30, 0xFF453A),
            Token::MenuBarWarn | Token::MenuBarFull | Token::Selection => return None,
        })
    }
}

/// A color written out, or another token's color so it follows light and dark.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Paint {
    Color(Rgba),
    Token(Token),
}

impl Paint {
    pub fn parse(text: &str) -> Option<Paint> {
        if let Some(color) = Rgba::parse(text) {
            return Some(Paint::Color(color));
        }
        // Tokens that default to a system color have nothing to paint with.
        Token::from_key(text).filter(|t| t.standard(false).is_some()).map(Paint::Token)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Gradient {
    pub colors: Vec<Paint>,
    /// Degrees, as in CSS: 0 runs bottom to top, 90 left to right, 180 top to bottom.
    pub angle: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatternKind {
    Dots,
    Grid,
    Lines,
}

impl PatternKind {
    fn from_key(key: &str) -> Option<PatternKind> {
        match key {
            "dots" => Some(PatternKind::Dots),
            "grid" => Some(PatternKind::Grid),
            "lines" => Some(PatternKind::Lines),
            _ => None,
        }
    }

    fn key(self) -> &'static str {
        match self {
            PatternKind::Dots => "dots",
            PatternKind::Grid => "grid",
            PatternKind::Lines => "lines",
        }
    }
}

/// Edge a pattern fades out toward.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fade {
    Top,
    Bottom,
}

impl Fade {
    fn from_key(key: &str) -> Option<Fade> {
        match key {
            "top" => Some(Fade::Top),
            "bottom" => Some(Fade::Bottom),
            _ => None,
        }
    }

    fn key(self) -> &'static str {
        match self {
            Fade::Top => "top",
            Fade::Bottom => "bottom",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pattern {
    pub kind: PatternKind,
    pub color: Paint,
    pub opacity: f64,
    /// Distance between marks, and how thick each one is, in points.
    pub spacing: f64,
    pub size: f64,
    pub fade: Option<Fade>,
}

impl Pattern {
    pub fn new(kind: PatternKind, color: Paint) -> Pattern {
        Pattern { kind, color, opacity: 0.25, spacing: 8.0, size: 1.5, fade: None }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Image {
    /// A file in the folder of the theme file.
    pub file: String,
    pub opacity: f64,
}

/// What a theme draws on a block on top of its fill color.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BlockBackground {
    pub gradient: Option<Gradient>,
    pub image: Option<Image>,
    pub pattern: Option<Pattern>,
}

impl BlockBackground {
    /// Blocks that can carry a background, with the ink a pattern defaults to. Sorted by key.
    const SLOTS: [(Token, Token); 7] = [
        (Token::Accent, Token::AccentInk),
        (Token::Coral, Token::CoralInk),
        (Token::Lavender, Token::LavenderInk),
        (Token::Mono, Token::MonoInk),
        (Token::Neutral, Token::Text),
        (Token::Sky, Token::SkyInk),
        (Token::Surface, Token::Text),
    ];

    /// The ink a pattern on this block defaults to; `None` when the block can't carry a background.
    pub fn slot_ink(slot: Token) -> Option<Token> {
        Self::SLOTS.iter().find(|(s, _)| *s == slot).map(|(_, ink)| *ink)
    }
}

pub const RADIUS_RANGE: (f64, f64) = (0.0, 24.0);
pub const GAP_RANGE: (f64, f64) = (2.0, 12.0);
pub const PILL_RANGE: (f64, f64) = (0.0, 999.0);

/// A theme file laid over the built-in look.
#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedTheme {
    pub name: String,
    pub light: BTreeMap<Token, Rgba>,
    pub dark: BTreeMap<Token, Rgba>,
    pub radius: f64,
    pub gap: f64,
    /// Corner radius of buttons, pills and the tab switcher; the default is fully round.
    pub pill: f64,
    pub backgrounds: BTreeMap<Token, BlockBackground>,
    /// Font family for text and for the big numbers; `None` keeps the built-in font.
    pub text_font: Option<String>,
    pub display_font: Option<String>,
}

impl Default for ResolvedTheme {
    fn default() -> Self {
        ResolvedTheme {
            name: "Default".into(),
            light: BTreeMap::new(),
            dark: BTreeMap::new(),
            radius: 14.0,
            gap: 6.0,
            pill: 999.0,
            backgrounds: BTreeMap::new(),
            text_font: None,
            display_font: None,
        }
    }
}

impl ResolvedTheme {
    /// The built-in look.
    pub fn standard() -> ResolvedTheme {
        ResolvedTheme::default()
    }

    pub fn color(&self, token: Token, dark: bool) -> Option<Rgba> {
        let set = if dark { &self.dark } else { &self.light };
        set.get(&token).copied().or_else(|| token.standard(dark))
    }

    /// Up to three colors that tell this theme from the others, most important first.
    pub fn swatch(&self, dark: bool) -> Vec<Rgba> {
        let resolve = |paint: &Paint| match paint {
            Paint::Color(c) => Some(*c),
            Paint::Token(t) => self.color(*t, dark),
        };
        let mut candidates = vec![self.color(Token::Coral, dark), self.color(Token::Accent, dark)];
        // A theme whose blocks share one fill is told apart by what it draws on them.
        for slot in [Token::Coral, Token::Accent] {
            if let Some(background) = self.backgrounds.get(&slot) {
                if let Some(pattern) = &background.pattern {
                    candidates.push(resolve(&pattern.color));
                }
                if let Some(gradient) = &background.gradient {
                    candidates.extend(gradient.colors.iter().map(resolve));
                }
            }
        }
        candidates.extend(
            [Token::Lavender, Token::Sky, Token::Mono, Token::Text, Token::Secondary].map(|t| self.color(t, dark)),
        );
        let mut picked: Vec<Rgba> = Vec::new();
        for candidate in candidates.into_iter().flatten() {
            if candidate.a > 0.5 && picked.len() < 3 {
                let distinct = picked.iter().all(|other| {
                    let (dr, dg, db) = (candidate.r - other.r, candidate.g - other.g, candidate.b - other.b);
                    (dr * dr + dg * dg + db * db).sqrt() > 0.12
                });
                if distinct {
                    picked.push(candidate);
                }
            }
        }
        if picked.is_empty() {
            picked.push(Rgba::from_hex(0x808080));
        }
        picked
    }

    /// Reads a theme file. Never fails: anything it can't use is skipped and reported in the
    /// issues, in the same order as the Mac app.
    pub fn parse(
        data: &[u8],
        fallback_name: &str,
        font_exists: &dyn Fn(&str) -> bool,
        image_exists: &dyn Fn(&str) -> bool,
    ) -> (ResolvedTheme, Vec<String>) {
        let mut theme = ResolvedTheme { name: fallback_name.to_string(), ..ResolvedTheme::default() };
        let data = data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(data);
        let root = match serde_json::from_slice::<Value>(data) {
            Ok(Value::Object(object)) => object,
            Ok(Value::Array(_)) => return (theme, vec!["The file must be a JSON object.".into()]),
            Ok(_) => {
                return (theme, vec!["Not valid JSON: the top level must be an object or an array.".into()]);
            }
            Err(error) => return (theme, vec![format!("Not valid JSON: {error}")]),
        };
        let mut p = Parser { issues: Vec::new() };

        const KNOWN: [&str; 7] = ["name", "colors", "light", "dark", "shape", "fonts", "backgrounds"];
        for key in sorted_keys(&root) {
            if !KNOWN.contains(&key) {
                p.issues.push(format!("Unknown key \"{key}\"."));
            }
        }
        if let Some(Value::String(name)) = root.get("name")
            && !name.is_empty()
        {
            theme.name = name.clone();
        }

        let shared = p.colors(&root, "colors");
        theme.light = shared.clone();
        theme.light.extend(p.colors(&root, "light"));
        theme.dark = shared;
        theme.dark.extend(p.colors(&root, "dark"));
        for set in [&mut theme.light, &mut theme.dark] {
            for (fill, ink) in Token::INK_PAIRS {
                if let Some(color) = set.get(&fill).copied()
                    && !set.contains_key(&ink)
                {
                    set.insert(ink, color.readable_ink());
                }
            }
        }

        if let Some(raw) = root.get("shape") {
            if let Value::Object(shape) = raw {
                p.unknown_keys(shape, "shape", &["radius", "gap", "pill"]);
                theme.radius = p.number(shape, "radius", "shape", RADIUS_RANGE).unwrap_or(theme.radius);
                theme.gap = p.number(shape, "gap", "shape", GAP_RANGE).unwrap_or(theme.gap);
                theme.pill = p.number(shape, "pill", "shape", PILL_RANGE).unwrap_or(theme.pill);
            } else {
                p.issues.push("\"shape\" must be an object.".into());
            }
        }

        if let Some(raw) = root.get("fonts") {
            if let Value::Object(fonts) = raw {
                for key in sorted_keys(fonts) {
                    if key != "text" && key != "display" {
                        p.issues.push(format!("fonts.{key}: unknown key."));
                    }
                }
                theme.text_font = p.family(fonts, "text", font_exists);
                theme.display_font = p.family(fonts, "display", font_exists).or_else(|| theme.text_font.clone());
            } else {
                p.issues.push("\"fonts\" must be an object.".into());
            }
        }

        if let Some(raw) = root.get("backgrounds") {
            if let Value::Object(blocks) = raw {
                for key in sorted_keys(blocks) {
                    let path = format!("backgrounds.{key}");
                    let Some((slot, ink)) =
                        Token::from_key(key).and_then(|s| BlockBackground::slot_ink(s).map(|i| (s, i)))
                    else {
                        let names: Vec<&str> = BlockBackground::SLOTS.iter().map(|(s, _)| s.key()).collect();
                        p.issues.push(format!("{path}: not a block. Use one of {}.", names.join(", ")));
                        continue;
                    };
                    let Value::Object(block) = &blocks[key] else {
                        p.issues.push(format!("{path}: must be an object."));
                        continue;
                    };
                    p.unknown_keys(block, &path, &["gradient", "image", "pattern"]);
                    let background = BlockBackground {
                        gradient: p.gradient(block, &path),
                        image: p.image(block, &path, image_exists),
                        pattern: p.pattern(block, &path, ink),
                    };
                    if background != BlockBackground::default() {
                        theme.backgrounds.insert(slot, background);
                    }
                }
            } else {
                p.issues.push("\"backgrounds\" must be an object.".into());
            }
        }
        (theme, p.issues)
    }
}

fn sorted_keys(object: &Map<String, Value>) -> Vec<&str> {
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    keys
}

struct Parser {
    issues: Vec<String>,
}

impl Parser {
    fn colors(&mut self, root: &Map<String, Value>, section: &str) -> BTreeMap<Token, Rgba> {
        let Some(raw) = root.get(section) else { return BTreeMap::new() };
        let Value::Object(entries) = raw else {
            self.issues.push(format!("\"{section}\" must be an object of token: color."));
            return BTreeMap::new();
        };
        let mut result = BTreeMap::new();
        for key in sorted_keys(entries) {
            let Some(token) = Token::from_key(key) else {
                self.issues.push(format!("{section}.{key}: unknown token."));
                continue;
            };
            match entries[key].as_str().and_then(Rgba::parse) {
                Some(color) => {
                    result.insert(token, color);
                }
                None => self.issues.push(format!("{section}.{key}: not a color, use #RRGGBB or #RRGGBBAA.")),
            }
        }
        result
    }

    /// A number from `object`, clamped to `range`; `None` when missing or not a number.
    fn number(&mut self, object: &Map<String, Value>, key: &str, path: &str, range: (f64, f64)) -> Option<f64> {
        let value = object.get(key)?;
        // JSON booleans are not numbers.
        let Some(number) = value.as_f64() else {
            self.issues.push(format!("{path}.{key}: must be a number."));
            return None;
        };
        let (low, high) = range;
        if !(low..=high).contains(&number) {
            self.issues.push(format!(
                "{path}.{key}: {} is outside {}–{}, clamped.",
                short(number),
                short(low),
                short(high)
            ));
        }
        Some(number.clamp(low, high))
    }

    fn unknown_keys(&mut self, object: &Map<String, Value>, path: &str, known: &[&str]) {
        for key in sorted_keys(object) {
            if !known.contains(&key) {
                self.issues.push(format!("{path}.{key}: unknown key."));
            }
        }
    }

    fn paint(&mut self, object: &Map<String, Value>, key: &str, path: &str) -> Option<Paint> {
        let value = object.get(key)?;
        let paint = value.as_str().and_then(Paint::parse);
        if paint.is_none() {
            self.issues.push(format!("{path}.{key}: use #RRGGBB, #RRGGBBAA or a token name."));
        }
        paint
    }

    /// A font family name, or a list of them of which the first installed one is used.
    fn family(&mut self, fonts: &Map<String, Value>, key: &str, font_exists: &dyn Fn(&str) -> bool) -> Option<String> {
        let value = fonts.get(key)?;
        let names: Option<Vec<&str>> = match value {
            Value::String(name) if !name.is_empty() => Some(vec![name.as_str()]),
            Value::Array(list) if !list.is_empty() => {
                list.iter().map(|v| v.as_str().filter(|s| !s.is_empty())).collect()
            }
            _ => None,
        };
        let Some(names) = names else {
            self.issues.push(format!("fonts.{key}: must be a font family name or a list of them."));
            return None;
        };
        if let Some(found) = names.iter().find(|name| font_exists(name)) {
            return Some((*found).to_string());
        }
        if value.is_string() {
            self.issues.push(format!("fonts.{key}: \"{}\" is not installed on this computer.", names[0]));
        } else {
            let quoted: Vec<String> = names.iter().map(|n| format!("\"{n}\"")).collect();
            self.issues.push(format!("fonts.{key}: none of {} is installed on this computer.", quoted.join(", ")));
        }
        None
    }

    fn gradient(&mut self, block: &Map<String, Value>, path: &str) -> Option<Gradient> {
        let raw = block.get("gradient")?;
        let Value::Object(gradient) = raw else {
            self.issues.push(format!("{path}.gradient: must be an object."));
            return None;
        };
        let at = format!("{path}.gradient");
        self.unknown_keys(gradient, &at, &["colors", "angle"]);
        let list: &[Value] = match gradient.get("colors") {
            Some(Value::Array(list)) => list,
            _ => &[],
        };
        let colors: Vec<Paint> = list.iter().filter_map(|v| v.as_str().and_then(Paint::parse)).collect();
        if colors.len() >= 2 && colors.len() == list.len() {
            let angle = self.number(gradient, "angle", &at, (-360.0, 360.0)).unwrap_or(180.0);
            Some(Gradient { colors, angle })
        } else {
            self.issues.push(format!("{path}.gradient.colors: needs two or more colors (#RRGGBB or token names)."));
            None
        }
    }

    fn image(&mut self, block: &Map<String, Value>, path: &str, image_exists: &dyn Fn(&str) -> bool) -> Option<Image> {
        let raw = block.get("image")?;
        let Value::Object(image) = raw else {
            self.issues.push(format!("{path}.image: must be an object."));
            return None;
        };
        let at = format!("{path}.image");
        self.unknown_keys(image, &at, &["file", "opacity"]);
        match image.get("file").and_then(Value::as_str) {
            Some(file) if !file.is_empty() && !file.contains(['/', '\\']) && !file.starts_with('.') => {
                if image_exists(file) {
                    let opacity = self.number(image, "opacity", &at, (0.0, 1.0)).unwrap_or(1.0);
                    Some(Image { file: file.to_string(), opacity })
                } else {
                    self.issues.push(format!("{path}.image.file: \"{file}\" isn't in the themes folder."));
                    None
                }
            }
            _ => {
                self.issues.push(format!("{path}.image.file: must be the name of a file in the themes folder."));
                None
            }
        }
    }

    fn pattern(&mut self, block: &Map<String, Value>, path: &str, ink: Token) -> Option<Pattern> {
        let raw = block.get("pattern")?;
        let Value::Object(pattern) = raw else {
            self.issues.push(format!("{path}.pattern: must be an object."));
            return None;
        };
        let at = format!("{path}.pattern");
        self.unknown_keys(pattern, &at, &["type", "color", "opacity", "spacing", "size", "fade"]);
        let Some(kind) = pattern.get("type").and_then(Value::as_str).and_then(PatternKind::from_key) else {
            self.issues.push(format!("{at}.type: use \"dots\", \"grid\" or \"lines\"."));
            return None;
        };
        let color = self.paint(pattern, "color", &at).unwrap_or(Paint::Token(ink));
        let mut result = Pattern::new(kind, color);
        result.opacity = self.number(pattern, "opacity", &at, (0.0, 1.0)).unwrap_or(result.opacity);
        result.spacing = self.number(pattern, "spacing", &at, (3.0, 64.0)).unwrap_or(result.spacing);
        result.size = self.number(pattern, "size", &at, (0.5, 16.0)).unwrap_or(result.size);
        if let Some(fade) = pattern.get("fade") {
            result.fade = fade.as_str().and_then(Fade::from_key);
            if result.fade.is_none() {
                self.issues.push(format!("{at}.fade: use \"top\" or \"bottom\"."));
            }
        }
        Some(result)
    }
}

/// C's `%g`: six significant digits, trailing zeros dropped, exponent form when very large or small.
fn short(value: f64) -> String {
    if !value.is_finite() {
        return if value.is_nan() {
            "nan".into()
        } else if value < 0.0 {
            "-inf".into()
        } else {
            "inf".into()
        };
    }
    if value == 0.0 {
        return "0".into();
    }
    let scientific = format!("{value:.5e}");
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let trim = |s: &str| {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s.to_string() }
    };
    if !(-4..6).contains(&exponent) {
        format!("{}e{}{:02}", trim(mantissa), if exponent < 0 { '-' } else { '+' }, exponent.abs())
    } else {
        trim(&format!("{:.*}", (5 - exponent) as usize, value))
    }
}

// MARK: fonts

/// Lowercased family names of the fonts installed on this computer, built on first use.
fn installed_families() -> &'static HashSet<String> {
    static FAMILIES: OnceLock<HashSet<String>> = OnceLock::new();
    FAMILIES.get_or_init(|| {
        let mut db = resvg::usvg::fontdb::Database::new();
        db.load_system_fonts();
        db.faces().flat_map(|face| face.families.iter().map(|(name, _)| name.to_lowercase())).collect()
    })
}

/// Whether a font family is installed, ignoring case.
pub fn font_installed(name: &str) -> bool {
    installed_families().contains(&name.to_lowercase())
}

// MARK: folder

const NOTE: &str = "<!-- Burn rewrites this file on every launch. Your themes are the .json files next to it. -->\n\n";
const MAX_IMAGE_BYTES: u64 = 25_000_000;

/// The folder of the themes that ship with the app: `built-in-themes` next to the executable
/// (where the installer puts it), in debug builds also the repo's `assets/Themes`.
pub fn built_in_dir() -> Option<PathBuf> {
    let beside = std::env::current_exe().ok().and_then(|exe| Some(exe.parent()?.join("built-in-themes")));
    if let Some(dir) = beside.filter(|dir| dir.is_dir()) {
        return Some(dir);
    }
    if cfg!(debug_assertions) {
        return Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../assets/Themes").canonicalize().ok();
    }
    None
}

/// The themes folders: the user's own and the one that ships with the app.
#[derive(Clone, Debug)]
pub struct ThemeDirs {
    pub user: PathBuf,
    pub built_in: Option<PathBuf>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    /// File name without `.json`; what `active.txt` holds.
    pub id: String,
    /// The theme's own `name`, or the file name.
    pub title: String,
    pub built_in: bool,
    pub look: ResolvedTheme,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Loaded {
    pub theme: ResolvedTheme,
    pub available: Vec<Entry>,
    /// Name in `active.txt`; `None` is the built-in look.
    pub selected: Option<String>,
    /// What's wrong with the selected theme.
    pub issues: Vec<String>,
    /// The folder of the active theme file, where its pictures live.
    pub theme_dir: Option<PathBuf>,
}

fn read_theme(path: &Path, font_exists: &dyn Fn(&str) -> bool) -> Option<(ResolvedTheme, Vec<String>)> {
    let data = fs::read(path).ok()?;
    let name = path.file_stem()?.to_string_lossy();
    let folder = path.parent().map(Path::to_path_buf).unwrap_or_default();
    Some(ResolvedTheme::parse(&data, &name, font_exists, &|file| folder.join(file).is_file()))
}

fn list(dir: &Path, built_in: bool, font_exists: &dyn Fn(&str) -> bool) -> Vec<Entry> {
    let Ok(read) = fs::read_dir(dir) else { return Vec::new() };
    let mut entries: Vec<Entry> = read
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "json"))
        .filter_map(|path| {
            let id = path.file_stem()?.to_string_lossy().into_owned();
            let look = read_theme(&path, font_exists).map(|(theme, _)| theme);
            Some(Entry {
                title: look.as_ref().map_or_else(|| id.clone(), |t| t.name.clone()),
                id,
                built_in,
                look: look.unwrap_or_default(),
            })
        })
        .collect();
    entries.sort_by_cached_key(|e| (e.title.to_lowercase(), e.id.clone()));
    entries
}

impl ThemeDirs {
    /// The file a theme name stands for: the user's own, else the built-in one.
    pub fn file_for(&self, name: &str) -> PathBuf {
        let own = self.user.join(format!("{name}.json"));
        if !own.exists()
            && let Some(built_in) = &self.built_in
        {
            let shipped = built_in.join(format!("{name}.json"));
            if shipped.exists() {
                return shipped;
            }
        }
        own
    }

    fn guide_file(&self) -> PathBuf {
        self.user.join("README.md")
    }

    /// Lists both folders and loads the theme `active.txt` names.
    pub fn load(&self, font_exists: &dyn Fn(&str) -> bool) -> Loaded {
        let own = list(&self.user, false, font_exists);
        let shipped = self.built_in.as_deref().map(|d| list(d, true, font_exists)).unwrap_or_default();
        let mut available: Vec<Entry> =
            shipped.into_iter().filter(|t| !own.iter().any(|o| o.id.to_lowercase() == t.id.to_lowercase())).collect();
        available.extend(own);

        let mut name = fs::read_to_string(self.user.join("active.txt")).ok().map(|s| s.trim().to_string());
        if let Some(n) = &mut name
            && let Some(stem) = n.strip_suffix(".json")
        {
            *n = stem.to_string();
        }
        if name.as_deref() == Some("") {
            name = None;
        }
        // The file system ignores case; show the name the way the file spells it.
        if let Some(n) = &name
            && let Some(found) = available.iter().find(|e| e.id.to_lowercase() == n.to_lowercase())
        {
            name = Some(found.id.clone());
        }

        let mut theme = ResolvedTheme::standard();
        let mut issues = Vec::new();
        let mut theme_dir = None;
        if let Some(n) = &name {
            // A name, never a path out of the themes folder.
            if n.contains(['/', '\\']) || n.starts_with('.') {
                issues.push("active.txt must hold a theme's file name, not a path.".to_string());
            } else {
                let file = self.file_for(n);
                if let Some((loaded, problems)) = read_theme(&file, font_exists) {
                    theme = loaded;
                    issues = problems;
                    theme_dir = file.parent().map(Path::to_path_buf);
                } else {
                    issues.push(format!("Theme \"{n}\" isn't in the themes folder."));
                }
            }
        }
        Loaded { theme, available, selected: name, issues, theme_dir }
    }

    /// Turns a theme on (or the built-in look with `None`) by writing `active.txt` atomically.
    pub fn select(&self, name: Option<&str>) -> io::Result<()> {
        fs::create_dir_all(&self.user)?;
        let tmp = self.user.join("active.txt.tmp");
        fs::write(&tmp, name.unwrap_or(""))?;
        fs::rename(&tmp, self.user.join("active.txt"))
    }

    /// Writes `README.md`, the guide, when it differs from what is there.
    pub fn write_guide(&self, guide: &str) {
        let content = format!("{NOTE}{guide}");
        let file = self.guide_file();
        if fs::read_to_string(&file).is_ok_and(|current| current == content) || fs::create_dir_all(&self.user).is_err()
        {
            return;
        }
        let tmp = self.user.join("README.md.tmp");
        if fs::write(&tmp, &content).is_ok() {
            let _ = fs::rename(&tmp, &file);
        }
    }

    /// What a user pastes to their coding agent to have a theme made.
    pub fn agent_prompt(&self) -> String {
        format!(
            "Make me a theme for Burn, my taskbar app. First read \"{}\": it explains the format, how to turn \
             the theme on and how to check it. What I want: ",
            self.guide_file().display()
        )
    }

    /// For a user with no idea yet: the agent comes up with a few designs to pick from.
    pub fn ideas_prompt(&self) -> String {
        format!(
            "Design 4 themes for Burn, my taskbar app, each in a clearly different style. First read \"{}\": it \
             explains the format and how to check a theme. Write each one as a new file in the themes folder, never \
             over an existing one. Use colors, block backgrounds, shape and fonts, and check every file. Then \
             describe each theme in one line and turn on the one you like best. I'll try the rest in Burn \
             → Settings → Theme.",
            self.guide_file().display()
        )
    }

    /// `burn --check-theme <name or path>`: the exit code and the text to print (no trailing newline).
    pub fn check(&self, argument: Option<&str>, font_exists: &dyn Fn(&str) -> bool) -> (i32, String) {
        let Some(argument) = argument else {
            return (2, "Usage: burn --check-theme <theme name or path to .json>".into());
        };
        let path = if argument.contains(['/', '\\']) || argument.ends_with(".json") {
            PathBuf::from(argument)
        } else {
            self.file_for(argument)
        };
        let Some((theme, issues)) = read_theme(&path, font_exists) else {
            return (2, format!("Can't read {}", path.display()));
        };
        if issues.is_empty() {
            return (0, format!("OK: \"{}\" has no problems.", theme.name));
        }
        let mut out =
            format!("\"{}\" has {} problem{}:", theme.name, issues.len(), if issues.len() == 1 { "" } else { "s" });
        for issue in &issues {
            out.push_str("\n- ");
            out.push_str(issue);
        }
        (1, out)
    }
}

// MARK: panel state

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwatchState {
    pub light: Vec<String>,
    pub dark: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryState {
    pub id: String,
    pub title: String,
    pub built_in: bool,
    pub swatch: SwatchState,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct GradientState {
    pub colors: Vec<String>,
    pub angle: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ImageState {
    pub path: String,
    pub opacity: f64,
    /// Modification time in ms, so a changed picture reloads.
    pub version: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PatternState {
    #[serde(rename = "type")]
    pub kind: String,
    pub color: String,
    pub opacity: f64,
    pub spacing: f64,
    pub size: f64,
    pub fade: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BackgroundState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gradient: Option<GradientState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pattern: Option<PatternState>,
}

/// The active theme as the panel's CSS needs it: only what the theme sets, colors as hex.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LookState {
    pub light: BTreeMap<String, String>,
    pub dark: BTreeMap<String, String>,
    pub radius: f64,
    pub gap: f64,
    pub pill: f64,
    pub text_font: Option<String>,
    pub display_font: Option<String>,
    pub backgrounds: BTreeMap<String, BackgroundState>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThemeState {
    pub selected: Option<String>,
    pub title: String,
    pub available: Vec<EntryState>,
    pub default_swatch: SwatchState,
    pub issues: Vec<String>,
    pub folder: String,
    pub agent_prompt: String,
    pub ideas_prompt: String,
    pub look: LookState,
}

fn swatch_state(theme: &ResolvedTheme) -> SwatchState {
    let hexes = |dark| theme.swatch(dark).iter().map(Rgba::hex).collect();
    SwatchState { light: hexes(false), dark: hexes(true) }
}

fn paint_css(paint: &Paint) -> String {
    match paint {
        Paint::Color(color) => color.hex(),
        Paint::Token(token) => format!("var(--{})", token.key()),
    }
}

/// The picture's path and mtime, when it is a regular file of a sensible size.
fn picture(folder: &Path, file: &str) -> Option<(String, u64)> {
    let path = folder.join(file);
    let meta = fs::metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_IMAGE_BYTES {
        return None;
    }
    let version = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?.as_millis() as u64;
    Some((path.to_string_lossy().into_owned(), version))
}

impl Loaded {
    pub fn state(&self, dirs: &ThemeDirs) -> ThemeState {
        let theme = &self.theme;
        let colors = |set: &BTreeMap<Token, Rgba>| set.iter().map(|(t, c)| (t.key().to_string(), c.hex())).collect();
        let backgrounds = theme
            .backgrounds
            .iter()
            .map(|(slot, background)| {
                let image = background.image.as_ref().and_then(|image| {
                    let (path, version) = picture(self.theme_dir.as_deref()?, &image.file)?;
                    Some(ImageState { path, opacity: image.opacity, version })
                });
                let state = BackgroundState {
                    gradient: background
                        .gradient
                        .as_ref()
                        .map(|g| GradientState { colors: g.colors.iter().map(paint_css).collect(), angle: g.angle }),
                    image,
                    pattern: background.pattern.as_ref().map(|p| PatternState {
                        kind: p.kind.key().into(),
                        color: paint_css(&p.color),
                        opacity: p.opacity,
                        spacing: p.spacing,
                        size: p.size,
                        fade: p.fade.map(|f| f.key().into()),
                    }),
                };
                (slot.key().to_string(), state)
            })
            .collect();
        let title = match &self.selected {
            None => "Default".to_string(),
            Some(id) => self.available.iter().find(|e| &e.id == id).map_or_else(|| id.clone(), |e| e.title.clone()),
        };
        ThemeState {
            selected: self.selected.clone(),
            title,
            available: self
                .available
                .iter()
                .map(|e| EntryState {
                    id: e.id.clone(),
                    title: e.title.clone(),
                    built_in: e.built_in,
                    swatch: swatch_state(&e.look),
                })
                .collect(),
            default_swatch: swatch_state(&ResolvedTheme::standard()),
            issues: self.issues.clone(),
            folder: dirs.user.to_string_lossy().into_owned(),
            agent_prompt: dirs.agent_prompt(),
            ideas_prompt: dirs.ideas_prompt(),
            look: LookState {
                light: colors(&theme.light),
                dark: colors(&theme.dark),
                radius: theme.radius,
                gap: theme.gap,
                pill: theme.pill,
                text_font: theme.text_font.clone(),
                display_font: theme.display_font.clone(),
                backgrounds,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn parse_with(
        json: &str,
        font: &dyn Fn(&str) -> bool,
        image: &dyn Fn(&str) -> bool,
    ) -> (ResolvedTheme, Vec<String>) {
        ResolvedTheme::parse(json.as_bytes(), "file", font, image)
    }

    fn parse(json: &str) -> (ResolvedTheme, Vec<String>) {
        parse_with(json, &|_| true, &|_| true)
    }

    fn hex(v: u32) -> Rgba {
        Rgba::from_hex(v)
    }

    #[test]
    fn parses_hex_colors() {
        assert_eq!(Rgba::parse("#fff"), Some(hex(0xFFFFFF)));
        assert_eq!(Rgba::parse(" #D97757 "), Some(hex(0xD97757)));
        assert_eq!(Rgba::parse("#00000080").map(|c| c.a), Some(128.0 / 255.0));
        assert_eq!(Rgba::parse("D97757"), None);
        assert_eq!(Rgba::parse("#GGGGGG"), None);
        assert_eq!(Rgba::parse("#12345"), None);
        assert_eq!(hex(0x000000).with_alpha(0.4).hex(), "#00000066");
        assert_eq!(hex(0xD97757).hex(), "#D97757");
    }

    #[test]
    fn formats_numbers_like_c() {
        assert_eq!(short(99.0), "99");
        assert_eq!(short(0.5), "0.5");
        assert_eq!(short(1e30), "1e+30");
        assert_eq!(short(-1e30), "-1e+30");
        assert_eq!(short(-360.0), "-360");
        assert_eq!(short(999.0), "999");
        assert_eq!(short(0.0), "0");
        assert_eq!(short(1234567.0), "1.23457e+06");
        assert_eq!(short(0.0001), "0.0001");
        assert_eq!(short(0.00001), "1e-05");
    }

    #[test]
    fn empty_theme_is_the_built_in_look() {
        let (theme, issues) = parse("{}");
        assert!(issues.is_empty());
        for token in Token::ALL {
            assert_eq!(theme.color(token, false), token.standard(false));
            assert_eq!(theme.color(token, true), token.standard(true));
        }
        assert_eq!((theme.radius, theme.gap, theme.pill), (14.0, 6.0, 999.0));
        assert_eq!(theme.text_font, None);
    }

    #[test]
    fn token_keys_round_trip() {
        for token in Token::ALL {
            assert_eq!(Token::from_key(token.key()), Some(token));
        }
        assert_eq!(Token::from_key("nope"), None);
    }

    #[test]
    fn appearance_overrides_shared_colors() {
        let (theme, issues) = parse(r##"{"name": "T", "colors": {"base": "#111111"}, "dark": {"base": "#222222"}}"##);
        assert!(issues.is_empty());
        assert_eq!(theme.name, "T");
        assert_eq!(theme.color(Token::Base, false), Some(hex(0x111111)));
        assert_eq!(theme.color(Token::Base, true), Some(hex(0x222222)));
        assert_eq!(theme.color(Token::Text, true), Token::Text.standard(true));
    }

    #[test]
    fn derives_ink_for_a_changed_fill() {
        let (theme, _) =
            parse(r##"{"colors": {"coral": "#101010", "accent": "#F0F0F0", "sky": "#000000", "sky-ink": "#00FF00"}}"##);
        assert_eq!(theme.color(Token::CoralInk, false), Some(hex(0xFFFFFF)));
        assert_eq!(theme.color(Token::AccentInk, true), Some(hex(0x141414)));
        assert_eq!(theme.color(Token::SkyInk, false), Some(hex(0x00FF00)));
        assert_eq!(theme.color(Token::LavenderInk, false), Token::LavenderInk.standard(false));
    }

    #[test]
    fn reports_what_it_skips() {
        let (theme, issues) = parse_with(
            r##"{"extra": 1, "colors": {"nope": "#000000", "base": "red"},
                "shape": {"radius": 99, "gap": "wide", "pill": true},
                "fonts": {"text": "Missing Sans", "display": "Real"}}"##,
            &|f| f == "Real",
            &|_| true,
        );
        assert_eq!(
            issues,
            [
                "Unknown key \"extra\".",
                "colors.base: not a color, use #RRGGBB or #RRGGBBAA.",
                "colors.nope: unknown token.",
                "shape.radius: 99 is outside 0–24, clamped.",
                "shape.gap: must be a number.",
                "shape.pill: must be a number.",
                "fonts.text: \"Missing Sans\" is not installed on this computer.",
            ]
        );
        assert_eq!(theme.color(Token::Base, false), Token::Base.standard(false));
        assert_eq!(theme.radius, 24.0);
        assert_eq!(theme.gap, 6.0);
        assert_eq!(theme.pill, 999.0);
        assert_eq!(theme.text_font, None);
        assert_eq!(theme.display_font.as_deref(), Some("Real"));
    }

    #[test]
    fn parses_block_backgrounds() {
        let (theme, issues) = parse(
            r##"{"shape": {"radius": 0, "pill": 0},
                "backgrounds": {
                  "accent": {"gradient": {"colors": ["#7C5CFF", "coral"], "angle": 135},
                             "pattern": {"type": "dots", "spacing": 4, "fade": "bottom"}},
                  "surface": {"image": {"file": "bg.png", "opacity": 0.5}}}}"##,
        );
        assert!(issues.is_empty(), "{issues:?}");
        assert_eq!(theme.pill, 0.0);
        let accent = &theme.backgrounds[&Token::Accent];
        assert_eq!(
            accent.gradient,
            Some(Gradient { colors: vec![Paint::Color(hex(0x7C5CFF)), Paint::Token(Token::Coral)], angle: 135.0 })
        );
        // A pattern without a color takes the block's ink.
        let mut pattern = Pattern::new(PatternKind::Dots, Paint::Token(Token::AccentInk));
        pattern.spacing = 4.0;
        pattern.fade = Some(Fade::Bottom);
        assert_eq!(accent.pattern, Some(pattern));
        assert_eq!(theme.backgrounds[&Token::Surface].image, Some(Image { file: "bg.png".into(), opacity: 0.5 }));
    }

    #[test]
    fn skips_backgrounds_it_cannot_draw() {
        let (theme, issues) = parse_with(
            r##"{"backgrounds": {
                   "text": {"pattern": {"type": "dots"}},
                   "accent": {"gradient": {"colors": ["#7C5CFF"]}, "pattern": {"type": "zigzag"},
                              "image": {"file": "../secret.png"}},
                   "coral": {"image": {"file": "missing.png"}}}}"##,
            &|_| true,
            &|_| false,
        );
        assert_eq!(
            issues,
            [
                "backgrounds.accent.gradient.colors: needs two or more colors (#RRGGBB or token names).",
                "backgrounds.accent.image.file: must be the name of a file in the themes folder.",
                "backgrounds.accent.pattern.type: use \"dots\", \"grid\" or \"lines\".",
                "backgrounds.coral.image.file: \"missing.png\" isn't in the themes folder.",
                "backgrounds.text: not a block. Use one of accent, coral, lavender, mono, neutral, sky, surface.",
            ]
        );
        assert!(theme.backgrounds.is_empty());
    }

    #[test]
    fn huge_numbers_are_clamped_not_fatal() {
        let (theme, issues) = parse(r##"{"shape": {"radius": 1e30, "gap": -1e30}}"##);
        assert_eq!(
            issues,
            ["shape.radius: 1e+30 is outside 0–24, clamped.", "shape.gap: -1e+30 is outside 2–12, clamped."]
        );
        assert_eq!(theme.radius, 24.0);
        assert_eq!(theme.gap, 2.0);
    }

    #[test]
    fn system_tokens_cannot_paint_a_background() {
        let (theme, issues) =
            parse(r##"{"backgrounds": {"accent": {"gradient": {"colors": ["menubar-warn", "#000000"]}}}}"##);
        assert_eq!(issues.len(), 1);
        assert!(theme.backgrounds.is_empty());
    }

    #[test]
    fn broken_json_falls_back_to_the_built_in_look() {
        let (theme, issues) = parse("{ not json");
        assert_eq!(issues.len(), 1);
        assert!(issues[0].starts_with("Not valid JSON: "));
        assert_eq!(theme.color(Token::Base, false), Token::Base.standard(false));
        assert_eq!(theme.name, "file");
        assert_eq!(parse("[]").1, ["The file must be a JSON object."]);
    }

    #[test]
    fn display_font_follows_text_font() {
        let (theme, _) = parse(r##"{"fonts": {"text": "Avenir Next"}}"##);
        assert_eq!(theme.display_font.as_deref(), Some("Avenir Next"));
    }

    #[test]
    fn font_lists_use_the_first_installed_family() {
        let font = |f: &str| f == "B" || f == "C";
        let (theme, issues) =
            parse_with(r##"{"fonts": {"text": ["A", "B", "C"], "display": ["C", "B"]}}"##, &font, &|_| true);
        assert!(issues.is_empty(), "{issues:?}");
        assert_eq!(theme.text_font.as_deref(), Some("B"));
        assert_eq!(theme.display_font.as_deref(), Some("C"));

        let (theme, issues) = parse_with(r##"{"fonts": {"text": ["B"], "display": ["Z"]}}"##, &font, &|_| true);
        assert_eq!(issues, ["fonts.display: none of \"Z\" is installed on this computer."]);
        assert_eq!(theme.display_font.as_deref(), Some("B"));
    }

    #[test]
    fn font_lists_report_when_none_is_installed() {
        let (theme, issues) = parse_with(r##"{"fonts": {"text": ["A", "B"]}}"##, &|_| false, &|_| true);
        assert_eq!(issues, ["fonts.text: none of \"A\", \"B\" is installed on this computer."]);
        assert_eq!(theme.text_font, None);
        assert_eq!(theme.display_font, None);
    }

    #[test]
    fn font_lists_reject_bad_shapes() {
        for bad in ["5", "\"\"", "[]", "[\"A\", 3]", "[\"A\", \"\"]", "null", "true", "{}"] {
            let (theme, issues) = parse(&format!(r#"{{"fonts": {{"text": {bad}}}}}"#));
            assert_eq!(issues, ["fonts.text: must be a font family name or a list of them."], "{bad}");
            assert_eq!(theme.text_font, None);
        }
    }

    #[test]
    fn swatch_has_up_to_three_distinct_colors() {
        let swatch = ResolvedTheme::standard().swatch(false);
        assert_eq!(swatch.iter().map(Rgba::hex).collect::<Vec<_>>(), ["#D97757", "#DFF26B", "#C9C5FF"]);
        let (theme, _) = parse(
            r##"{"colors": {"coral": "#000000", "accent": "#000000", "lavender": "#000000", "sky": "#000000", "mono": "#000000", "text": "#000000", "secondary": "#000000"}}"##,
        );
        assert_eq!(theme.swatch(true), [hex(0x000000)]);
    }

    fn assets_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap()
    }

    /// The `--name: value;` pairs of the `{ ... }` block that follows the selectors in `path`, in order.
    fn css_block(css: &str, path: &[&str]) -> BTreeMap<String, String> {
        let mut from = 0;
        for selector in path {
            from += css[from..].find(selector).unwrap_or_else(|| panic!("theme.css has no `{selector}`"));
        }
        let open = from + css[from..].find('{').unwrap();
        let close = open + css[open..].find('}').unwrap();
        css[open + 1..close]
            .split(';')
            .filter_map(|decl| {
                let (name, value) = decl.split_once(':')?;
                let name = name.trim().strip_prefix("--")?;
                Some((name.to_string(), value.trim().to_string()))
            })
            .collect()
    }

    /// `#rrggbb` or `rgba(r, g, b, a)` as bytes and alpha.
    fn css_color(value: &str) -> Option<(u8, u8, u8, f64)> {
        if let Some(color) = Rgba::parse(value) {
            let byte = |c: f64| (c * 255.0).round() as u8;
            return Some((byte(color.r), byte(color.g), byte(color.b), color.a));
        }
        let inner = value.strip_prefix("rgba(")?.strip_suffix(')')?;
        let parts: Vec<&str> = inner.split(',').map(str::trim).collect();
        let [r, g, b, a] = parts[..] else { return None };
        Some((r.parse().ok()?, g.parse().ok()?, b.parse().ok()?, a.parse().ok()?))
    }

    /// The panel's CSS repeats the built-in colors; a token changed in Rust but not there would
    /// paint the default look wrong.
    #[test]
    fn panel_css_matches_the_built_in_tokens() {
        let css = fs::read_to_string(assets_dir().join("windows/ui/src/lib/theme.css")).unwrap();
        let mut stripped = String::new();
        let mut rest = css.as_str();
        while let Some(i) = rest.find("/*") {
            stripped.push_str(&rest[..i]);
            rest = rest[i..].split_once("*/").map_or("", |(_, after)| after);
        }
        stripped.push_str(rest);

        let light = css_block(&stripped, &[":root"]);
        let mut dark = light.clone();
        dark.extend(css_block(&stripped, &["@media (prefers-color-scheme: dark)", ":root"]));
        let mut checked = 0;
        for token in Token::ALL {
            for (dark_mode, vars) in [(false, &light), (true, &dark)] {
                let Some(expected) = token.standard(dark_mode) else { continue };
                let appearance = if dark_mode { "dark" } else { "light" };
                let found = vars
                    .get(token.key())
                    .unwrap_or_else(|| panic!("theme.css has no --{} ({appearance})", token.key()));
                let (r, g, b, a) = css_color(found)
                    .unwrap_or_else(|| panic!("theme.css --{} ({appearance}) is not a color: {found}", token.key()));
                let (er, eg, eb, _) = css_color(&expected.hex()[..7]).unwrap();
                assert_eq!((r, g, b), (er, eg, eb), "--{} ({appearance}) is {found}", token.key());
                assert!((a - expected.a).abs() < 0.005, "--{} ({appearance}) alpha is {found}", token.key());
                checked += 1;
            }
        }
        assert!(checked > 40, "only {checked} colors checked");
    }

    #[test]
    fn built_in_themes_have_no_problems() {
        let dir = assets_dir().join("assets/Themes");
        let mut count = 0;
        for file in fs::read_dir(&dir).unwrap().flatten().map(|e| e.path()) {
            if file.extension().is_none_or(|e| e != "json") {
                continue;
            }
            count += 1;
            let (theme, issues) =
                ResolvedTheme::parse(&fs::read(&file).unwrap(), "", &font_installed, &|f| dir.join(f).is_file());
            assert!(issues.is_empty(), "{}: {issues:?}", file.display());
            assert!(!theme.name.is_empty(), "{} needs a name", file.display());
        }
        assert!(count > 0);
    }

    /// The guide is how agents learn the format: a token missing from it can't be themed in practice.
    #[test]
    fn guide_documents_every_token() {
        let guide = fs::read_to_string(assets_dir().join("docs/themes.md")).unwrap();
        for token in Token::ALL {
            let show = |dark| token.standard(dark).map_or_else(|| "system".to_string(), |c| c.hex());
            let row = format!("| `{}` | `{}` | `{}` |", token.key(), show(false), show(true));
            assert!(guide.contains(&row), "docs/themes.md needs the row: {row}");
        }
    }

    #[test]
    fn finds_installed_fonts() {
        if cfg!(target_os = "macos") {
            assert!(font_installed("Menlo"));
            assert!(font_installed("menlo"));
        }
        assert!(!font_installed("Definitely Not A Font 123"));
    }

    struct Tmp(PathBuf);

    impl Tmp {
        fn new() -> Tmp {
            static N: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "burn-theme-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Tmp(dir)
        }

        fn write(&self, rel: &str, text: &str) {
            let path = self.0.join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, text).unwrap();
        }
    }

    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn dirs(tmp: &Tmp) -> ThemeDirs {
        ThemeDirs { user: tmp.0.join("user"), built_in: Some(tmp.0.join("built-in")) }
    }

    fn all_fonts(_: &str) -> bool {
        true
    }

    #[test]
    fn user_file_wins_over_a_built_in_of_the_same_id() {
        let tmp = Tmp::new();
        tmp.write("built-in/paper.json", r#"{"name": "Built-in paper"}"#);
        tmp.write("built-in/zeta.json", r#"{"name": "alpha"}"#);
        tmp.write("user/Paper.json", r#"{"name": "My paper"}"#);
        tmp.write("user/notes.txt", "x");
        tmp.write("user/beta.json", "{}");
        let d = dirs(&tmp);
        let loaded = d.load(&all_fonts);
        let seen: Vec<_> = loaded.available.iter().map(|e| (e.id.as_str(), e.title.as_str(), e.built_in)).collect();
        assert_eq!(seen, [("zeta", "alpha", true), ("beta", "beta", false), ("Paper", "My paper", false)]);
        assert_eq!(d.file_for("nothing"), d.user.join("nothing.json"));
        d.select(Some("zeta")).unwrap();
        assert_eq!(d.file_for("zeta"), d.built_in.clone().unwrap().join("zeta.json"));
    }

    #[test]
    fn selection_round_trip() {
        let tmp = Tmp::new();
        tmp.write("built-in/terminal.json", r##"{"name": "Terminal", "colors": {"accent": "#4DFF88"}}"##);
        let d = dirs(&tmp);
        assert_eq!(d.load(&all_fonts).selected, None);

        d.select(Some("terminal")).unwrap();
        let loaded = d.load(&all_fonts);
        assert_eq!(loaded.selected.as_deref(), Some("terminal"));
        assert_eq!(loaded.theme.name, "Terminal");
        assert_eq!(loaded.theme_dir, d.built_in);
        assert!(!d.user.join("active.txt.tmp").exists());

        // A trailing .json and another case still find the file, spelled the way it is on disk.
        d.select(Some("TerMinal.json\n")).unwrap();
        let loaded = d.load(&all_fonts);
        assert_eq!(loaded.selected.as_deref(), Some("terminal"));
        assert!(loaded.issues.is_empty());

        d.select(None).unwrap();
        assert_eq!(d.load(&all_fonts).selected, None);
    }

    #[test]
    fn path_like_and_missing_names_are_reported() {
        let tmp = Tmp::new();
        let d = dirs(&tmp);
        for name in ["../x", "a/b", "a\\b", ".hidden"] {
            d.select(Some(name)).unwrap();
            let loaded = d.load(&all_fonts);
            assert_eq!(loaded.issues, ["active.txt must hold a theme's file name, not a path."], "{name}");
            assert_eq!(loaded.theme, ResolvedTheme::standard());
        }
        d.select(Some("ghost")).unwrap();
        let loaded = d.load(&all_fonts);
        assert_eq!(loaded.issues, ["Theme \"ghost\" isn't in the themes folder."]);
        assert_eq!(loaded.selected.as_deref(), Some("ghost"));
    }

    #[test]
    fn guide_is_written_once() {
        let tmp = Tmp::new();
        let d = dirs(&tmp);
        d.write_guide("# Guide\n");
        let file = d.user.join("README.md");
        let text = fs::read_to_string(&file).unwrap();
        assert!(text.starts_with("<!-- Burn rewrites this file on every launch."));
        assert!(text.ends_with("\n\n# Guide\n"));
        let first = fs::metadata(&file).unwrap().modified().unwrap();
        d.write_guide("# Guide\n");
        assert_eq!(fs::metadata(&file).unwrap().modified().unwrap(), first);
        d.write_guide("# Guide 2\n");
        assert!(fs::read_to_string(&file).unwrap().ends_with("# Guide 2\n"));
        assert!(!d.user.join("README.md.tmp").exists());
    }

    #[test]
    fn check_reports_like_the_mac_app() {
        let tmp = Tmp::new();
        tmp.write("user/ok.json", r#"{"name": "Fine"}"#);
        tmp.write("user/bad.json", r##"{"name": "Bad", "x": 1, "shape": {"gap": 99}}"##);
        let d = dirs(&tmp);
        assert_eq!(d.check(None, &all_fonts), (2, "Usage: burn --check-theme <theme name or path to .json>".into()));
        assert_eq!(d.check(Some("ok"), &all_fonts), (0, "OK: \"Fine\" has no problems.".into()));
        assert_eq!(
            d.check(Some("bad"), &all_fonts),
            (1, "\"Bad\" has 2 problems:\n- Unknown key \"x\".\n- shape.gap: 99 is outside 2–12, clamped.".into())
        );
        let by_path = tmp.0.join("user/ok.json");
        assert_eq!(d.check(by_path.to_str(), &all_fonts).0, 0);
        let (code, text) = d.check(Some("nope"), &all_fonts);
        assert_eq!(code, 2);
        assert!(text.starts_with("Can't read "));
    }

    #[test]
    fn prompts_name_the_guide() {
        let tmp = Tmp::new();
        let d = dirs(&tmp);
        let guide = d.user.join("README.md").display().to_string();
        assert!(d.agent_prompt().contains(&format!("read \"{guide}\"")));
        assert!(d.agent_prompt().starts_with("Make me a theme for Burn, my taskbar app."));
        assert!(d.ideas_prompt().contains("Burn → Settings → Theme."));
    }

    #[test]
    fn state_has_the_shape_the_panel_reads() {
        let tmp = Tmp::new();
        tmp.write(
            "user/vivid.json",
            r##"{"name": "Vivid", "colors": {"accent": "#7C5CFF"},
                "shape": {"radius": 10},
                "backgrounds": {"accent": {
                  "gradient": {"colors": ["#7C5CFF", "coral"], "angle": 135},
                  "image": {"file": "paper.png", "opacity": 0.4},
                  "pattern": {"type": "dots", "opacity": 0.25, "fade": "top"}}}}"##,
        );
        tmp.write("user/paper.png", "png");
        tmp.write("user/other.json", "{}");
        let d = dirs(&tmp);
        d.select(Some("vivid")).unwrap();
        let loaded = d.load(&all_fonts);
        let state = loaded.state(&d);
        let version = fs::metadata(d.user.join("paper.png")).unwrap().modified().unwrap();
        let version = version.duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;

        let value = serde_json::to_value(&state).unwrap();
        let expected = json!({
            "selected": "vivid",
            "title": "Vivid",
            "available": [
                {"id": "other", "title": "other", "builtIn": false,
                 "swatch": {"light": ["#D97757", "#DFF26B", "#C9C5FF"], "dark": ["#D97757", "#DFF26B", "#C9C5FF"]}},
                {"id": "vivid", "title": "Vivid", "builtIn": false,
                 "swatch": {
                    "light": ["#D97757", "#7C5CFF", "#FFFFFF"],
                    "dark": ["#D97757", "#7C5CFF", "#FFFFFF"]}},
            ],
            "defaultSwatch": {"light": ["#D97757", "#DFF26B", "#C9C5FF"], "dark": ["#D97757", "#DFF26B", "#C9C5FF"]},
            "issues": [],
            "folder": d.user.to_string_lossy(),
            "agentPrompt": d.agent_prompt(),
            "ideasPrompt": d.ideas_prompt(),
            "look": {
                "light": {"accent": "#7C5CFF", "accent-ink": "#FFFFFF"},
                "dark": {"accent": "#7C5CFF", "accent-ink": "#FFFFFF"},
                "radius": 10.0, "gap": 6.0, "pill": 999.0,
                "textFont": null, "displayFont": null,
                "backgrounds": {"accent": {
                    "gradient": {"colors": ["#7C5CFF", "var(--coral)"], "angle": 135.0},
                    "image": {"path": d.user.join("paper.png").to_string_lossy(), "opacity": 0.4, "version": version},
                    "pattern": {"type": "dots", "color": "var(--accent-ink)", "opacity": 0.25,
                                "spacing": 8.0, "size": 1.5, "fade": "top"}
                }}
            }
        });
        assert_eq!(value, expected);

        // No selection: built-in look, nothing set, and a missing picture is left out.
        d.select(None).unwrap();
        let state = d.load(&all_fonts).state(&d);
        assert_eq!(state.title, "Default");
        assert_eq!(state.selected, None);
        assert!(state.look.light.is_empty() && state.look.backgrounds.is_empty());
        fs::remove_file(d.user.join("paper.png")).unwrap();
        d.select(Some("vivid")).unwrap();
        let state = d.load(&|_| true).state(&d);
        assert_eq!(state.issues, ["backgrounds.accent.image.file: \"paper.png\" isn't in the themes folder."]);
    }
}
