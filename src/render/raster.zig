//! Pure-Zig software rasterizer. Consumes a `Canvas` command list and paints
//! into a `Framebuffer` of `Color` pixels. Shapes use a signed-distance field
//! for crisp 1px anti-aliasing, so rounded rects, circles, strokes, and lines
//! all share one coverage path. This backend exists so the entire visual layer
//! can be rendered and asserted on in tests and in headless/Docker/CI runs with
//! no GPU or window server.

const std = @import("std");
const geom = @import("../layout/geometry.zig");
const Color = @import("color.zig").Color;
const canvas_mod = @import("canvas.zig");

const Rect = geom.Rect;
const Point = geom.Point;
const DrawCommand = canvas_mod.DrawCommand;
const Allocator = std.mem.Allocator;

/// A CPU pixel buffer in straight-alpha `Color` (f32) for accurate compositing.
pub const Framebuffer = struct {
    width: u32,
    height: u32,
    pixels: []Color,
    allocator: Allocator,

    pub fn init(allocator: Allocator, width: u32, height: u32) !Framebuffer {
        const px = try allocator.alloc(Color, width * height);
        @memset(px, Color.transparent);
        return .{ .width = width, .height = height, .pixels = px, .allocator = allocator };
    }
    pub fn deinit(self: *Framebuffer) void {
        self.allocator.free(self.pixels);
    }
    pub fn clear(self: *Framebuffer, color: Color) void {
        @memset(self.pixels, color);
    }
    pub fn at(self: *const Framebuffer, x: u32, y: u32) Color {
        return self.pixels[y * self.width + x];
    }
    pub fn rgba8At(self: *const Framebuffer, x: u32, y: u32) Color.Rgba8 {
        return self.at(x, y).toRgba8();
    }
    fn blend(self: *Framebuffer, x: u32, y: u32, src: Color, coverage: f32) void {
        if (coverage <= 0) return;
        const i = y * self.width + x;
        const s = src.withAlpha(src.a * coverage);
        self.pixels[i] = s.over(self.pixels[i]);
    }

    /// Export to a tightly-packed RGBA8 buffer (caller owns the memory).
    pub fn toRgba8Alloc(self: *const Framebuffer, allocator: Allocator) ![]u8 {
        const out = try allocator.alloc(u8, self.width * self.height * 4);
        for (self.pixels, 0..) |c, i| {
            const p = c.toRgba8();
            out[i * 4 + 0] = p.r;
            out[i * 4 + 1] = p.g;
            out[i * 4 + 2] = p.b;
            out[i * 4 + 3] = p.a;
        }
        return out;
    }
};

const Clip = struct { rect: Rect, radius: f32 };

/// Render `commands` into `fb`. Uses `allocator` for the transient clip stack.
pub fn render(allocator: Allocator, fb: *Framebuffer, commands: []const DrawCommand) !void {
    var clips: std.ArrayList(Clip) = .empty;
    defer clips.deinit(allocator);

    for (commands) |cmd| {
        switch (cmd) {
            .push_clip => |c| try clips.append(allocator, .{ .rect = c.rect, .radius = c.radius }),
            .pop_clip => {
                if (clips.items.len > 0) _ = clips.pop();
            },
            .fill_rrect => |c| fillShape(fb, clips.items, c.rect, c.radius, .{ .solid = c.color }),
            .stroke_rrect => |c| strokeShape(fb, clips.items, c.rect, c.radius, c.width, c.color),
            .linear_gradient => |c| fillShape(fb, clips.items, c.rect, c.radius, .{ .gradient = .{
                .start = c.start,
                .end = c.end,
                .c0 = c.c0,
                .c1 = c.c1,
            } }),
            .line => |c| drawLine(fb, clips.items, c.a, c.b, c.width, c.color),
            .glyph => |c| drawGlyph(fb, clips.items, c.rect, c.color, c.coverage),
            .image => |c| drawImage(fb, clips.items, c.rect, c.image),
            .blur_rect => |c| try blurRect(allocator, fb, clips.items, c.rect, c.radius, c.sigma, c.tint),
        }
    }
}

