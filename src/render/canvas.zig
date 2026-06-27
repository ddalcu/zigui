//! Canvas: a retained 2D draw-command list. Components paint into a `Canvas` by
//! appending high-level commands (filled/stroked rounded rects, gradients,
//! lines, glyph quads, images, clip push/pop). The command list is the single
//! interface consumed by *both* backends:
//!
//!   * the pure-Zig software rasterizer (`render/raster.zig`) — used for tests
//!     and headless/CI rendering, and
//!   * the GPU backend (`gpu/`) — used for on-screen display.
//!
//! Keeping drawing as data (not immediate GPU calls) is what lets the entire
//! visual layer be unit-tested without a window or GPU.

const std = @import("std");
const geom = @import("../layout/geometry.zig");
const Color = @import("color.zig").Color;

const Rect = geom.Rect;
const Point = geom.Point;
const Allocator = std.mem.Allocator;

/// An 8-bit single-channel coverage bitmap (e.g. a rasterized glyph), row-major.
pub const Coverage = struct {
    width: u32,
    height: u32,
    data: []const u8,
};

/// An RGBA8 image, row-major, 4 bytes per pixel.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const DrawCommand = union(enum) {
    fill_rrect: struct { rect: Rect, radius: f32 = 0, color: Color },
    stroke_rrect: struct { rect: Rect, radius: f32 = 0, width: f32 = 1, color: Color },
    /// Linear gradient clipped to a (possibly rounded) rect, interpolating from
    /// `c0` at `start` to `c1` at `end`.
    linear_gradient: struct {
        rect: Rect,
        radius: f32 = 0,
        start: Point,
        end: Point,
        c0: Color,
        c1: Color,
    },
    line: struct { a: Point, b: Point, width: f32 = 1, color: Color },
    /// A glyph (or any coverage mask) tinted with `color`, drawn so the mask's
    /// top-left lands at `rect` origin and is scaled to `rect` size. `gamma` is
    /// the exponent applied to coverage at composite time (`cov' = pow(cov,
    /// gamma)`): 1.0 leaves it untouched, < 1 thickens the anti-aliased edge
    /// (gamma-correct text on a dark background), > 1 thins it (dark-on-light).
    /// Both backends apply it identically, so the paths stay pixel-matched.
    glyph: struct { rect: Rect, color: Color, coverage: Coverage, gamma: f32 = 1 },
    image: struct { rect: Rect, image: Image },
    /// Blur the pixels already drawn beneath `rect`, then composite `tint` over
    /// the result — the primitive behind frosted "material" backgrounds. `sigma`
    /// controls the blur extent. Backend-neutral: the software rasterizer does a
    /// separable box blur; a future GPU backend samples the framebuffer.
    blur_rect: struct { rect: Rect, radius: f32 = 0, sigma: f32 = 0, tint: Color = Color.transparent },
    /// Push a clip region; subsequent draws are masked to the intersection of
    /// all clips on the stack until the matching `pop_clip`.
    push_clip: struct { rect: Rect, radius: f32 = 0 },
    pop_clip,
};

pub const Canvas = struct {
    commands: std.ArrayList(DrawCommand) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Canvas {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Canvas) void {
        self.commands.deinit(self.allocator);
    }
    pub fn clearCommands(self: *Canvas) void {
        self.commands.clearRetainingCapacity();
    }
    pub fn count(self: *const Canvas) usize {
        return self.commands.items.len;
    }

    pub fn push(self: *Canvas, cmd: DrawCommand) !void {
        try self.commands.append(self.allocator, cmd);
    }

    // -- convenience builders ----------------------------------------------

    pub fn fillRect(self: *Canvas, rect: Rect, color: Color) !void {
        try self.push(.{ .fill_rrect = .{ .rect = rect, .radius = 0, .color = color } });
    }
    pub fn fillRoundedRect(self: *Canvas, rect: Rect, radius: f32, color: Color) !void {
        try self.push(.{ .fill_rrect = .{ .rect = rect, .radius = radius, .color = color } });
    }
    pub fn strokeRoundedRect(self: *Canvas, rect: Rect, radius: f32, width: f32, color: Color) !void {
        try self.push(.{ .stroke_rrect = .{ .rect = rect, .radius = radius, .width = width, .color = color } });
    }
    pub fn fillCircle(self: *Canvas, center: Point, r: f32, color: Color) !void {
        try self.fillRoundedRect(
            .{ .x = center.x - r, .y = center.y - r, .width = 2 * r, .height = 2 * r },
            r,
            color,
        );
    }
    pub fn line(self: *Canvas, a: Point, b: Point, width: f32, color: Color) !void {
        try self.push(.{ .line = .{ .a = a, .b = b, .width = width, .color = color } });
    }
    pub fn drawGlyph(self: *Canvas, rect: Rect, color: Color, coverage: Coverage) !void {
        try self.push(.{ .glyph = .{ .rect = rect, .color = color, .coverage = coverage } });
    }
    /// Like `drawGlyph` but with an explicit coverage `gamma` (see the `glyph`
    /// command). The text path uses this to apply the active `setTextGamma`.
    pub fn drawGlyphGamma(self: *Canvas, rect: Rect, color: Color, coverage: Coverage, gamma: f32) !void {
        try self.push(.{ .glyph = .{ .rect = rect, .color = color, .coverage = coverage, .gamma = gamma } });
    }
    pub fn drawImage(self: *Canvas, rect: Rect, image: Image) !void {
        try self.push(.{ .image = .{ .rect = rect, .image = image } });
    }
    pub fn blurRect(self: *Canvas, rect: Rect, radius: f32, sigma: f32, tint: Color) !void {
        try self.push(.{ .blur_rect = .{ .rect = rect, .radius = radius, .sigma = sigma, .tint = tint } });
    }
    pub fn pushClip(self: *Canvas, rect: Rect, radius: f32) !void {
        try self.push(.{ .push_clip = .{ .rect = rect, .radius = radius } });
    }
    pub fn popClip(self: *Canvas) !void {
        try self.push(.pop_clip);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Canvas: records commands in order" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.fillRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, Color.red);
    try c.strokeRoundedRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 4, 2, Color.blue);
    try testing.expectEqual(@as(usize, 2), c.count());
    try testing.expect(c.commands.items[0] == .fill_rrect);
    try testing.expect(c.commands.items[1] == .stroke_rrect);
}

test "Canvas: clip push/pop and clear" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.pushClip(.{ .x = 0, .y = 0, .width = 5, .height = 5 }, 0);
    try c.popClip();
    try testing.expectEqual(@as(usize, 2), c.count());
    c.clearCommands();
    try testing.expectEqual(@as(usize, 0), c.count());
}

test "Canvas: fillCircle expands to a rounded rect" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.fillCircle(.{ .x = 50, .y = 50 }, 10, Color.green);
    const cmd = c.commands.items[0].fill_rrect;
    try testing.expectEqual(Rect{ .x = 40, .y = 40, .width = 20, .height = 20 }, cmd.rect);
    try testing.expectEqual(@as(f32, 10), cmd.radius);
}

test "Canvas: blurRect records a blur command" {
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.blurRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, 4, 6, Color.white.withAlpha(0.5));
    try testing.expect(c.commands.items[0] == .blur_rect);
    try testing.expectEqual(@as(f32, 6), c.commands.items[0].blur_rect.sigma);
}
