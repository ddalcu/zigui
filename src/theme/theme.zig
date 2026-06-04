//! Theme: the design-token vocabulary that gives zigui its look. A `Theme`
//! bundles semantic color roles, a typographic scale, and layout metrics.
//! Components read tokens from the active theme rather than hard-coding values,
//! so the whole UI restyles by swapping one struct (see `theme/macos.zig` for
//! the default macOS light/dark presets).

const std = @import("std");
const Color = @import("../render/color.zig").Color;

pub const ColorScheme = enum { light, dark };

/// SF-style font weights.
pub const FontWeight = enum {
    ultra_light,
    thin,
    light,
    regular,
    medium,
    semibold,
    bold,
    heavy,
    black,
};

/// A named text style: point size + weight (and a line-height multiple used by
/// the text layout pass).
pub const TextStyle = struct {
    size: f32,
    weight: FontWeight = .regular,
    line_height: f32 = 1.2,
};

/// Semantic color roles. Names follow macOS's dynamic system colors so the same
/// role resolves to an appropriate value in light or dark mode.
pub const Colors = struct {
    /// The accent / tint color (macOS "System Blue" by default).
    accent: Color,
    /// Primary text/content color (labelColor).
    label: Color,
    secondary_label: Color,
    tertiary_label: Color,
    /// Color for content drawn on top of the accent (e.g. button text).
    on_accent: Color,
    /// Window / scene background.
    window_background: Color,
    /// Background for grouped content areas.
    secondary_background: Color,
    /// Fill for controls (text fields, etc.).
    control_background: Color,
    /// Hairline separators / dividers.
    separator: Color,
    /// Selection highlight.
    selection: Color,
    /// Destructive / error (System Red).
    destructive: Color,
};

/// The typographic scale, mirroring SwiftUI's `Font.TextStyle` cases at macOS
/// point sizes.
pub const Typography = struct {
    large_title: TextStyle,
    title: TextStyle,
    title2: TextStyle,
    title3: TextStyle,
    headline: TextStyle,
    body: TextStyle,
    callout: TextStyle,
    subheadline: TextStyle,
    footnote: TextStyle,
    caption: TextStyle,
    caption2: TextStyle,

    /// The default font for unstyled text.
    pub fn defaultStyle(self: Typography) TextStyle {
        return self.body;
    }
};

/// Spacing, sizing, and radius metrics.
pub const Metrics = struct {
    /// Default spacing between elements in a stack.
    spacing: f32 = 8,
    spacing_small: f32 = 4,
    spacing_large: f32 = 16,
    /// Default content padding.
    padding: f32 = 8,
    /// Corner radius for cards / grouped containers.
    corner_radius: f32 = 8,
    /// Corner radius for push buttons and controls.
    control_corner_radius: f32 = 6,
    /// Standard control (button/field) height.
    control_height: f32 = 28,
    /// Window corner radius.
    window_corner_radius: f32 = 10,
    /// Hairline thickness for separators/borders at 1x.
    hairline: f32 = 1,
};

pub const Theme = struct {
    scheme: ColorScheme,
    colors: Colors,
    typography: Typography,
    metrics: Metrics = .{},

    /// Resolve a named text style.
    pub fn font(self: Theme, name: enum {
        large_title,
        title,
        title2,
        title3,
        headline,
        body,
        callout,
        subheadline,
        footnote,
        caption,
        caption2,
    }) TextStyle {
        return switch (name) {
            .large_title => self.typography.large_title,
            .title => self.typography.title,
            .title2 => self.typography.title2,
            .title3 => self.typography.title3,
            .headline => self.typography.headline,
            .body => self.typography.body,
            .callout => self.typography.callout,
            .subheadline => self.typography.subheadline,
            .footnote => self.typography.footnote,
            .caption => self.typography.caption,
            .caption2 => self.typography.caption2,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Theme: font() resolves named styles" {
    const macos = @import("macos.zig");
    const t = macos.light;
    try testing.expectEqual(t.typography.body, t.font(.body));
    try testing.expectEqual(t.typography.large_title, t.font(.large_title));
}

test "Metrics: sensible defaults" {
    const m = Metrics{};
    try testing.expectEqual(@as(f32, 8), m.spacing);
    try testing.expectEqual(@as(f32, 6), m.control_corner_radius);
}