/// Frosted "material" effect: separable box blur of the pixels already in `fb`
/// under `rect`, composited with `tint`, written back masked by the rect shape
/// and the clip stack. The blur reads from a scratch snapshot (never in place)
/// so neighbouring output pixels don't feed back into each other.
fn blurRect(
    allocator: Allocator,
    fb: *Framebuffer,
    clips: []const Clip,
    rect: Rect,
    radius: f32,
    sigma: f32,
    tint: Color,
) !void {
    const br: i64 = @intFromFloat(@max(1.0, @round(sigma)));
    const b = boundsOf(fb, rect, 0);
    if (b.x1 <= b.x0 or b.y1 <= b.y0) return;

    // Snapshot an expanded region (the output region grown by `br`, clamped to
    // the framebuffer) so every output pixel has a full ±br window to sample.
    const fbw: i64 = @intCast(fb.width);
    const fbh: i64 = @intCast(fb.height);
    const ex0: i64 = @max(0, @as(i64, b.x0) - br);
    const ey0: i64 = @max(0, @as(i64, b.y0) - br);
    const ex1: i64 = @min(fbw, @as(i64, b.x1) + br);
    const ey1: i64 = @min(fbh, @as(i64, b.y1) + br);
    const ew: usize = @intCast(ex1 - ex0);
    const eh: usize = @intCast(ey1 - ey0);

    const src = try allocator.alloc(Color, ew * eh);
    defer allocator.free(src);
    const tmp = try allocator.alloc(Color, ew * eh);
    defer allocator.free(tmp);

    var yy: usize = 0;
    while (yy < eh) : (yy += 1) {
        const fy: usize = @intCast(ey0 + @as(i64, @intCast(yy)));
        var xx: usize = 0;
        while (xx < ew) : (xx += 1) {
            const fx: usize = @intCast(ex0 + @as(i64, @intCast(xx)));
            src[yy * ew + xx] = fb.pixels[fy * fb.width + fx];
        }
    }

    // Horizontal box pass: src -> tmp.
    yy = 0;
    while (yy < eh) : (yy += 1) {
        var xx: usize = 0;
        while (xx < ew) : (xx += 1) {
            tmp[yy * ew + xx] = boxAverage(src, ew, eh, @intCast(xx), @intCast(yy), br, true);
        }
    }

    // Vertical box pass over tmp, then composite tint and write back masked.
    var py: u32 = b.y0;
    while (py < b.y1) : (py += 1) {
        const ly: i64 = @as(i64, py) - ey0;
        var px: u32 = b.x0;
        while (px < b.x1) : (px += 1) {
            const lx: i64 = @as(i64, px) - ex0;
            const blurred = boxAverage(tmp, ew, eh, lx, ly, br, false);
            const cx = @as(f32, @floatFromInt(px)) + 0.5;
            const cy = @as(f32, @floatFromInt(py)) + 0.5;
            const cov = fillCoverage(cx, cy, rect, radius) * clipCoverage(clips, cx, cy);
            if (cov <= 0) continue;
            const result = tint.over(blurred);
            const i = py * fb.width + px;
            fb.pixels[i] = fb.pixels[i].lerp(result, cov);
        }
    }
}

/// Average a `2*br+1` box of `buf` centred at (x,y), along the horizontal axis
/// when `horizontal` else the vertical axis, clamping the window to the region.
fn boxAverage(buf: []const Color, w: usize, h: usize, x: i64, y: i64, br: i64, horizontal: bool) Color {
    var r: f32 = 0;
    var g: f32 = 0;
    var bch: f32 = 0;
    var a: f32 = 0;
    var cnt: f32 = 0;
    var k: i64 = -br;
    while (k <= br) : (k += 1) {
        const sx = if (horizontal) x + k else x;
        const sy = if (horizontal) y else y + k;
        if (sx < 0 or sy < 0 or sx >= @as(i64, @intCast(w)) or sy >= @as(i64, @intCast(h))) continue;
        const p = buf[@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))];
        r += p.r;
        g += p.g;
        bch += p.b;
        a += p.a;
        cnt += 1;
    }
    if (cnt == 0) return Color.transparent;
    return .{ .r = r / cnt, .g = g / cnt, .b = bch / cnt, .a = a / cnt };
}

const Paint = union(enum) {
    solid: Color,
    gradient: struct { start: Point, end: Point, c0: Color, c1: Color },

    fn colorAt(self: Paint, px: f32, py: f32) Color {
        return switch (self) {
            .solid => |c| c,
            .gradient => |g| blk: {
                const dx = g.end.x - g.start.x;
                const dy = g.end.y - g.start.y;
                const len2 = dx * dx + dy * dy;
                if (len2 <= 0) break :blk g.c0;
                const t = ((px - g.start.x) * dx + (py - g.start.y) * dy) / len2;
                break :blk g.c0.lerp(g.c1, std.math.clamp(t, 0, 1));
            },
        };
    }
};

