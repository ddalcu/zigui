//! macOS theme (light & dark): Apple's "Liquid Glass" appearance — translucent
//! surfaces, vertical gradient sheens, and bright edge rims. The painter draws
//! the chrome; palette values approximate macOS's dynamic system colors and the
//! SF Pro type scale. No Apple assets are used — only color/size tokens.

const std = @import("std");
const theme = @import("theme.zig");
const Color = @import("../render/color.zig").Color;
const geom = @import("../layout/geometry.zig");

const Theme = theme.Theme;
const Typography = theme.Typography;
const Surface = theme.Surface;
const ControlState = theme.ControlState;
const Role = theme.Role;
const Rect = geom.Rect;

/// macOS type scale (point sizes / weights roughly matching the system).
const typography = Typography{
    .large_title = .{ .size = 26, .weight = .bold },
    .title = .{ .size = 22, .weight = .regular },
    .title2 = .{ .size = 17, .weight = .regular },
    .title3 = .{ .size = 15, .weight = .regular },
    .headline = .{ .size = 13, .weight = .semibold },
    .body = .{ .size = 13, .weight = .regular },
    .callout = .{ .size = 12, .weight = .regular },
    .subheadline = .{ .size = 11, .weight = .regular },
    .footnote = .{ .size = 10, .weight = .regular },
    .caption = .{ .size = 10, .weight = .regular },
    .caption2 = .{ .size = 10, .weight = .regular },
};

// ---------------------------------------------------------------------------
// Painter — the Liquid Glass look
// ---------------------------------------------------------------------------

/// The Liquid Glass treatment shared by buttons, the selected segment, and the
/// switch track: a vertical sheen over `bg`, a bright rim, and a specular
/// highlight tucked under the top edge so the capsule reads as curved glass.
fn glassCapsule(s: Surface, rect: Rect, radius: f32, bg: Color, dim: f32) std.mem.Allocator.Error!void {
    try s.vGradient(rect, radius, bg.lighten(0.22).multiplyAlpha(dim), bg.darken(0.06).multiplyAlpha(dim));
    try s.stroke(rect, radius, s.metrics.hairline, Color.white.withAlpha(0.30 * dim));
    const inset = @min(radius, rect.width / 2);
    try s.lineSeg(
        .{ .x = rect.x + inset, .y = rect.y + 1.5 },
        .{ .x = rect.maxX() - inset, .y = rect.y + 1.5 },
        1,
        Color.white.withAlpha(0.35 * dim),
    );
}

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) std.mem.Allocator.Error!Color {
    const dim: f32 = if (st.disabled) 0.4 else 1.0;
    if (role == .plain) return s.palette.accent;
    var bg = if (role == .destructive) s.palette.destructive else s.palette.accent;
    if (st.pressed) bg = bg.darken(0.08) else if (st.hovered) bg = bg.lighten(0.06);
    // macOS 26 buttons are full capsules, not rounded rects.
    try glassCapsule(s, rect, rect.height / 2, bg, dim);
    return s.palette.on_accent;
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) std.mem.Allocator.Error!void {
    try s.fill(rect, radius, s.palette.control_background);
    const c = if (st.focused) s.palette.accent else s.palette.separator;
    const w: f32 = if (st.focused) 2 else s.metrics.hairline;
    try s.stroke(rect, radius, w, c);
}

fn segmentedTrack(s: Surface, rect: Rect) std.mem.Allocator.Error!void {
    // A recessed translucent capsule trough with a hairline rim.
    const r = rect.height / 2;
    try s.fill(rect, r, s.palette.control_track.over(s.palette.window_background));
    try s.stroke(rect, r, s.metrics.hairline, s.palette.control_border);
}

fn segmentedSelection(s: Surface, seg: Rect) std.mem.Allocator.Error!Color {
    // The selected segment floats as an accent glass capsule (the macOS 26
    // tinted segmented style), so its label flips to `on_accent`.
    const inner = seg.insetBy(2, 2);
    try glassCapsule(s, inner, inner.height / 2, s.palette.accent, 1);
    return s.palette.on_accent;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) std.mem.Allocator.Error!void {
    const r = rect.height / 2;
    if (on) {
        // The on track gets the same glass treatment as a button.
        try glassCapsule(s, rect, r, s.palette.accent, 1);
    } else {
        try s.fill(rect, r, s.palette.control_track.over(s.palette.control_background));
        try s.stroke(rect, r, s.metrics.hairline, s.palette.control_border);
    }
}

