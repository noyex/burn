//! Placement maths for the taskbar widget and its panel, in screen pixels. Kept free of
//! Win32 types so it is unit-tested on any platform.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rect {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

impl Rect {
    pub const fn new(left: i32, top: i32, right: i32, bottom: i32) -> Rect {
        Rect { left, top, right, bottom }
    }
    pub fn xywh(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect::new(x, y, x + w, y + h)
    }
    pub fn width(&self) -> i32 {
        self.right - self.left
    }
    pub fn height(&self) -> i32 {
        self.bottom - self.top
    }
    pub fn is_empty(&self) -> bool {
        self.width() <= 0 || self.height() <= 0
    }
    fn center_x(&self) -> i32 {
        self.left + self.width() / 2
    }
    fn center_y(&self) -> i32 {
        self.top + self.height() / 2
    }
}

/// The screen edge the taskbar is docked to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Left,
    Top,
    Right,
    Bottom,
}

impl Edge {
    pub fn is_horizontal(self) -> bool {
        matches!(self, Edge::Top | Edge::Bottom)
    }
}

/// Clamps like `i32::clamp`, but prefers `min` when the range is inverted (content larger
/// than the space), so the start of the content stays visible.
fn clamp(v: i32, min: i32, max: i32) -> i32 {
    v.min(max).max(min)
}

/// The widget's rect: right before the notification area, centred across the bar.
/// `size` is (along the bar, across the bar). When the tray can't be found it keeps
/// `fallback_tray` pixels free at the end of the bar.
pub fn widget_rect(
    taskbar: Rect,
    tray: Option<Rect>,
    edge: Edge,
    size: (i32, i32),
    gap: i32,
    fallback_tray: i32,
) -> Rect {
    let (along, across) = size;
    let tray = tray.filter(|t| !t.is_empty() && overlaps(*t, taskbar));
    if edge.is_horizontal() {
        let end = tray.map_or(taskbar.right - fallback_tray, |t| t.left);
        let h = across.min(taskbar.height());
        let x = clamp(end - gap - along, taskbar.left, taskbar.right - along);
        Rect::xywh(x, taskbar.top + (taskbar.height() - h) / 2, along, h)
    } else {
        let end = tray.map_or(taskbar.bottom - fallback_tray, |t| t.top);
        let w = across.min(taskbar.width());
        let y = clamp(end - gap - along, taskbar.top, taskbar.bottom - along);
        Rect::xywh(taskbar.left + (taskbar.width() - w) / 2, y, w, along)
    }
}

fn overlaps(a: Rect, b: Rect) -> bool {
    a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
}

/// The panel's rect: against the taskbar side of the work area (opening away from the bar),
/// centred on `anchor` along it and kept `gap` inside the work area.
pub fn panel_rect(edge: Edge, anchor: Rect, work: Rect, size: (i32, i32), gap: i32) -> Rect {
    let (w, h) = (size.0.min(work.width() - 2 * gap), size.1.min(work.height() - 2 * gap));
    let along_x = clamp(anchor.center_x() - w / 2, work.left + gap, work.right - gap - w);
    let along_y = clamp(anchor.center_y() - h / 2, work.top + gap, work.bottom - gap - h);
    match edge {
        Edge::Bottom => Rect::xywh(along_x, work.bottom - gap - h, w, h),
        Edge::Top => Rect::xywh(along_x, work.top + gap, w, h),
        Edge::Left => Rect::xywh(work.left + gap, along_y, w, h),
        Edge::Right => Rect::xywh(work.right - gap - w, along_y, w, h),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 1920×1080 with a 48 px Windows 11 taskbar at the bottom.
    const BOTTOM_BAR: Rect = Rect::new(0, 1032, 1920, 1080);
    const TRAY: Rect = Rect::new(1700, 1032, 1920, 1080);

    #[test]
    fn widget_sits_left_of_the_tray() {
        let r = widget_rect(BOTTOM_BAR, Some(TRAY), Edge::Bottom, (160, 48), 4, 200);
        assert_eq!(r, Rect::new(1536, 1032, 1696, 1080));
    }

    #[test]
    fn widget_falls_back_without_a_tray() {
        let r = widget_rect(BOTTOM_BAR, None, Edge::Bottom, (160, 40), 4, 200);
        assert_eq!(r, Rect::new(1556, 1036, 1716, 1076));
        // A tray rect outside the bar (stale or on another monitor) is ignored.
        let stale = Rect::new(3600, 1032, 3840, 1080);
        assert_eq!(widget_rect(BOTTOM_BAR, Some(stale), Edge::Bottom, (160, 40), 4, 200), r);
    }

    #[test]
    fn widget_on_a_vertical_bar_sits_above_the_tray() {
        let bar = Rect::new(0, 0, 62, 1080);
        let tray = Rect::new(0, 900, 62, 1080);
        let r = widget_rect(bar, Some(tray), Edge::Left, (60, 62), 4, 200);
        assert_eq!(r, Rect::new(0, 836, 62, 896));
    }

    #[test]
    fn panel_opens_up_from_a_bottom_bar() {
        let work = Rect::new(0, 0, 1920, 1032);
        let anchor = Rect::new(1536, 1032, 1696, 1080);
        let r = panel_rect(Edge::Bottom, anchor, work, (360, 240), 12);
        assert_eq!(r, Rect::new(1436, 780, 1796, 1020));
    }

    #[test]
    fn panel_stays_inside_the_work_area() {
        let work = Rect::new(0, 0, 1920, 1032);
        let anchor = Rect::new(1880, 1032, 1920, 1080);
        assert_eq!(panel_rect(Edge::Bottom, anchor, work, (360, 240), 12).right, 1908);
        let tall = panel_rect(Edge::Bottom, anchor, work, (360, 2000), 12);
        assert_eq!((tall.top, tall.bottom), (12, 1020));
    }

    #[test]
    fn panel_opens_down_and_sideways() {
        let anchor = Rect::new(1536, 0, 1696, 48);
        let work = Rect::new(0, 48, 1920, 1080);
        assert_eq!(panel_rect(Edge::Top, anchor, work, (360, 240), 12).top, 60);
        let side = Rect::new(0, 836, 62, 896);
        let work = Rect::new(62, 0, 1920, 1080);
        assert_eq!(panel_rect(Edge::Left, side, work, (360, 240), 12), Rect::new(74, 746, 434, 986));
    }
}
