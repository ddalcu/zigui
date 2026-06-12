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
//
// Every value here was sampled from real macOS 26 (Tahoe) screenshots of the
// same controls rendered by SwiftUI (`tools/parity/RefGallery.swift`), so the
// painter reproduces what the OS actually draws rather than an interpretation:
// flat fills (no gradients), a soft drop shadow that floats each capsule, a
// one-pixel specular line under the top edge of tinted controls, and the dual
// blues — `accent` (#007AFF) for prominent buttons vs `selection` (#3478F6,
// AppKit's controlAccentColor) for switches/segmented chips/slider fills.
// Raised glass still begins with a `backdropBlur` so controls genuinely frost
// scrolled content beneath them (over a flat background the blur is a no-op).

const Err = std.mem.Allocator.Error;

/// Backdrop frost strength for raised glass controls.
const control_sigma: f32 = 4;
/// Frost for popover/menu material panels.
const popover_sigma: f32 = 18;

/// The soft drop shadow that floats a glass capsule off the surface: two
/// offset translucent fills peeking out below the shape (drawn first, mostly
/// covered by the fill itself). Matches the ~2pt ambient shadow under native
/// controls.
fn dropShadow(s: Surface, rect: Rect, radius: f32, strength: f32) Err!void {
    try s.fill(rect.offsetBy(0, 2).insetBy(-1, -1), radius + 1, Color.black.withAlpha(0.05 * strength));
    try s.fill(rect.offsetBy(0, 1), radius, Color.black.withAlpha(0.10 * strength));
}

/// Neutral ("clear") Liquid Glass — the macOS 26 default control surface.
/// Light mode: a near-white capsule with a white rim, a faint occlusion line
/// under the top edge, and a soft shadow. Dark mode: a darker-than-backdrop
/// fill with a brighter top rim.
fn clearGlass(s: Surface, rect: Rect, radius: f32, st: ControlState, dim: f32) Err!void {
    const lit = s.scheme == .light;
    if (st.disabled) {
        // Native disabled glass is an outline ghost: no fill, no shadow, just
        // a hairline ring with dimmed text.
        const ring = if (lit) Color.black.withAlpha(0.25) else Color.white.withAlpha(0.27);
        try s.stroke(rect, radius, 1, ring);
        return;
    }
    try dropShadow(s, rect, radius, if (lit) 1.0 else 1.6);
    try s.backdropBlur(rect, radius, control_sigma, Color.transparent);
    const inset = @min(radius, rect.width / 2);
    if (lit) {
        try s.fill(rect, radius, Color.white.withAlpha(0.93 * dim));
        // white rim, brightest along the sides/bottom of the capsule
        try s.stroke(rect, radius, 1, Color.white.withAlpha(0.90 * dim));
        // faint occlusion line under the top edge
        try s.lineSeg(
            .{ .x = rect.x + inset, .y = rect.y + 1 },
            .{ .x = rect.maxX() - inset, .y = rect.y + 1 },
            1,
            Color.black.withAlpha(0.04 * dim),
        );
    } else {
        // Dark glass *lifts* off its backdrop — a translucent white wash (a
        // toolbar pill over a near-black window reads lighter, never darker).
        try s.fill(rect, radius, Color.white.withAlpha(0.09 * dim));
        try s.stroke(rect, radius, 1, Color.white.withAlpha(0.07 * dim));
        // brighter refractive line along the top edge
        try s.lineSeg(
            .{ .x = rect.x + inset, .y = rect.y + 1 },
            .{ .x = rect.maxX() - inset, .y = rect.y + 1 },
            1,
            Color.white.withAlpha(0.14 * dim),
        );
    }
    if (st.pressed) {
        try s.fill(rect, radius, Color.black.withAlpha(0.08));
    } else if (st.hovered) {
        try s.fill(rect, radius, s.palette.hover);
    }
}

