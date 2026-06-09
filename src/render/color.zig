//! Color: an RGBA color with f32 channels in the 0..1 range (straight/
//! non-premultiplied alpha), plus conversions and alpha compositing.

const std = @import("std");
const testing = std.testing;

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    // -- constructors -------------------------------------------------------

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1 };
    }
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    pub fn fromRgb8(r: u8, g: u8, b: u8) Color {
        return fromRgba8(r, g, b, 255);
    }
    pub fn fromRgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
    /// 0xRRGGBB, alpha = 1.
    pub fn hex(value: u24) Color {
        return fromRgb8(
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast(value & 0xFF),
        );
    }
    /// 0xRRGGBBAA.
    pub fn hexa(value: u32) Color {
        return fromRgba8(
            @intCast((value >> 24) & 0xFF),
            @intCast((value >> 16) & 0xFF),
            @intCast((value >> 8) & 0xFF),
            @intCast(value & 0xFF),
        );
    }
    /// Parse "#RGB", "#RRGGBB", or "#RRGGBBAA" (leading '#' optional).
    pub fn parse(s: []const u8) !Color {
        const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
        switch (h.len) {
            3 => {
                const r = try nibble(h[0]);
                const g = try nibble(h[1]);
                const b = try nibble(h[2]);
                return fromRgb8(r * 17, g * 17, b * 17); // 0xF -> 0xFF
            },
            6 => return hex(try std.fmt.parseInt(u24, h, 16)),
            8 => return hexa(try std.fmt.parseInt(u32, h, 16)),
            else => return error.InvalidColor,
        }
    }

    // -- conversions --------------------------------------------------------

    pub const Rgba8 = struct { r: u8, g: u8, b: u8, a: u8 };

    pub fn toRgba8(c: Color) Rgba8 {
        return .{
            .r = chan8(c.r),
            .g = chan8(c.g),
            .b = chan8(c.b),
            .a = chan8(c.a),
        };
    }

    // -- operations ---------------------------------------------------------

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }
    /// Multiply existing alpha by `factor` (for `.opacity()` modifiers).
    pub fn multiplyAlpha(c: Color, factor: f32) Color {
        return c.withAlpha(c.a * factor);
    }
    /// Lighten toward white by `amount` (0..1), preserving alpha. Used for the
    /// top sheen of "liquid glass" controls.
    pub fn lighten(c: Color, amount: f32) Color {
        return .{
            .r = c.r + (1 - c.r) * amount,
            .g = c.g + (1 - c.g) * amount,
            .b = c.b + (1 - c.b) * amount,
            .a = c.a,
        };
    }
    /// Darken toward black by `amount` (0..1), preserving alpha.
    pub fn darken(c: Color, amount: f32) Color {
        const k = 1 - amount;
        return .{ .r = c.r * k, .g = c.g * k, .b = c.b * k, .a = c.a };
    }
    /// Linear interpolation per channel; t in 0..1.
    pub fn lerp(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }
    /// Premultiplied-alpha form (rgb scaled by alpha).
    pub fn premultiplied(c: Color) Color {
        return .{ .r = c.r * c.a, .g = c.g * c.a, .b = c.b * c.a, .a = c.a };
    }
    /// Source-over compositing: `src` painted on top of `dst` (straight alpha).
    pub fn over(src: Color, dst: Color) Color {
        const out_a = src.a + dst.a * (1 - src.a);
        if (out_a <= 0) return transparent;
        const f = struct {
            fn ch(s: f32, sa: f32, d: f32, da: f32, oa: f32) f32 {
                return (s * sa + d * da * (1 - sa)) / oa;
            }
        }.ch;
        return .{
            .r = f(src.r, src.a, dst.r, dst.a, out_a),
            .g = f(src.g, src.a, dst.g, dst.a, out_a),
            .b = f(src.b, src.a, dst.b, dst.a, out_a),
            .a = out_a,
        };
    }
    /// Relative luminance (Rec. 709 weights) of the RGB, ignoring alpha.
    pub fn luminance(c: Color) f32 {
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    }
    pub fn isDark(c: Color) bool {
        return c.luminance() < 0.5;
    }
    pub fn approxEql(a: Color, b: Color, tol: f32) bool {
        return @abs(a.r - b.r) <= tol and @abs(a.g - b.g) <= tol and
            @abs(a.b - b.b) <= tol and @abs(a.a - b.a) <= tol;
    }

    // -- named colors -------------------------------------------------------

    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const red = Color{ .r = 1, .g = 0, .b = 0, .a = 1 };
    pub const green = Color{ .r = 0, .g = 1, .b = 0, .a = 1 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 1, .a = 1 };
};

