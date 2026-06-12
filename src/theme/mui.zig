//! Material UI theme (Google Material Design): flat, ink-on-paper surfaces with
//! a bold primary color, 4px rounded corners, "contained" filled buttons, thin
//! tracks with circular thumbs, and outlined inputs. Light & dark follow the OS
//! appearance (Material's baseline `#1976d2` primary on light, `#90caf9` on
//! dark). The renderer has no box-shadow primitive, so elevation is suggested
//! with subtle tints/borders rather than drop shadows.

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

/// Roboto-ish scale: Material's type ramp, scaled for a desktop UI.
const typography = Typography{
    .large_title = .{ .size = 28, .weight = .medium },
    .title = .{ .size = 24, .weight = .regular },
    .title2 = .{ .size = 20, .weight = .medium },
    .title3 = .{ .size = 18, .weight = .regular },
    .headline = .{ .size = 16, .weight = .medium },
    .body = .{ .size = 14, .weight = .regular },
    .callout = .{ .size = 14, .weight = .regular },
    .subheadline = .{ .size = 13, .weight = .regular },
    .footnote = .{ .size = 12, .weight = .regular },
    .caption = .{ .size = 12, .weight = .regular },
    .caption2 = .{ .size = 11, .weight = .regular },
};

/// Material rounds by 4px and uses a 36px-tall control (the spec button height).
const metrics = Metrics{
    .corner_radius = 8,
    .control_corner_radius = 4,
    .panel_corner_radius = 4,
    .selection_corner_radius = 4,
    .window_corner_radius = 0,
    .control_height = 36,
    .hairline = 1,
};

// ---------------------------------------------------------------------------
// Painter — flat fills, a strong primary, circular thumbs
// ---------------------------------------------------------------------------

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) Err!Color {
    // A "text button": label-only, no container.
    if (role == .plain) return s.palette.accent;
    const r = s.metrics.control_corner_radius;
    if (st.disabled) {
        // Material disables to neutral grey (action.disabledBackground), not a
        // faded primary.
        try s.fill(rect, r, s.palette.label.withAlpha(0.12));
        return s.palette.label.withAlpha(0.38);
    }
    const base = if (role == .destructive) s.palette.destructive else s.palette.accent;
    // Material darkens the container on hover (an action-state overlay).
    const fillc = if (st.hovered) base.darken(0.08) else base;
    try s.fill(rect, r, fillc);
    return s.palette.on_accent;
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) Err!void {
    // The Material "outlined" text field: a thin box that thickens and tints to
    // the primary color on focus.
    try s.fill(rect, radius, s.palette.control_background);
    const c = if (st.focused) s.palette.accent else s.palette.control_border;
    const w: f32 = if (st.focused) 2 else 1;
    try s.stroke(rect, radius, w, c);
}

fn segmentedTrack(s: Surface, rect: Rect) Err!void {
    // A toggle-button group: an outlined container.
    const r = s.metrics.control_corner_radius;
    try s.fill(rect, r, s.palette.control_background);
    try s.stroke(rect, r, 1, s.palette.control_border);
}

fn segmentedSelection(s: Surface, seg: Rect) Err!Color {
    // The selected toggle button is a primary-tinted cell with primary text
    // (MUI's ToggleButton selected state).
    try s.fill(seg.insetBy(1, 1), s.metrics.control_corner_radius, s.palette.accent.withAlpha(0.12));
    return s.palette.accent;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) Err!void {
    // The Material switch is a thin track the thumb overhangs — not a full-
    // height iOS pill. On tints to a translucent primary; off is a grey wash.
    const h: f32 = 14;
    const track = Rect{ .x = rect.x + 2, .y = rect.midY() - h / 2, .width = rect.width - 4, .height = h };
    const c = if (on) s.palette.accent.withAlpha(0.5) else s.palette.control_track;
    try s.fill(track, h / 2, c);
}

