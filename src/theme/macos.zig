//! Default macOS theme presets (light & dark), tuned to resemble Apple's system
//! appearance. Values approximate macOS's dynamic system colors and the SF Pro
//! macOS type scale. No Apple assets are used — only color/size tokens.

const theme = @import("theme.zig");
const Color = @import("../render/color.zig").Color;
const Theme = theme.Theme;
const TextStyle = theme.TextStyle;
const Typography = theme.Typography;

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

pub const light = Theme{
    .scheme = .light,
    .typography = typography,
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
    .scheme = .dark,
    .typography = typography,
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

const std = @import("std");
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
