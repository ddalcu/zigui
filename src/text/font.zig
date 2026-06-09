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
    /// The bundled icon font (a Lucide subset). Its glyphs live in the Private
    /// Use Area; see `src/icons.zig`. The embedded blob is known-good.
    pub fn icons() Font {
        return .{ .face = ttf.Font.parse(ttf.icon_ttf) catch unreachable };
    }
    /// The bundled monochrome emoji font (Noto Emoji, OFL). Wire it as a
    /// fallback via `face.fallback` so codepoints the primary font lacks (emoji,
    /// etc.) render through the normal coverage path. The embedded blob is
    /// known-good.
    pub fn emoji() Font {
        return .{ .face = ttf.Font.parse(ttf.emoji_ttf) catch unreachable };
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
        const raster = try cache.getFace(pg.face, pg.glyph, pixel_size);
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
        const raster = try cache.getFace(pg.face, pg.glyph, device_px);
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

/// Draw a single icon glyph (`codepoint` in the icon font's PUA) centered in
/// `box`, sized to `box`'s smaller side, tinted `color`. Coverage is rasterized
/// at device resolution (`box side * scale`) but the quad is emitted in point
/// space, so the later ×`scale` in `view.renderScaled` lands it crisply — the
/// same HiDPI trick as `drawTextScaled`. No-op for a blank glyph.
pub fn drawIcon(
    canvas: *Canvas,
    cache: *atlas.GlyphCache,
    codepoint: u21,
    box: Rect,
    scale: f32,
    color: Color,
) !void {
    const face = cache.face;
    const side = @min(box.width, box.height);
    // Icon glyphs are designed on the em square, so rasterize the glyph at the
    // box side (em == side) and center the inked bitmap within the box.
    const raster = try cache.get(face.glyphIndex(codepoint), side * scale);
    if (raster.width == 0 or raster.height == 0) return; // blank / missing glyph
    const w = @as(f32, @floatFromInt(raster.width)) / scale;
    const h = @as(f32, @floatFromInt(raster.height)) / scale;
    const rect = Rect{
        .x = box.x + (box.width - w) / 2,
        .y = box.y + (box.height - h) / 2,
        .width = w,
        .height = h,
    };
    try canvas.drawGlyph(rect, color, .{
        .width = raster.width,
        .height = raster.height,
        .data = raster.data,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const raster_mod = @import("../render/raster.zig");

test "Font: icons parses and maps a known PUA codepoint to a glyph" {
    const font = Font.icons();
    // lucide `heart` lives at U+E0F2 in the bundled subset.
    try testing.expect(font.face.glyphIndex(0xE0F2) != 0);
}

test "drawIcon: inks pixels for a real icon and is a no-op for a blank slot" {
    const font = Font.icons();
    var cache = atlas.GlyphCache.init(testing.allocator, &font.face);
    defer cache.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const box = Rect{ .x = 0, .y = 0, .width = 24, .height = 24 };
    try drawIcon(&canvas, &cache, 0xE0F2, box, 1, Color.black); // heart
    try testing.expect(canvas.count() == 1);
    canvas.clearCommands();
    // A codepoint not in the subset maps to .notdef/blank → no command.
    try drawIcon(&canvas, &cache, 0x0041, box, 1, Color.black); // 'A'
    try testing.expect(canvas.count() == 0);
}

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

test "drawText: renders an emoji through the fallback face" {
    var font = Font.default();
    var emoji_font = Font.emoji();
    font.face.fallback = &emoji_font.face;
    var cache = atlas.GlyphCache.init(testing.allocator, &font.face);
    defer cache.deinit();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // "A😀" — one Latin glyph from Inter, one emoji from the fallback face.
    try drawText(&canvas, &cache, "A\u{1F600}", 48, Color.black, .{ .x = 0, .y = 0 });
    try testing.expectEqual(@as(usize, 2), canvas.count());

    var fb = try raster_mod.Framebuffer.init(testing.allocator, 128, 64);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster_mod.render(testing.allocator, &fb, canvas.commands.items);
    // The emoji must ink real pixels (right half of the canvas, past 'A').
    var dark: u32 = 0;
    for (0..fb.height) |yy| {
        for (64..fb.width) |xx| {
            if (fb.at(@intCast(xx), @intCast(yy)).luminance() < 0.5) dark += 1;
        }
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