/// Tinted Liquid Glass (prominent / destructive): a flat tint capsule with a
/// bright 1px specular under the top edge and a soft shadow — exactly how
/// native `.glassProminent` renders at rest.
fn tintedGlass(s: Surface, rect: Rect, radius: f32, tint: Color, st: ControlState, dim: f32) Err!void {
    var bg = tint;
    if (st.pressed) bg = bg.darken(0.08) else if (st.hovered) bg = bg.lighten(0.06);
    if (!st.disabled) try dropShadow(s, rect, radius, 1);
    try s.backdropBlur(rect, radius, control_sigma, Color.transparent);
    try s.fill(rect, radius, bg.withAlpha(0.97).multiplyAlpha(dim));
    const inset = @min(radius, rect.width / 2);
    try s.lineSeg(
        .{ .x = rect.x + inset, .y = rect.y + 0.75 },
        .{ .x = rect.maxX() - inset, .y = rect.y + 0.75 },
        1.5,
        Color.white.withAlpha(0.32 * dim),
    );
}

fn button(s: Surface, rect: Rect, role: Role, st: ControlState) Err!Color {
    const dim: f32 = if (st.disabled) 0.4 else 1.0;
    // In-content macOS 26 buttons are gently rounded rects (~5pt), not
    // capsules — capsules are the *toolbar pill* style (see `glassSurface`).
    const r = @min(s.metrics.control_corner_radius, rect.height / 2);
    switch (role) {
        // Native borderless buttons render with the secondary label color.
        .plain => return s.palette.secondary_label,
        // The everyday button is *neutral* glass with an ordinary label; only
        // prominent (default-action) and destructive buttons carry a tint.
        .normal => {
            try clearGlass(s, rect, r, st, dim);
            return if (st.disabled) s.palette.tertiary_label else s.palette.label;
        },
        .prominent => {
            try tintedGlass(s, rect, r, s.palette.accent, st, dim);
            return s.palette.on_accent;
        },
        .destructive => {
            try tintedGlass(s, rect, r, s.palette.destructive, st, dim);
            return s.palette.on_accent;
        },
    }
}

fn field(s: Surface, rect: Rect, radius: f32, st: ControlState) Err!void {
    try s.fill(rect, radius, s.palette.control_background);
    if (st.focused) {
        // The macOS focus glow: a soft accent halo outside the ring itself.
        try s.stroke(rect.insetBy(-1.5, -1.5), radius + 1.5, 3, s.palette.selection.withAlpha(0.25));
        try s.stroke(rect, radius, 2, s.palette.selection);
    } else {
        try s.stroke(rect, radius, s.metrics.hairline, s.palette.separator);
    }
}

fn segmentedTrack(s: Surface, rect: Rect) Err!void {
    // A flat translucent trough, moderately rounded (native is ~7pt at a 24pt
    // height — not a capsule), with no border.
    try s.fill(rect, 7, s.palette.control_track);
}

fn segmentedSelection(s: Surface, seg: Rect) Err!Color {
    // The selected chip fills the full track height (no inset) as a flat
    // control-accent rounded rect with a faint top specular.
    try s.fill(seg, 5.5, s.palette.selection);
    const inset: f32 = 6;
    try s.lineSeg(
        .{ .x = seg.x + inset, .y = seg.y + 1 },
        .{ .x = seg.maxX() - inset, .y = seg.y + 1 },
        1,
        Color.white.withAlpha(0.25),
    );
    return s.palette.on_accent;
}

fn switchTrack(s: Surface, rect: Rect, on: bool) Err!void {
    const r = rect.height / 2;
    if (on) {
        try s.fill(rect, r, s.palette.selection);
    } else {
        const lit = s.scheme == .light;
        const fillc = if (lit) Color.black.withAlpha(0.11) else Color.white.withAlpha(0.09);
        try s.fill(rect, r, fillc);
        try s.stroke(rect, r, s.metrics.hairline, Color.black.withAlpha(if (lit) 0.04 else 0.15));
    }
}

fn switchKnob(s: Surface, knob: Rect, on: bool) Err!void {
    _ = on; // the knob looks the same on or off; its position encodes the state
    const r = knob.width / 2;
    // a soft shadow grounds the floating knob against the track
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() + 0.75 }, r, Color.black.withAlpha(0.20));
    // dark-mode knobs are slightly translucent (they pick up the track tint)
    const kc = if (s.scheme == .light) Color.white else Color.white.withAlpha(0.87);
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, kc);
}