/// Signed distance from point (px,py) to a rounded box. Negative inside.
fn sdRoundBox(px: f32, py: f32, rect: Rect, radius: f32) f32 {
    const r = @min(radius, @min(rect.width, rect.height) / 2);
    const cx = rect.midX();
    const cy = rect.midY();
    const hx = rect.width / 2 - r;
    const hy = rect.height / 2 - r;
    const qx = @abs(px - cx) - hx;
    const qy = @abs(py - cy) - hy;
    const ax = @max(qx, 0);
    const ay = @max(qy, 0);
    const outside = @sqrt(ax * ax + ay * ay);
    const inside = @min(@max(qx, qy), 0);
    return outside + inside - r;
}

/// Coverage 0..1 of a filled rounded box at a pixel center, 1px anti-aliased.
fn fillCoverage(px: f32, py: f32, rect: Rect, radius: f32) f32 {
    return std.math.clamp(0.5 - sdRoundBox(px, py, rect, radius), 0, 1);
}

fn clipCoverage(clips: []const Clip, px: f32, py: f32) f32 {
    var cov: f32 = 1;
    for (clips) |c| {
        cov *= fillCoverage(px, py, c.rect, c.radius);
        if (cov <= 0) return 0;
    }
    return cov;
}

const PixelBounds = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

/// Integer pixel range covering `rect` (expanded by `pad` for AA), clamped to fb.
fn boundsOf(fb: *const Framebuffer, rect: Rect, pad: f32) PixelBounds {
    const x0 = std.math.clamp(@floor(rect.minX() - pad), 0, @as(f32, @floatFromInt(fb.width)));
    const y0 = std.math.clamp(@floor(rect.minY() - pad), 0, @as(f32, @floatFromInt(fb.height)));
    const x1 = std.math.clamp(@ceil(rect.maxX() + pad), 0, @as(f32, @floatFromInt(fb.width)));
    const y1 = std.math.clamp(@ceil(rect.maxY() + pad), 0, @as(f32, @floatFromInt(fb.height)));
    return .{
        .x0 = @intFromFloat(x0),
        .y0 = @intFromFloat(y0),
        .x1 = @intFromFloat(x1),
        .y1 = @intFromFloat(y1),
    };
}

fn fillShape(fb: *Framebuffer, clips: []const Clip, rect: Rect, radius: f32, paint: Paint) void {
    const b = boundsOf(fb, rect, 1);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const cov = fillCoverage(px, py, rect, radius) * clipCoverage(clips, px, py);
            if (cov > 0) fb.blend(x, y, paint.colorAt(px, py), cov);
        }
    }
}

fn strokeShape(fb: *Framebuffer, clips: []const Clip, rect: Rect, radius: f32, width: f32, color: Color) void {
    const half = width / 2;
    const b = boundsOf(fb, rect, half + 1);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = @abs(sdRoundBox(px, py, rect, radius)) - half;
            const cov = std.math.clamp(0.5 - d, 0, 1) * clipCoverage(clips, px, py);
            if (cov > 0) fb.blend(x, y, color, cov);
        }
    }
}

/// Distance from a point to a line segment.
fn sdSegment(px: f32, py: f32, a: Point, b: Point) f32 {
    const pax = px - a.x;
    const pay = py - a.y;
    const bax = b.x - a.x;
    const bay = b.y - a.y;
    const len2 = bax * bax + bay * bay;
    const h = if (len2 > 0) std.math.clamp((pax * bax + pay * bay) / len2, 0, 1) else 0;
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    return @sqrt(dx * dx + dy * dy);
}

fn drawLine(fb: *Framebuffer, clips: []const Clip, a: Point, b: Point, width: f32, color: Color) void {
    const half = width / 2;
    const minx = @min(a.x, b.x);
    const miny = @min(a.y, b.y);
    const rect = Rect{ .x = minx, .y = miny, .width = @abs(b.x - a.x), .height = @abs(b.y - a.y) };
    const bounds = boundsOf(fb, rect, half + 1);
    var y = bounds.y0;
    while (y < bounds.y1) : (y += 1) {
        var x = bounds.x0;
        while (x < bounds.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const d = sdSegment(px, py, a, b) - half;
            const cov = std.math.clamp(0.5 - d, 0, 1) * clipCoverage(clips, px, py);
            if (cov > 0) fb.blend(x, y, color, cov);
        }
    }
}

