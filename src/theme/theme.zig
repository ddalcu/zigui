//! Theme: the design-token vocabulary *and* drawing strategy that give a zigui
//! app its look. A `Theme` bundles three things:
//!
//!   * a **`Palette`** of semantic color roles (resolved for one `ColorScheme`),
//!   * a typographic scale and layout **`Metrics`**, and
//!   * a **`Painter`** — a small vtable of functions that draw the *chrome* of
//!     the theme-defining controls (buttons, switches, fields, segmented
//!     controls).
//!
//! Splitting the palette from the painter is what lets very different looks
//! coexist: macOS draws translucent "liquid glass" with gradient sheens, while
//! Windows 2000 chisels raised/sunken bevels from the same token vocabulary.
//! Components read tokens and call the painter rather than hard-coding a look,
//! so the whole UI restyles by swapping one `Theme`.
//!
//! A `Painter` depends only on the renderer (`Canvas`, `Color`, geometry) and
//! these tokens — never on the view layer — so the two compose without a
//! dependency cycle: the view layer owns text, layout, and interaction; the
//! painter owns decoration.
//!
//! Concrete themes live alongside this file (`macos.zig`, `win2000.zig`,
//! `windows10.zig`, `kde.zig`); `registry.zig` selects one for the OS color
//! scheme.

const std = @import("std");
const Color = @import("../render/color.zig").Color;
const geom = @import("../layout/geometry.zig");
const canvas_mod = @import("../render/canvas.zig");

const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Point = geom.Point;
const Canvas = canvas_mod.Canvas;

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

/// The semantic appearance of a control, used by buttons (and reusable by other
/// roled controls). `normal` is the theme's everyday button; `prominent` is the
/// emphasized/default action (accent-tinted on most themes); `plain` is a
/// borderless, label-only button.
pub const Role = enum { normal, prominent, destructive, plain };

/// Semantic color roles, resolved for a single `ColorScheme`. The first block
/// follows macOS's dynamic system colors; the bevel block at the end is only
/// meaningful for chiseled (Windows-9x/2000) painters and is defaulted so flat
/// themes can ignore it.
pub const Palette = struct {
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

    // --- Translucent "liquid glass" roles (macOS) -------------------------
    /// A subtle fill painted behind a control/row while the cursor hovers it.
    hover: Color,
    /// The bright hairline edge along the top/sides of a glass control.
    control_border: Color,
    /// A translucent tint laid over blurred content for glass panels.
    glass: Color,
    /// Fill for an unselected segmented/glass control track.
    control_track: Color,
    /// The dimming wash drawn across the window beneath a modal overlay.
    scrim: Color = Color.black.withAlpha(0.2),
    /// Neutral selected-row fill (macOS sidebar selection is grey, not accent).
    quaternary_fill: Color = Color.black.withAlpha(0.10),
    /// Sidebar pane background, when it differs from `secondary_background`
    /// (macOS sidebars are #FAFAFA light / #1A1B1B dark). Null = fall back to
    /// `secondary_background`.
    sidebar_background: ?Color = null,

    // --- Chiseled bevel roles (Windows 2000 / 9x) -------------------------
    // The 3D edge colors of the classic raised/sunken look. Defaulted so flat
    // and glass themes need not spell them out.
    /// The face color of a raised control (the button body).
    control_face: Color = Color.fromRgb8(212, 208, 200),
    /// Brightest bevel edge (outer top-left of a raised control).
    control_highlight: Color = Color.white,
    /// Light bevel edge (inner top-left).
    control_light: Color = Color.fromRgb8(223, 223, 223),
    /// Shadow bevel edge (inner bottom-right).
    control_shadow: Color = Color.fromRgb8(128, 128, 128),
    /// Darkest bevel edge (outer bottom-right).
    control_dark_shadow: Color = Color.fromRgb8(64, 64, 64),
    /// Label color on a raised/grey control (vs. `on_accent` for tinted ones).
    on_control: Color = Color.black,
};

/// The typographic scale, mirroring SwiftUI's `Font.TextStyle` cases.
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
    corner_radius: f32 = 12,
    /// Corner radius for push buttons and controls.
    control_corner_radius: f32 = 7,
    /// Corner radius for large panels (sidebars, sheets, popovers).
    panel_corner_radius: f32 = 16,
    /// Standard control (button/field) height.
    control_height: f32 = 28,
    /// Rounded selection-highlight radius for sidebar / list rows.
    selection_corner_radius: f32 = 8,
    /// Window corner radius.
    window_corner_radius: f32 = 10,
    /// Hairline thickness for separators/borders at 1x.
    hairline: f32 = 1,
};

// ---------------------------------------------------------------------------
// Painter: the per-theme drawing strategy
// ---------------------------------------------------------------------------

/// What a floating panel is for: native macOS draws modals (sheets/alerts) as
/// opaque elevated panels but popovers/menus as frosted material.
pub const PanelKind = enum { modal, popover };

