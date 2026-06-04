//! High-level font façade. Wraps the low-level `ttf.Font` parser, the glyph
//! `GlyphCache`, and the `shape` helpers, and knows how to paint a string into a
//! `Canvas` as a sequence of tinted glyph-coverage quads. The default font is
//! the bundled Inter (OFL).

const std = @import("std");
const ttf = @import("ttf.zig");
const atlas = @import("atlas.zig");
const shape = @import("shape.zig");
const geom = @import("../layout/geometry.zig");
const Color = @import("../render/color.zig").Color;
const Canvas = @import("../render/canvas.zig").Canvas;
const Allocator = std.mem.Allocator;

const Size = geom.Size;
const Rect = geom.Rect;
const Point = geom.Point;

pub const Font = struct {
    face: ttf.Font,

    /// The bundled default font (Inter). The embedded blob is known-good.
    pub fn default() Font {
        return .{ .face = ttf.Font.parse(ttf.inter_ttf) catch unreachable };
    }
    pub fn fromBytes(bytes: []const u8) !Font {
        return .{ .face = try ttf.Font.parse(bytes) };
    }

    pub fn lineHeight(self: *const Font, pixel_size: f32) f32 {
        return shape.lineHeight(&self.face, pixel_size);
    }
    pub fn ascent(self: *const Font, pixel_size: f32) f32 {
        return shape.ascentPixels(&self.face, pixel_size);
    }

    /// Measure a single line: width = advance sum, height = one line height.
    pub fn measure(self: *const Font, text: []const u8, pixel_size: f32) Size {
        return .{
            .width = shape.measureLineWidth(&self.face, text, pixel_size),
            .height = self.lineHeight(pixel_size),
        };
    }
};

/// Paint `text` into `canvas` with its top-left at `origin`, at `pixel_size`,
/// tinted `color`, using `cache` for glyph bitmaps.
pub fn drawText(
    canvas: *Canvas,
    cache: *atlas.GlyphCache,
    text: []const u8,
    pixel_size: f32,
    color: Color,
    origin: Point,
) !void {
    const face = cache.face;
    const baseline = origin.y + shape.ascentPixels(face, pixel_size);
    const glyphs = try shape.layoutLine(canvas.allocator, face, text, pixel_size, origin.x);
    defer canvas.allocator.free(glyphs);
    for (glyphs) |pg| {
        const raster = try cache.get(pg.glyph, pixel_size);
        if (raster.width == 0 or raster.height == 0) continue; // whitespace
        const rect = Rect{
            .x = pg.x + @as(f32, @floatFromInt(raster.left)),
            .y = baseline - @as(f32, @floatFromInt(raster.top)),
            .width = @floatFromInt(raster.width),
            .height = @floatFromInt(raster.height),
        };
        try canvas.drawGlyph(rect, color, .{
            .width = raster.width,
            .height = raster.height,
            .data = raster.data,
        });
    }
}

/// Like `drawText`, but rasterizes glyph coverage at `pixel_size * scale`
/// (device resolution) while emitting the glyph quad in *point* space (sizes and
/// bearings divided by `scale`). A later uniform ×`scale` of the command list
/// then lands the quad on device pixels with a 1:1 coverage mapping — crisp
/// HiDPI text instead of a stretched low-res glyph. See `view.renderScaled`.
pub fn drawTextScaled(
    canvas: *Canvas,
    cache: *atlas.GlyphCache,
    text: []const u8,
    pixel_size: f32,
    scale: f32,
    color: Color,
    origin: Point,
) !void {
    const face = cache.face;
    const device_px = pixel_size * scale;
    const baseline = origin.y + shape.ascentPixels(face, pixel_size);
    const glyphs = try shape.layoutLine(canvas.allocator, face, text, pixel_size, origin.x);
    defer canvas.allocator.free(glyphs);
    for (glyphs) |pg| {
        const raster = try cache.get(pg.glyph, device_px);
        if (raster.width == 0 or raster.height == 0) continue; // whitespace
        const rect = Rect{
            .x = pg.x + @as(f32, @floatFromInt(raster.left)) / scale,
            .y = baseline - @as(f32, @floatFromInt(raster.top)) / scale,
            .width = @as(f32, @floatFromInt(raster.width)) / scale,
            .height = @as(f32, @floatFromInt(raster.height)) / scale,
        };
        try canvas.drawGlyph(rect, color, .{
            .width = raster.width,
            .height = raster.height,
            .data = raster.data,
        });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const raster_mod = @import("../render/raster.zig");

test "Font: default parses and measures text" {
    const font = Font.default();
    const size = font.measure("Hello", 16);
    try testing.expect(size.width > 0);
    try testing.expect(size.height > 0);
}

test "drawText: emits one glyph command per visible character" {
    const font = Font.default();
    var cache = atlas.GlyphCache.init(testing.allocator, &font.face);
    defer cache.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try drawText(&canvas, &cache, "AB", 32, Color.black, .{ .x = 0, .y = 0 });
    // two visible glyphs -> two glyph commands
    try testing.expectEqual(@as(usize, 2), canvas.count());
    try testing.expect(canvas.commands.items[0] == .glyph);
}

test "drawText: actually inks pixels when rasterized" {
    const font = Font.default();
    var cache = atlas.GlyphCache.init(testing.allocator, &font.face);
    defer cache.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try drawText(&canvas, &cache, "A", 48, Color.black, .{ .x = 2, .y = 2 });

    var fb = try raster_mod.Framebuffer.init(testing.allocator, 64, 64);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster_mod.render(testing.allocator, &fb, canvas.commands.items);

    // count dark pixels — the letter 'A' should ink a meaningful number
    var dark: u32 = 0;
    for (fb.pixels) |p| {
        if (p.luminance() < 0.5) dark += 1;
    }
    try testing.expect(dark > 20);
}

test "drawText: whitespace produces no glyph commands" {
    const font = Font.default();
    var cache = atlas.GlyphCache.init(testing.allocator, &font.face);
    defer cache.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try drawText(&canvas, &cache, "   ", 32, Color.black, .{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(usize, 0), canvas.count());
}
