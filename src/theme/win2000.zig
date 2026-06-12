//! Windows 2000 theme: the classic "Luna-less" chiseled look — silver 3D-face
//! controls with raised/sunken bevels drawn from four edge colors, a navy
//! selection highlight, and square corners. Light-only (Windows 2000 had no
//! dark mode), so `registry.zig` keeps it on the light palette regardless of the
//! OS appearance.

const std = @import("std");
const theme = @import("theme.zig");
const Color = @import("../render/color.zig").Color;
const geom = @import("../layout/geometry.zig");

const Theme = theme.Theme;
const Typography = theme.Typography;
const Metrics = theme.Metrics;
const Surface = theme.Surface;
const ControlState = theme.ControlState;
const Role = theme.Role;
const Rect = geom.Rect;
const Err = std.mem.Allocator.Error;

/// Tahoma-ish UI scale: small, dense text like the classic Windows shell.
const typography = Typography{
    .large_title = .{ .size = 20, .weight = .bold },
    .title = .{ .size = 17, .weight = .bold },
    .title2 = .{ .size = 15, .weight = .bold },
    .title3 = .{ .size = 13, .weight = .bold },
    .headline = .{ .size = 12, .weight = .bold },
    .body = .{ .size = 12, .weight = .regular },
    .callout = .{ .size = 12, .weight = .regular },
    .subheadline = .{ .size = 11, .weight = .regular },
    .footnote = .{ .size = 11, .weight = .regular },
    .caption = .{ .size = 10, .weight = .regular },
    .caption2 = .{ .size = 10, .weight = .regular },
};

/// Square corners, 1px hairlines, a slightly taller default control.
const metrics = Metrics{
    .corner_radius = 0,
    .control_corner_radius = 0,
    .panel_corner_radius = 0,
    .selection_corner_radius = 0,
    .window_corner_radius = 0,
    .control_height = 23,
    .hairline = 1,
};

// ---------------------------------------------------------------------------
// Bevels — the heart of the chiseled look
// ---------------------------------------------------------------------------

/// Draw one 1px ring: top & left edges in `tl`, bottom & right edges in `br`.
fn ring(s: Surface, r: Rect, tl: Color, br: Color) Err!void {
    try s.fill(.{ .x = r.x, .y = r.y, .width = r.width, .height = 1 }, 0, tl); // top
    try s.fill(.{ .x = r.x, .y = r.y, .width = 1, .height = r.height }, 0, tl); // left
    try s.fill(.{ .x = r.x, .y = r.maxY() - 1, .width = r.width, .height = 1 }, 0, br); // bottom
    try s.fill(.{ .x = r.maxX() - 1, .y = r.y, .width = 1, .height = r.height }, 0, br); // right
}

/// A two-ring 3D bevel. `raised` (a button at rest) lights the top-left and
/// shadows the bottom-right; sunken (a pressed button, or an input well) swaps
/// them so the surface reads as pushed in.
fn bevel(s: Surface, rect: Rect, raised: bool) Err!void {
    const p = s.palette;
    if (raised) {
        try ring(s, rect, p.control_highlight, p.control_dark_shadow);
        try ring(s, rect.insetBy(1, 1), p.control_light, p.control_shadow);
    } else {
        try ring(s, rect, p.control_shadow, p.control_highlight);
        try ring(s, rect.insetBy(1, 1), p.control_dark_shadow, p.control_light);
    }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) Err!Color {
    if (role == .plain) return s.palette.accent;
    var r = rect;
    if (role == .prominent) {
        // The classic default-button treatment: a black ring around the bevel.
        try s.fill(r, 0, Color.black);
        r = r.insetBy(1, 1);
    }
    try s.fill(r, 0, s.palette.control_face);
    try bevel(s, r, !st.pressed);
    return s.palette.on_control;
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) Err!void {
    _ = radius; // always square
    _ = st;
    try s.fill(rect, 0, s.palette.control_background);
    try bevel(s, rect, false); // an input is a sunken well
}

fn segmentedTrack(s: Surface, rect: Rect) Err!void {
    try s.fill(rect, 0, s.palette.control_face);
    try bevel(s, rect, true);
}