fn slider(s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Err!void {
    _ = st;
    const lit = s.scheme == .light;
    const tr = track.height / 2;
    const trough = if (lit) Color.black.withAlpha(0.10) else Color.white.withAlpha(0.09);
    try s.fill(track, tr, trough);
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try s.fill(filled, tr, s.palette.selection);
    const r = knob.width / 2;
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() + 0.75 }, r, Color.black.withAlpha(0.20));
    const kc = if (lit) Color.white else Color.white.withAlpha(0.92);
    try s.fillCircle(.{ .x = knob.midX(), .y = knob.midY() }, r, kc);
}

fn stepperBox(s: Surface, rect: Rect, st: ControlState) Err!void {
    _ = st;
    // Native steppers are a flat grey chevron column — same fill as the
    // segmented trough, no border.
    try s.fill(rect, 7, s.palette.control_track);
}

fn progress(s: Surface, rect: Rect, frac: f32) Err!void {
    const r = rect.height / 2;
    const lit = s.scheme == .light;
    const trough = if (lit) Color.black.withAlpha(0.10) else Color.white.withAlpha(0.09);
    try s.fill(rect, r, trough);
    const filled = Rect{ .x = rect.x, .y = rect.y, .width = rect.width * std.math.clamp(frac, 0, 1), .height = rect.height };
    try s.fill(filled, r, s.palette.selection);
}

fn panel(s: Surface, rect: Rect, radius: f32, kind: theme.PanelKind) Err!void {
    // A wide ambient shadow halo grounds the floating panel.
    var i: f32 = 1;
    while (i <= 5) : (i += 1) {
        try s.stroke(rect.insetBy(-i, -i), radius + i, 2, Color.black.withAlpha(0.06 - i * 0.009));
    }
    const lit = s.scheme == .light;
    switch (kind) {
        // Native sheets/alerts are *opaque* elevated panels: white in light
        // mode, near-black (#161616) with a faint rim in dark mode.
        .modal => {
            const bg = if (lit) Color.white else Color.fromRgb8(22, 22, 22);
            try s.fill(rect, radius, bg);
            if (!lit) try s.stroke(rect, radius, 1, Color.white.withAlpha(0.13));
        },
        // Popovers/menus are frosted material.
        .popover => {
            try s.backdropBlur(rect, radius, popover_sigma, s.palette.glass);
            const rim = if (lit) Color.black.withAlpha(0.08) else Color.white.withAlpha(0.13);
            try s.stroke(rect, radius, s.metrics.hairline, rim);
        },
    }
}

/// The `.glassEffect()` surface: the same neutral clear glass as a button at
/// rest (frost + sheen + rim + soft shadow).
fn glassSurface(s: Surface, rect: Rect, radius: f32) Err!void {
    try clearGlass(s, rect, radius, .{}, 1);
}