fn switchKnob(s: Surface, knob: Rect, on: bool) Err!void {
    // The thumb is wider than the track. On: solid primary. Off: a pale disc
    // with a hairline border standing in for the spec's elevation shadow.
    const r = knob.width / 2;
    const off_thumb = if (s.scheme == .dark) Color.fromRgb8(189, 189, 189) else Color.white;
    const c = if (on) s.palette.accent else off_thumb;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, c);
    if (!on) try s.stroke(knob, r, 1, s.palette.control_border);
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Err!void {
    _ = st;
    const tr = track.height / 2;
    // An unfilled rail in a faded primary, a solid primary fill, a primary thumb.
    try s.fill(track, tr, s.palette.accent.withAlpha(0.38));
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, tr, s.palette.accent);
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
    try s.fill(rect, r, s.palette.accent.withAlpha(0.3));
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, r, s.palette.accent);
}

fn panel(s: Surface, rect: Rect, radius: f32, kind: theme.PanelKind) Err!void {
    _ = kind; // one panel style fits all in this family
    // A raised surface (card/menu/dialog). No shadow primitive, so a thin border
    // grounds it against the background.
    try s.fill(rect, radius, s.palette.control_background);
    try s.stroke(rect, radius, 1, s.palette.separator);
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
    .name = "Material",
    .scheme = .light,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(25, 118, 210), // Material primary (#1976d2)
        .label = Color.black.withAlpha(0.87), // text primary
        .secondary_label = Color.black.withAlpha(0.60),
        .tertiary_label = Color.black.withAlpha(0.38),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(250, 250, 250), // grey 50
        .secondary_background = Color.white,
        .control_background = Color.white,
        .separator = Color.black.withAlpha(0.12), // divider
        .selection = Color.fromRgb8(25, 118, 210),
        .destructive = Color.fromRgb8(211, 47, 47), // error (#d32f2f)
        .hover = Color.black.withAlpha(0.04),
        .control_border = Color.black.withAlpha(0.23), // outlined input border
        .glass = Color.white.withAlpha(0.7),
        .control_track = Color.black.withAlpha(0.38), // switch-off track (spec)
    },
};

pub const dark = Theme{
    .name = "Material",
    .scheme = .dark,
    .typography = typography,
    .metrics = metrics,
    .painter = painter,
    .colors = .{
        .accent = Color.fromRgb8(144, 202, 249), // dark primary (#90caf9)
        .label = Color.white,
        .secondary_label = Color.white.withAlpha(0.70),
        .tertiary_label = Color.white.withAlpha(0.50),
        .on_accent = Color.black.withAlpha(0.87), // dark text on the light-blue primary
        .window_background = Color.fromRgb8(18, 18, 18), // Material dark background
        .secondary_background = Color.fromRgb8(30, 30, 30),
        .control_background = Color.fromRgb8(30, 30, 30), // surface (#1e1e1e)
        .separator = Color.white.withAlpha(0.12),
        .selection = Color.fromRgb8(144, 202, 249),
        .destructive = Color.fromRgb8(244, 67, 54), // error (#f44336)
        .hover = Color.white.withAlpha(0.08),
        .control_border = Color.white.withAlpha(0.23),
        .glass = Color.fromRgb8(30, 30, 30).withAlpha(0.8),
        .control_track = Color.white.withAlpha(0.3), // switch-off track (spec)
    },
};

const testing = std.testing;

test "mui: material blue primary and 4px controls" {
    try testing.expect(light.colors.accent.b > light.colors.accent.r);
    try testing.expectEqual(@as(f32, 4), light.metrics.control_corner_radius);
}

test "mui: light and dark backgrounds differ" {
    try testing.expect(light.colors.window_background.isDark() != dark.colors.window_background.isDark());
}

test "mui: dark mode uses dark text on the light primary" {
    try testing.expect(dark.colors.on_accent.isDark());
}
