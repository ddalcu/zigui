//! Windows 10 theme: the flat "Metro/Fluent-lite" look — solid fills, 1px
//! borders, square corners, and a single bright accent. Light & dark follow the
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

/// Segoe UI scale: clean, slightly larger than the Win2000 shell.
const typography = Typography{
    .large_title = .{ .size = 24, .weight = .light },
    .title = .{ .size = 20, .weight = .regular },
    .title2 = .{ .size = 16, .weight = .regular },
    .title3 = .{ .size = 14, .weight = .semibold },
    .headline = .{ .size = 13, .weight = .semibold },
    .body = .{ .size = 13, .weight = .regular },
    .callout = .{ .size = 12, .weight = .regular },
    .subheadline = .{ .size = 12, .weight = .regular },
    .footnote = .{ .size = 11, .weight = .regular },
    .caption = .{ .size = 11, .weight = .regular },
    .caption2 = .{ .size = 10, .weight = .regular },
};

/// Flat and square, with a comfortable control height.
const metrics = Metrics{
    .corner_radius = 0,
    .control_corner_radius = 2,
    .panel_corner_radius = 0,
    .selection_corner_radius = 0,
    .window_corner_radius = 0,
    .control_height = 26,
    .hairline = 1,
};

// ---------------------------------------------------------------------------
// Painter — flat fills + 1px borders
// ---------------------------------------------------------------------------

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) Err!Color {
    const r = s.metrics.control_corner_radius;
    if (role == .plain) return s.palette.accent;
    if (role == .destructive) {
        try s.fill(rect, r, s.palette.destructive);
        return s.palette.on_accent;
    }
    // Default Win10 buttons are a neutral fill with a flat border; the accent is
    // reserved for the hover/focus border.
    try s.fill(rect, r, s.palette.control_track);
    const border = if (st.hovered or st.focused) s.palette.accent else s.palette.control_border;
    try s.stroke(rect, r, 1, border);
    return s.palette.label;
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) Err!void {
    try s.fill(rect, radius, s.palette.control_background);
    const c = if (st.focused) s.palette.accent else s.palette.separator;
    const w: f32 = if (st.focused) 2 else 1;
    try s.stroke(rect, radius, w, c);
}

fn segmentedTrack(s: Surface, rect: Rect) Err!void {
    const r = s.metrics.control_corner_radius;
    try s.fill(rect, r, s.palette.control_track);
    try s.stroke(rect, r, 1, s.palette.control_border);
}

fn segmentedSelection(s: Surface, seg: Rect) Err!Color {
    // The selected segment is a solid accent block with accent-contrast text.
    try s.fill(seg.insetBy(1, 1), s.metrics.control_corner_radius, s.palette.accent);
    return s.palette.on_accent;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) Err!void {
    const r = rect.height / 2;
    if (on) {
        try s.fill(rect, r, s.palette.accent);
    } else {
        try s.fill(rect, r, s.palette.control_track);
        try s.stroke(rect, r, 1, s.palette.label);
    }
}

fn switchKnob(s: Surface, knob: Rect, on: bool) Err!void {
    // A flat circular thumb: bright on the accent track, neutral on the off track.
    const c = if (on) s.palette.on_accent else s.palette.label;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, knob.width / 2, c);
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Err!void {
    _ = st;
    const tr = track.height / 2;
    try s.fill(track, tr, s.palette.control_track);
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, tr, s.palette.accent);
    // A solid accent thumb.
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, knob.width / 2, s.palette.accent);
}

fn stepperBox(s: Surface, rect: Rect, st: ControlState) Err!void {
    _ = st;
    const r = s.metrics.control_corner_radius;
    try s.fill(rect, r, s.palette.control_background);
    try s.stroke(rect, r, 1, s.palette.control_border);
}

fn progress(s: Surface, rect: Rect, frac: f32) Err!void {
    const r = rect.height / 2;
    try s.fill(rect, r, s.palette.control_track);
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, r, s.palette.accent);
}

fn panel(s: Surface, rect: Rect, radius: f32) Err!void {
    _ = radius; // always square
    try s.fill(rect, 0, s.palette.control_background);
    try s.stroke(rect, 0, 1, s.palette.control_border);
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
// Themes
// ---------------------------------------------------------------------------

pub const light = Theme{
    .name = "Windows 10",
    .scheme = .light,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(0, 120, 215), // Windows 10 blue
        .label = Color.fromRgb8(0, 0, 0),
        .secondary_label = Color.fromRgb8(96, 96, 96),
        .tertiary_label = Color.fromRgb8(140, 140, 140),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(240, 240, 240),
        .secondary_background = Color.fromRgb8(230, 230, 230),
        .control_background = Color.white,
        .separator = Color.fromRgb8(204, 204, 204),
        .selection = Color.fromRgb8(0, 120, 215),
        .destructive = Color.fromRgb8(232, 17, 35),
        .hover = Color.fromRgb8(229, 241, 251), // Win10 hover wash
        .control_border = Color.fromRgb8(173, 173, 173),
        .glass = Color.white.withAlpha(0.8),
        .control_track = Color.fromRgb8(225, 225, 225),
    },
};

pub const dark = Theme{
    .name = "Windows 10",
    .scheme = .dark,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(96, 205, 255), // brighter accent on dark
        .label = Color.white,
        .secondary_label = Color.white.withAlpha(0.6),
        .tertiary_label = Color.white.withAlpha(0.4),
        .on_accent = Color.fromRgb8(0, 0, 0),
        .window_background = Color.fromRgb8(32, 32, 32),
        .secondary_background = Color.fromRgb8(43, 43, 43),
        .control_background = Color.fromRgb8(51, 51, 51),
        .separator = Color.fromRgb8(80, 80, 80),
        .selection = Color.fromRgb8(0, 120, 215),
        .destructive = Color.fromRgb8(255, 99, 71),
        .hover = Color.white.withAlpha(0.08),
        .control_border = Color.fromRgb8(96, 96, 96),
        .glass = Color.fromRgb8(43, 43, 43).withAlpha(0.85),
        .control_track = Color.fromRgb8(60, 60, 60),
    },
};

const testing = std.testing;

test "windows10: flat with a bright accent" {
    try testing.expect(light.colors.accent.b > light.colors.accent.r);
    try testing.expectEqual(@as(f32, 2), light.metrics.control_corner_radius);
}

test "windows10: light and dark backgrounds differ" {
    try testing.expect(light.colors.window_background.isDark() != dark.colors.window_background.isDark());
}