fn drawGlyph(fb: *Framebuffer, clips: []const Clip, rect: Rect, color: Color, cov: canvas_mod.Coverage) void {
    if (cov.width == 0 or cov.height == 0) return;
    const b = boundsOf(fb, rect, 0);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            // map pixel -> coverage texel (nearest)
            const u = (px - rect.x) / rect.width * @as(f32, @floatFromInt(cov.width));
            const v = (py - rect.y) / rect.height * @as(f32, @floatFromInt(cov.height));
            if (u < 0 or v < 0) continue;
            const ui: u32 = @intFromFloat(u);
            const vi: u32 = @intFromFloat(v);
            if (ui >= cov.width or vi >= cov.height) continue;
            const a = @as(f32, @floatFromInt(cov.data[vi * cov.width + ui])) / 255.0;
            const c = a * clipCoverage(clips, px, py);
            if (c > 0) fb.blend(x, y, color, c);
        }
    }
}

fn drawImage(fb: *Framebuffer, clips: []const Clip, rect: Rect, img: canvas_mod.Image) void {
    if (img.width == 0 or img.height == 0) return;
    const b = boundsOf(fb, rect, 0);
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const u = (px - rect.x) / rect.width * @as(f32, @floatFromInt(img.width));
            const v = (py - rect.y) / rect.height * @as(f32, @floatFromInt(img.height));
            if (u < 0 or v < 0) continue;
            const ui: u32 = @intFromFloat(u);
            const vi: u32 = @intFromFloat(v);
            if (ui >= img.width or vi >= img.height) continue;
            const idx = (vi * img.width + ui) * 4;
            const src = Color.fromRgba8(
                img.pixels[idx + 0],
                img.pixels[idx + 1],
                img.pixels[idx + 2],
                img.pixels[idx + 3],
            );
            fb.blend(x, y, src, clipCoverage(clips, px, py));
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Canvas = canvas_mod.Canvas;

fn renderCanvas(fb: *Framebuffer, c: *const Canvas) !void {
    try render(testing.allocator, fb, c.commands.items);
}

test "raster: fill rect paints interior, leaves outside untouched" {
    var fb = try Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.fillRect(.{ .x = 5, .y = 5, .width = 10, .height = 10 }, Color.red);
    try renderCanvas(&fb, &c);

    try testing.expect(fb.at(10, 10).approxEql(Color.red, 0.02)); // inside
    try testing.expect(fb.at(0, 0).approxEql(Color.white, 0.02)); // outside
}

test "raster: rounded rect clips its corners" {
    var fb = try Framebuffer.init(testing.allocator, 40, 40);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.fillRoundedRect(.{ .x = 0, .y = 0, .width = 40, .height = 40 }, 12, Color.red);
    try renderCanvas(&fb, &c);

    try testing.expect(fb.at(20, 20).approxEql(Color.red, 0.02)); // center filled
    // extreme corner is outside the rounded shape -> still background
    try testing.expect(fb.at(0, 0).approxEql(Color.white, 0.05));
}

test "raster: alpha compositing blends translucent over opaque" {
    var fb = try Framebuffer.init(testing.allocator, 10, 10);
    defer fb.deinit();
    fb.clear(Color.black);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.fillRect(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, Color.white.withAlpha(0.5));
    try renderCanvas(&fb, &c);
    try testing.expect(fb.at(5, 5).approxEql(Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 }, 0.02));
}

test "raster: clip masks drawing to the clip rect" {
    var fb = try Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.pushClip(.{ .x = 0, .y = 0, .width = 10, .height = 20 }, 0);
    try c.fillRect(.{ .x = 0, .y = 0, .width = 20, .height = 20 }, Color.red); // wider than clip
    try c.popClip();
    try renderCanvas(&fb, &c);

    try testing.expect(fb.at(5, 10).approxEql(Color.red, 0.02)); // inside clip
    try testing.expect(fb.at(15, 10).approxEql(Color.white, 0.02)); // clipped away
}