fn chan8(v: f32) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidColor,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Color: rgba8 round trip" {
    const c = Color.fromRgba8(255, 128, 0, 255);
    const out = c.toRgba8();
    try testing.expectEqual(@as(u8, 255), out.r);
    try testing.expectEqual(@as(u8, 128), out.g);
    try testing.expectEqual(@as(u8, 0), out.b);
    try testing.expectEqual(@as(u8, 255), out.a);
}

test "Color: hex int constructors" {
    try testing.expect(Color.hex(0xFF8000).approxEql(Color.fromRgb8(255, 128, 0), 0.001));
    const c = Color.hexa(0x11223344);
    try testing.expect(c.approxEql(Color.fromRgba8(0x11, 0x22, 0x33, 0x44), 0.001));
}

test "Color: parse strings" {
    try testing.expect((try Color.parse("#FF8000")).approxEql(Color.fromRgb8(255, 128, 0), 0.001));
    try testing.expect((try Color.parse("FF8000")).approxEql(Color.fromRgb8(255, 128, 0), 0.001));
    try testing.expect((try Color.parse("#f00")).approxEql(Color.red, 0.001));
    try testing.expect((try Color.parse("#80808080")).approxEql(Color.fromRgba8(128, 128, 128, 128), 0.001));
    try testing.expectError(error.InvalidColor, Color.parse("#xyz"));
    try testing.expectError(error.InvalidColor, Color.parse("#12345"));
}

test "Color: withAlpha and multiplyAlpha" {
    const c = Color.red.withAlpha(0.5);
    try testing.expectEqual(@as(f32, 0.5), c.a);
    try testing.expectEqual(@as(f32, 0.25), c.multiplyAlpha(0.5).a);
}

test "Color: lerp midpoint" {
    const mid = Color.black.lerp(Color.white, 0.5);
    try testing.expect(mid.approxEql(Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 }, 0.001));
}

test "Color: over compositing opaque on opaque" {
    // Opaque src completely covers dst.
    const result = Color.red.over(Color.blue);
    try testing.expect(result.approxEql(Color.red, 0.001));
}

test "Color: over compositing transparent src keeps dst" {
    const result = Color.transparent.over(Color.blue);
    try testing.expect(result.approxEql(Color.blue, 0.001));
}

test "Color: over compositing half alpha blends" {
    // 50% white over opaque black -> mid grey, fully opaque.
    const result = Color.white.withAlpha(0.5).over(Color.black);
    try testing.expect(result.approxEql(Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1 }, 0.001));
}

test "Color: premultiplied" {
    const p = Color.white.withAlpha(0.5).premultiplied();
    try testing.expect(p.approxEql(Color{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.5 }, 0.001));
}

test "Color: luminance and isDark" {
    try testing.expect(Color.black.isDark());
    try testing.expect(!Color.white.isDark());
    try testing.expect(Color.white.luminance() > 0.99);
}

test "Color: chan8 clamps and rounds" {
    const over_white = Color{ .r = 2, .g = -1, .b = 0.5, .a = 1 };
    const o = over_white.toRgba8();
    try testing.expectEqual(@as(u8, 255), o.r);
    try testing.expectEqual(@as(u8, 0), o.g);
    try testing.expectEqual(@as(u8, 128), o.b);
}