fn segmentedSelection(s: Surface, seg: Rect) Err!Color {
    // The selected tab/segment reads as a depressed button.
    try s.fill(seg, 0, s.palette.control_face);
    try bevel(s, seg, false);
    return s.palette.on_control;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) Err!void {
    // Classic Windows has no switches — a boolean control is a *checkbox*: a
    // 13px sunken white well on the trailing edge with a black check when on.
    const box: f32 = 13;
    const b = Rect{ .x = rect.maxX() - box, .y = rect.midY() - box / 2, .width = box, .height = box };
    try s.fill(b, 0, s.palette.control_background);
    try bevel(s, b, false);
    if (on) {
        // The check: a short down-stroke meeting a longer up-stroke.
        const mid = geom.Point{ .x = b.x + 5.5, .y = b.y + 9 };
        try s.lineSeg(.{ .x = b.x + 3, .y = b.y + 6.5 }, mid, 1.8, s.palette.on_control);
        try s.lineSeg(mid, .{ .x = b.x + 10, .y = b.y + 3.5 }, 1.8, s.palette.on_control);
    }
}

fn switchKnob(s: Surface, knob: Rect, on: bool) Err!void {
    // The checkbox is drawn entirely by `switchTrack`; there is no thumb.
    _ = s;
    _ = knob;
    _ = on;
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Err!void {
    _ = st;
    // A sunken groove with a navy fill, and a raised square handle.
    try s.fill(track, 0, s.palette.control_background);
    try bevel(s, track, false);
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, 0, s.palette.accent);
    try s.fill(knob, 0, s.palette.control_face);
    try bevel(s, knob, true);
}

fn stepperBox(s: Surface, rect: Rect, st: ControlState) Err!void {
    _ = st;
    try s.fill(rect, 0, s.palette.control_face);
    try bevel(s, rect, true); // a raised control box
}

fn progress(s: Surface, rect: Rect, frac: f32) Err!void {
    try s.fill(rect, 0, s.palette.control_background);
    try bevel(s, rect, false); // a sunken trough
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, 0, s.palette.accent);
}

fn panel(s: Surface, rect: Rect, radius: f32, kind: theme.PanelKind) Err!void {
    _ = kind; // one panel style fits all in this family
    _ = radius; // always square
    try s.fill(rect, 0, s.palette.control_face);
    try bevel(s, rect, true); // a raised window/panel
}

pub const painter = theme.Painter{
    .button = button,
    .field = field,
    .segmentedTrack = segmentedTrack,
    .segmentedSelection = segmentedSelection,
    .switchTrack = switchTrack,
    .switchKnob = switchKnob,
    .slider = slider,
    .stepperBox = stepperBox,
    .progress = progress,
    .panel = panel,
};

// ---------------------------------------------------------------------------
// Theme (light only)
// ---------------------------------------------------------------------------

pub const light = Theme{
    .name = "Windows 2000",
    .scheme = .light,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(10, 36, 106), // classic navy selection
        .label = Color.black,
        .secondary_label = Color.fromRgb8(64, 64, 64),
        .tertiary_label = Color.fromRgb8(128, 128, 128),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(212, 208, 200), // 3DFACE
        .secondary_background = Color.fromRgb8(212, 208, 200),
        .control_background = Color.white, // edit fields / lists
        .separator = Color.fromRgb8(128, 128, 128),
        .selection = Color.fromRgb8(10, 36, 106),
        .destructive = Color.fromRgb8(170, 0, 0),
        .hover = Color.fromRgb8(10, 36, 106).withAlpha(0.12),
        .control_border = Color.fromRgb8(128, 128, 128),
        .glass = Color.fromRgb8(212, 208, 200).withAlpha(0.95),
        .control_track = Color.fromRgb8(212, 208, 200),
        // Bevel edges (the 3D scheme colors).
        .control_face = Color.fromRgb8(212, 208, 200),
        .control_highlight = Color.white,
        .control_light = Color.fromRgb8(227, 224, 219),
        .control_shadow = Color.fromRgb8(128, 128, 128),
        .control_dark_shadow = Color.fromRgb8(64, 64, 64),
        .on_control = Color.black,
    },
};

// Windows 2000 had no dark mode; the registry maps any scheme to `light`.
pub const dark = light;

const testing = std.testing;

test "win2000: square corners and silver face" {
    try testing.expectEqual(@as(f32, 0), light.metrics.control_corner_radius);
    try testing.expect(light.colors.window_background.approxEql(Color.fromRgb8(212, 208, 200), 0.01));
}

test "win2000: selection is navy" {
    const a = light.colors.accent;
    try testing.expect(a.b > a.r and a.b > a.g and a.isDark());
}
