//! KDE Plasma theme (Breeze): the Linux desktop look — soft neutral surfaces,
//! a cyan-blue accent, gently rounded 3px corners, and subtle vertical
//! gradients with thin borders. Light (Breeze) & dark (Breeze Dark) follow the
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

/// Noto Sans / Oxygen scale.
const typography = Typography{
    .large_title = .{ .size = 24, .weight = .bold },
    .title = .{ .size = 20, .weight = .regular },
    .title2 = .{ .size = 16, .weight = .regular },
    .title3 = .{ .size = 14, .weight = .medium },
    .headline = .{ .size = 13, .weight = .bold },
    .body = .{ .size = 13, .weight = .regular },
    .callout = .{ .size = 12, .weight = .regular },
    .subheadline = .{ .size = 12, .weight = .regular },
    .footnote = .{ .size = 11, .weight = .regular },
    .caption = .{ .size = 11, .weight = .regular },
    .caption2 = .{ .size = 10, .weight = .regular },
};

/// Breeze rounds corners by ~3px and uses a slightly tall control.
const metrics = Metrics{
    .corner_radius = 6,
    .control_corner_radius = 3,
    .panel_corner_radius = 8,
    .selection_corner_radius = 3,
    .window_corner_radius = 6,
    .control_height = 28,
    .hairline = 1,
};

// ---------------------------------------------------------------------------
// Painter — subtle gradients + thin borders
// ---------------------------------------------------------------------------

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) Err!Color {
    const r = s.metrics.control_corner_radius;
    if (role == .plain) return s.palette.accent;
    if (role == .destructive) {
        try s.vGradient(rect, r, s.palette.destructive.lighten(0.08), s.palette.destructive.darken(0.06));
        try s.stroke(rect, r, 1, s.palette.destructive.darken(0.15));
        return s.palette.on_accent;
    }
    if (role == .prominent) {
        // The Breeze default action: the same gradient treatment in the accent.
        try s.vGradient(rect, r, s.palette.accent.lighten(0.08), s.palette.accent.darken(0.06));
        try s.stroke(rect, r, 1, s.palette.accent.darken(0.15));
        return s.palette.on_accent;
    }
    // Breeze buttons: a faint top-lit gradient over the control face with a thin
    // border; hover lifts toward the accent.
    const base = s.palette.control_track;
    const top = if (st.hovered) base.lighten(0.12) else base.lighten(0.05);
    try s.vGradient(rect, r, top, base.darken(0.04));
    const border = if (st.hovered or st.focused) s.palette.accent else s.palette.control_border;
    try s.stroke(rect, r, 1, border);
    return s.palette.label;
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) Err!void {
    try s.fill(rect, radius, s.palette.control_background);
    const c = if (st.focused) s.palette.accent else s.palette.control_border;
    const w: f32 = if (st.focused) 2 else 1;
    try s.stroke(rect, radius, w, c);
}

fn segmentedTrack(s: Surface, rect: Rect) Err!void {
    const r = s.metrics.control_corner_radius;
    try s.fill(rect, r, s.palette.control_track);
    try s.stroke(rect, r, 1, s.palette.control_border);
}

fn segmentedSelection(s: Surface, seg: Rect) Err!Color {
    const inner = seg.insetBy(2, 2);
    const r = s.metrics.control_corner_radius - 1;
    try s.vGradient(inner, r, s.palette.accent.lighten(0.06), s.palette.accent.darken(0.04));
    return s.palette.on_accent;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) Err!void {
    const r = rect.height / 2;
    if (on) {
        try s.fill(rect, r, s.palette.accent);
    } else {
        try s.fill(rect, r, s.palette.control_track.darken(0.04));
        try s.stroke(rect, r, 1, s.palette.control_border);
    }
}

fn switchKnob(s: Surface, knob: Rect, on: bool) Err!void {
    _ = on;
    // A pale circular handle with a thin Breeze border.
    const r = knob.width / 2;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, s.palette.control_background);
    try s.stroke(knob, r, 1, s.palette.control_border);
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Err!void {
    _ = st;
    const tr = track.height / 2;
    try s.fill(track, tr, s.palette.control_track.darken(0.04));
    try s.stroke(track, tr, 1, s.palette.control_border);
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, tr, s.palette.accent);
    const r = knob.width / 2;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, s.palette.control_background);
    try s.stroke(knob, r, 1, s.palette.control_border);
}

fn stepperBox(s: Surface, rect: Rect, st: ControlState) Err!void {
    _ = st;
    const r = s.metrics.control_corner_radius;
    try s.vGradient(rect, r, s.palette.control_track.lighten(0.05), s.palette.control_track.darken(0.04));
    try s.stroke(rect, r, 1, s.palette.control_border);
}

fn progress(s: Surface, rect: Rect, frac: f32) Err!void {
    const r = rect.height / 2;
    try s.fill(rect, r, s.palette.control_track.darken(0.04));
    try s.stroke(rect, r, 1, s.palette.control_border);
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, r, s.palette.accent);
}

fn panel(s: Surface, rect: Rect, radius: f32, kind: theme.PanelKind) Err!void {
    _ = kind; // one panel style fits all in this family
    try s.fill(rect, radius, s.palette.window_background);
    try s.stroke(rect, radius, 1, s.palette.control_border);
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
    .name = "KDE Plasma",
    .scheme = .light,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(61, 174, 233), // Breeze blue
        .label = Color.fromRgb8(35, 38, 41), // Breeze "Text"
        .secondary_label = Color.fromRgb8(91, 95, 99),
        .tertiary_label = Color.fromRgb8(136, 140, 144),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(239, 240, 241), // Breeze Window
        .secondary_background = Color.fromRgb8(227, 229, 231),
        .control_background = Color.fromRgb8(252, 252, 252), // Breeze View
        .separator = Color.fromRgb8(188, 192, 196),
        .selection = Color.fromRgb8(61, 174, 233),
        .destructive = Color.fromRgb8(218, 68, 83), // Breeze red
        .hover = Color.fromRgb8(61, 174, 233).withAlpha(0.12),
        .control_border = Color.fromRgb8(188, 192, 196),
        .glass = Color.fromRgb8(239, 240, 241).withAlpha(0.85),
        .control_track = Color.fromRgb8(239, 240, 241),
    },
};

pub const dark = Theme{
    .name = "KDE Plasma",
    .scheme = .dark,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(61, 174, 233),
        .label = Color.fromRgb8(252, 252, 252),
        .secondary_label = Color.fromRgb8(189, 195, 199),
        .tertiary_label = Color.fromRgb8(127, 140, 141),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(42, 46, 50), // Breeze Dark Window
        .secondary_background = Color.fromRgb8(49, 54, 59),
        .control_background = Color.fromRgb8(35, 38, 41), // Breeze Dark View
        .separator = Color.fromRgb8(81, 86, 91),
        .selection = Color.fromRgb8(61, 174, 233),
        .destructive = Color.fromRgb8(218, 68, 83),
        .hover = Color.fromRgb8(61, 174, 233).withAlpha(0.18),
        .control_border = Color.fromRgb8(81, 86, 91),
        .glass = Color.fromRgb8(42, 46, 50).withAlpha(0.85),
        .control_track = Color.fromRgb8(49, 54, 59),
    },
};

const testing = std.testing;

test "kde: breeze blue accent and rounded controls" {
    try testing.expect(light.colors.accent.b > light.colors.accent.r);
    try testing.expectEqual(@as(f32, 3), light.metrics.control_corner_radius);
}

test "kde: light and dark differ" {
    try testing.expect(light.colors.window_background.isDark() != dark.colors.window_background.isDark());
}