pub const painter = theme.Painter{
    .button = button,
    .field = field,
    .glassSurface = glassSurface,
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

/// Layout metrics matching the native macOS 26 control sizes (sampled).
const metrics = theme.Metrics{
    // Buttons/segmented controls are 24pt tall on macOS 26.
    .control_height = 24,
    // Form buttons are *moderately* rounded (~5pt at 24pt height) — only
    // toolbar pills are capsules.
    .control_corner_radius = 5.5,
    // Sheets/alerts round at ~20pt; sidebar selection at 6pt.
    .panel_corner_radius = 20,
    .selection_corner_radius = 6,
};

// Palette values sampled from native macOS 26 captures (see the painter notes).
pub const light = Theme{
    .name = "macOS",
    .scheme = .light,
    .typography = typography,
    .painter = painter,
    .metrics = metrics,
    .colors = .{
        .accent = Color.fromRgb8(1, 121, 254), // systemBlue (glassProminent fill)
        .label = Color.black.withAlpha(0.85), // labelColor
        .secondary_label = Color.fromRgb8(122, 122, 122),
        .tertiary_label = Color.black.withAlpha(0.26),
        .on_accent = Color.white,
        // Grouped content: a white window with slightly darker rows/cards.
        .window_background = Color.white,
        .secondary_background = Color.fromRgb8(247, 247, 247),
        .control_background = Color.white,
        .separator = Color.black.withAlpha(0.08),
        // controlAccentColor — switches, segmented chips, slider/progress fills.
        .selection = Color.fromRgb8(52, 120, 246),
        .destructive = Color.fromRgb8(255, 61, 65), // sampled glassProminent red
        // Liquid Glass
        .hover = Color.black.withAlpha(0.05),
        .control_border = Color.black.withAlpha(0.08),
        .glass = Color.fromRgb8(248, 250, 251).withAlpha(0.90),
        .control_track = Color.black.withAlpha(0.075),
        .scrim = Color.black.withAlpha(0.20),
        .quaternary_fill = Color.black.withAlpha(0.12),
        .sidebar_background = Color.fromRgb8(250, 250, 250),
    },
};

pub const dark = Theme{
    .name = "macOS",
    .scheme = .dark,
    .typography = typography,
    .painter = painter,
    .metrics = metrics,
    .colors = .{
        .accent = Color.fromRgb8(0, 121, 255),
        .label = Color.white.withAlpha(0.85),
        .secondary_label = Color.fromRgb8(156, 156, 156),
        .tertiary_label = Color.white.withAlpha(0.25),
        .on_accent = Color.white,
        .window_background = Color.fromRgb8(27, 27, 27),
        .secondary_background = Color.fromRgb8(34, 34, 34),
        .control_background = Color.fromRgb8(44, 44, 44),
        .separator = Color.white.withAlpha(0.12),
        .selection = Color.fromRgb8(57, 124, 247),
        .destructive = Color.fromRgb8(255, 69, 58),
        // Liquid Glass
        .hover = Color.white.withAlpha(0.08),
        .control_border = Color.white.withAlpha(0.14),
        .glass = Color.fromRgb8(44, 44, 44).withAlpha(0.88),
        .control_track = Color.white.withAlpha(0.065),
        .scrim = Color.black.withAlpha(0.30),
        .quaternary_fill = Color.white.withAlpha(0.17),
        .sidebar_background = Color.fromRgb8(26, 27, 27),
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

test "macos: liquid glass buttons frost their backdrop" {
    const Canvas = @import("../render/canvas.zig").Canvas;
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const s = Surface{ .canvas = &canvas, .palette = &light.colors, .metrics = &light.metrics, .scheme = .light };
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 28 };
    const label_color = try painter.button(s, rect, .normal, .{});
    // Neutral glass keeps the ordinary label color…
    try testing.expect(label_color.approxEql(light.colors.label, 0.001));
    // …and draws a backdrop frost (after the drop shadow).
    var saw_blur = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .blur_rect) saw_blur = true;
    }
    try testing.expect(saw_blur);
}

test "macos: prominent and destructive buttons are tinted glass" {
    const Canvas = @import("../render/canvas.zig").Canvas;
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const s = Surface{ .canvas = &canvas, .palette = &light.colors, .metrics = &light.metrics, .scheme = .light };
    const rect = Rect{ .x = 0, .y = 0, .width = 80, .height = 28 };
    try testing.expect((try painter.button(s, rect, .prominent, .{})).approxEql(light.colors.on_accent, 0.001));
    try testing.expect((try painter.button(s, rect, .destructive, .{})).approxEql(light.colors.on_accent, 0.001));
}

test "macos: popover panels are deep-frosted glass; modals are opaque" {
    const Canvas = @import("../render/canvas.zig").Canvas;
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const s = Surface{ .canvas = &canvas, .palette = &dark.colors, .metrics = &dark.metrics, .scheme = .dark };
    try painter.panel(s, .{ .x = 10, .y = 10, .width = 200, .height = 120 }, 16, .popover);
    var saw_blur = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .blur_rect) {
            saw_blur = true;
            try testing.expect(cmd.blur_rect.sigma > control_sigma);
        }
    }
    try testing.expect(saw_blur);
    // A modal sheet/alert is an opaque elevated panel — no backdrop sampling.
    canvas.clearCommands();
    try painter.panel(s, .{ .x = 10, .y = 10, .width = 200, .height = 120 }, 16, .modal);
    for (canvas.commands.items) |cmd| try testing.expect(cmd != .blur_rect);
}