/// The interaction state of a control, passed to painter functions so a theme
/// can render pressed/hovered/focused/disabled variants.
pub const ControlState = struct {
    pressed: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

/// Everything a painter needs to draw chrome: the target `canvas`, the active
/// `palette`/`metrics`, the `scheme` (light/dark), and the inherited `opacity`.
/// Convenience methods apply `opacity` so painters read declaratively.
pub const Surface = struct {
    canvas: *Canvas,
    palette: *const Palette,
    metrics: *const Metrics,
    scheme: ColorScheme,
    opacity: f32 = 1,

    pub fn fill(s: Surface, rect: Rect, radius: f32, c: Color) Allocator.Error!void {
        try s.canvas.fillRoundedRect(rect, radius, c.multiplyAlpha(s.opacity));
    }
    pub fn stroke(s: Surface, rect: Rect, radius: f32, width: f32, c: Color) Allocator.Error!void {
        try s.canvas.strokeRoundedRect(rect, radius, width, c.multiplyAlpha(s.opacity));
    }
    /// A top-to-bottom (vertical) gradient filling `rect`.
    pub fn vGradient(s: Surface, rect: Rect, radius: f32, top: Color, bottom: Color) Allocator.Error!void {
        try s.canvas.push(.{ .linear_gradient = .{
            .rect = rect,
            .radius = radius,
            .start = .{ .x = rect.x, .y = rect.y },
            .end = .{ .x = rect.x, .y = rect.maxY() },
            .c0 = top.multiplyAlpha(s.opacity),
            .c1 = bottom.multiplyAlpha(s.opacity),
        } });
    }
    pub fn lineSeg(s: Surface, a: Point, b: Point, width: f32, c: Color) Allocator.Error!void {
        try s.canvas.line(a, b, width, c.multiplyAlpha(s.opacity));
    }
    pub fn fillCircle(s: Surface, center: Point, r: f32, c: Color) Allocator.Error!void {
        try s.canvas.fillCircle(center, r, c.multiplyAlpha(s.opacity));
    }
    /// Frost the content already drawn beneath `rect` (a `blur_rect`), then lay
    /// `tint` over the result — the backdrop-sampling half of a glass surface.
    /// Pair with a translucent fill and a rim drawn on top.
    pub fn backdropBlur(s: Surface, rect: Rect, radius: f32, sigma: f32, tint: Color) Allocator.Error!void {
        try s.canvas.blurRect(rect, radius, sigma, tint.multiplyAlpha(s.opacity));
    }
};

/// A vtable of chrome-drawing functions — the heart of a theme's identity. Each
/// draws only decoration (fills, borders, bevels, gradients); the view layer
/// draws labels, lays things out, and registers hit regions around them.
pub const Painter = struct {
    /// Draw a push-button's background/border in `rect`, then return the color
    /// its label should be drawn in (so a theme controls both at once).
    button: *const fn (s: Surface, rect: Rect, role: Role, st: ControlState) Allocator.Error!Color,
    /// Draw a text-input surface (background + border) with the given corner
    /// `radius`; `st.focused` selects the focused appearance.
    field: *const fn (s: Surface, rect: Rect, radius: f32, st: ControlState) Allocator.Error!void,
    /// Draw the recessed track behind a whole segmented control.
    segmentedTrack: *const fn (s: Surface, rect: Rect) Allocator.Error!void,
    /// Draw the highlight chip behind the selected segment (`seg`), then return
    /// the color its label should be drawn in (an accent-filled chip needs
    /// `on_accent` text; a pale chip keeps `label`).
    segmentedSelection: *const fn (s: Surface, seg: Rect) Allocator.Error!Color,
    /// Draw an on/off switch track. The sliding knob is drawn separately by
    /// `switchKnob` (the view layer owns the knob *geometry* and calls both in
    /// sequence).
    switchTrack: *const fn (s: Surface, rect: Rect, on: bool) Allocator.Error!void,
    /// Draw the toggle's sliding thumb within `knob` (a square bounding the
    /// circular knob); `on` lets a theme tint it differently per state.
    switchKnob: *const fn (s: Surface, knob: Rect, on: bool) Allocator.Error!void,
    /// Draw a slider: the unfilled `track`, the filled portion (`track` scaled by
    /// `frac` in 0..1), and the handle within `knob`.
    slider: *const fn (s: Surface, track: Rect, frac: f32, knob: Rect, st: ControlState) Allocator.Error!void,
    /// Draw the +/- control box chrome (fill + border/bevel); the divider and
    /// glyph lines are drawn by the view layer.
    stepperBox: *const fn (s: Surface, rect: Rect, st: ControlState) Allocator.Error!void,
    /// Draw a determinate progress bar: the track, then the filled portion
    /// (`rect` scaled by `frac` in 0..1).
    progress: *const fn (s: Surface, rect: Rect, frac: f32) Allocator.Error!void,
    /// Draw the frame (background + border/bevel) for a floating panel with the
    /// given corner `radius`: `kind` distinguishes modals (sheets/alerts) from
    /// popovers/menus so a theme can render them as different materials.
    panel: *const fn (s: Surface, rect: Rect, radius: f32, kind: PanelKind) Allocator.Error!void,
    /// Draw a freestanding glass surface behind arbitrary content (the
    /// `.glassEffect()` modifier — toolbar pills, floating bars, inset
    /// sidebars). Optional: themes without a glass identity fall back to a
    /// translucent `control_track` fill with a `control_border` ring.
    glassSurface: ?*const fn (s: Surface, rect: Rect, radius: f32) Allocator.Error!void = null,
};

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// A fully-resolved theme for one `ColorScheme`: a palette, a type scale, layout
/// metrics, and the painter that gives it its look. Built per scheme by the
/// concrete theme modules; `registry.zig` picks one for the OS appearance.
pub const Theme = struct {
    /// Human-readable name of the theme family (e.g. "macOS", "Windows 2000").
    name: []const u8 = "zigui",
    scheme: ColorScheme,
    colors: Palette,
    typography: Typography,
    metrics: Metrics = .{},
    painter: Painter,

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
    try testing.expectEqual(@as(f32, 7), m.control_corner_radius);
    // Liquid Glass rounds panels more than controls.
    try testing.expect(m.panel_corner_radius > m.corner_radius);
}

test "Palette: bevel tokens default for non-chiseled themes" {
    const macos = @import("macos.zig");
    // macOS doesn't set bevel tokens, so they fall back to the struct defaults.
    try testing.expect(macos.light.colors.control_highlight.approxEql(Color.white, 0.001));
}