test "raster: linear gradient interpolates left-to-right" {
    var fb = try Framebuffer.init(testing.allocator, 100, 10);
    defer fb.deinit();
    fb.clear(Color.black);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.push(.{ .linear_gradient = .{
        .rect = .{ .x = 0, .y = 0, .width = 100, .height = 10 },
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = 100, .y = 0 },
        .c0 = Color.red,
        .c1 = Color.blue,
    } });
    try renderCanvas(&fb, &c);

    try testing.expect(fb.at(1, 5).r > 0.9); // left ~ red
    try testing.expect(fb.at(98, 5).b > 0.9); // right ~ blue
    const mid = fb.at(50, 5);
    try testing.expect(mid.r > 0.3 and mid.r < 0.7 and mid.b > 0.3 and mid.b < 0.7);
}

test "raster: stroke paints border but not center" {
    var fb = try Framebuffer.init(testing.allocator, 40, 40);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.strokeRoundedRect(.{ .x = 5, .y = 5, .width = 30, .height = 30 }, 0, 2, Color.black);
    try renderCanvas(&fb, &c);

    try testing.expect(fb.at(20, 20).approxEql(Color.white, 0.05)); // hollow center
    try testing.expect(fb.at(20, 5).isDark()); // top border drawn
}

test "raster: glyph coverage is tinted and blitted" {
    var fb = try Framebuffer.init(testing.allocator, 4, 4);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    // 2x2 coverage: top-left fully opaque, rest transparent
    const data = [_]u8{ 255, 0, 0, 0 };
    try c.drawGlyph(
        .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        Color.red,
        .{ .width = 2, .height = 2, .data = &data },
    );
    try renderCanvas(&fb, &c);
    try testing.expect(fb.at(0, 0).approxEql(Color.red, 0.02)); // covered texel
    try testing.expect(fb.at(1, 1).approxEql(Color.white, 0.02)); // uncovered
}

test "raster: image blit copies pixels" {
    var fb = try Framebuffer.init(testing.allocator, 2, 2);
    defer fb.deinit();
    fb.clear(Color.white);
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    // a single green opaque pixel image, stretched over the 2x2 fb
    const px = [_]u8{ 0, 255, 0, 255 };
    try c.drawImage(.{ .x = 0, .y = 0, .width = 2, .height = 2 }, .{ .width = 1, .height = 1, .pixels = &px });
    try renderCanvas(&fb, &c);
    try testing.expect(fb.at(0, 0).approxEql(Color.green, 0.02));
    try testing.expect(fb.at(1, 1).approxEql(Color.green, 0.02));
}

test "raster: blur_rect averages its region and leaves the outside untouched" {
    var fb = try Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    // high-contrast vertical stripes (even cols black, odd white)
    var y: usize = 0;
    while (y < 20) : (y += 1) {
        var x: usize = 0;
        while (x < 20) : (x += 1) {
            fb.pixels[y * 20 + x] = if (x % 2 == 0) Color.black else Color.white;
        }
    }
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.blurRect(.{ .x = 5, .y = 5, .width = 10, .height = 10 }, 0, 3, Color.transparent);
    try renderCanvas(&fb, &c);

    // inside the blurred region the stripes smear toward the mid grey mean
    const center = fb.at(10, 10);
    try testing.expect(center.r > 0.3 and center.r < 0.7);
    // outside the rect the stripes are pristine
    try testing.expect(fb.at(0, 0).approxEql(Color.black, 0.02));
    try testing.expect(fb.at(1, 0).approxEql(Color.white, 0.02));
}

test "raster: blur_rect tint shifts the region toward the tint color" {
    var fb = try Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    fb.clear(Color.fromRgb8(128, 128, 128)); // mid grey
    var c = Canvas.init(testing.allocator);
    defer c.deinit();
    try c.blurRect(.{ .x = 5, .y = 5, .width = 10, .height = 10 }, 0, 2, Color.white.withAlpha(0.5));
    try renderCanvas(&fb, &c);
    // tinted region is clearly lighter than the untouched grey background
    try testing.expect(fb.at(10, 10).luminance() > fb.at(0, 0).luminance() + 0.1);
    try testing.expect(fb.at(0, 0).approxEql(Color.fromRgb8(128, 128, 128), 0.02));
}

test "raster: toRgba8Alloc exports packed bytes" {
    var fb = try Framebuffer.init(testing.allocator, 2, 1);
    defer fb.deinit();
    fb.clear(Color.red);
    const bytes = try fb.toRgba8Alloc(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 8), bytes.len);
    try testing.expectEqual(@as(u8, 255), bytes[0]); // R
    try testing.expectEqual(@as(u8, 0), bytes[1]); // G
    try testing.expectEqual(@as(u8, 255), bytes[3]); // A
}