fn switchKnob(s: Surface, knob: Rect, on: bool) std.mem.Allocator.Error!void {
    _ = on; // the knob looks the same on or off; its position encodes the state
    const r = knob.width / 2;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, Color.white);
    // a faint rim grounds the knob against the track
    try s.stroke(knob, r, s.metrics.hairline, Color.black.withAlpha(0.10));
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) std.mem.Allocator.Error!void {
    _ = st;
    const tr = track.height / 2;
    try s.fill(track, tr, s.palette.separator.over(s.palette.control_background));
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, tr, s.palette.accent);
    const r = knob.width / 2;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, Color.white);
    try s.stroke(knob, r, 1, s.palette.separator);
}

fn stepperBox(s: Surface, rect: Rect, st: ControlState) std.mem.Allocator.Error!void {
    _ = st;
    const r = s.metrics.control_corner_radius;
    try s.fill(rect, r, s.palette.control_background);
    try s.stroke(rect, r, s.metrics.hairline, s.palette.separator);
}

fn progress(s: Surface, rect: Rect, frac: f32) std.mem.Allocator.Error!void {
    const r = rect.height / 2;
    try s.fill(rect, r, s.palette.separator.over(s.palette.control_background));
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, r, s.palette.accent);
}

fn panel(s: Surface, rect: Rect, radius: f32) std.mem.Allocator.Error!void {
    try s.fill(rect, radius, s.palette.control_background);
    try s.stroke(rect, radius, s.metrics.hairline, s.palette.separator);
    // The glass bevel: a soft specular along the top inside edge (invisible on
    // a white light-mode panel, a subtle catch-light on a dark one).
    const inset = @min(radius, rect.width / 2);
    try s.lineSeg(
        .{ .x = rect.x + inset, .y = rect.y + 1 },
        .{ .x = rect.maxX() - inset, .y = rect.y + 1 },
        1,
        Color.white.withAlpha(0.12),
    );
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
    .name = "macOS",
    .scheme = .light,
    .typography = typography,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(0, 122, 255), // System Blue
        .label = Color.black.withAlpha(0.85), // labelColor
        .secondary_label = Color.black.withAlpha(0.50),
        .tertiary_label = Color.black.withAlpha(0.26),
        .on_accent = Color.white,
        // macOS 26 windows read brighter and a touch warmer than the flat grey.
        .window_background = Color.fromRgb8(242, 242, 247),
        .secondary_background = Color.fromRgb8(250, 250, 252),
        .control_background = Color.white,
        .separator = Color.black.withAlpha(0.10),
        .selection = Color.fromRgb8(0, 122, 255),
        .destructive = Color.fromRgb8(255, 59, 48), // System Red
        // Liquid Glass
        .hover = Color.black.withAlpha(0.06),
        .control_border = Color.black.withAlpha(0.08),
        .glass = Color.white.withAlpha(0.65),
        .control_track = Color.black.withAlpha(0.06),
    },
};

pub const dark = Theme{
    .name = "macOS",
    .scheme = .dark,
    .typography = typography,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(10, 132, 255), // System Blue (dark)
        .label = Color.white.withAlpha(0.85),
        .secondary_label = Color.white.withAlpha(0.55),
        .tertiary_label = Color.white.withAlpha(0.25),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(28, 28, 30),
        .secondary_background = Color.fromRgb8(38, 38, 41),
        .control_background = Color.fromRgb8(54, 54, 58),
        .separator = Color.white.withAlpha(0.15),
        .selection = Color.fromRgb8(10, 132, 255),
        .destructive = Color.fromRgb8(255, 69, 58),
        // Liquid Glass
        .hover = Color.white.withAlpha(0.10),
        .control_border = Color.white.withAlpha(0.14),
        .glass = Color.fromRgb8(60, 60, 64).withAlpha(0.55),
        .control_track = Color.white.withAlpha(0.10),
    },
};

/// The library-wide default theme.
pub const default = light;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "macos: light and dark differ in background and label" {
    try testing.expect(!light.colors.window_background.approxEql(dark.colors.window_background, 0.01));
    // light label is dark-on-light; dark label is light-on-dark
    try testing.expect(light.colors.label.isDark());
    try testing.expect(!dark.colors.label.isDark());
}

test "macos: body font is 13pt regular" {
    try testing.expectEqual(@as(f32, 13), light.typography.body.size);
    try testing.expectEqual(theme.FontWeight.regular, light.typography.body.weight);
}

test "macos: accent is a recognizable blue" {
    const a = light.colors.accent;
    try testing.expect(a.b > a.r and a.b > a.g); // blue dominant
}

test "macos: default is light" {
    try testing.expectEqual(theme.ColorScheme.light, default.scheme);
}
