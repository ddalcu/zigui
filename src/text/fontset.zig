//! The set of bundled faces (Inter weights + italic, JetBrains Mono) with one
//! glyph cache each. `Context.fonts` points at one; a view's weight/italic/mono
//! selects the cache every text measure and paint then uses.

const std = @import("std");
const ttf = @import("ttf.zig");
const atlas = @import("atlas.zig");
const theme = @import("../theme/theme.zig");

pub const Style = struct {
    weight: theme.FontWeight = .regular,
    italic: bool = false,
    mono: bool = false,
};

const Slot = enum { regular, medium, semibold, bold, italic, bold_italic, mono, mono_bold, emoji };
const slot_count = std.meta.fieldNames(Slot).len;

const blobs = [slot_count][]const u8{
    ttf.inter_ttf,
    @embedFile("inter_medium"),
    @embedFile("inter_semibold"),
    @embedFile("inter_bold"),
    @embedFile("inter_italic"),
    @embedFile("inter_bold_italic"),
    @embedFile("mono_regular"),
    @embedFile("mono_bold"),
    ttf.emoji_ttf,
};

fn slotFor(s: Style) Slot {
    const heavy = switch (s.weight) {
        .semibold, .bold, .heavy, .black => true,
        else => false,
    };
    if (s.mono) return if (heavy) .mono_bold else .mono;
    if (s.italic) return if (heavy) .bold_italic else .italic;
    return switch (s.weight) {
        .ultra_light, .thin, .light, .regular => .regular,
        .medium => .medium,
        .semibold => .semibold,
        .bold, .heavy, .black => .bold,
    };
}

pub const FontSet = struct {
    alloc: std.mem.Allocator,
    faces: [slot_count]ttf.Font,
    caches: [slot_count]atlas.GlyphCache,

    /// Heap-allocated so the face/cache pointers stay stable.
    pub fn create(alloc: std.mem.Allocator) !*FontSet {
        const self = try alloc.create(FontSet);
        self.alloc = alloc;
        for (blobs, 0..) |b, i| self.faces[i] = try ttf.Font.parse(b);
        // Text faces fall back to the emoji font for codepoints they lack.
        const emoji = &self.faces[@intFromEnum(Slot.emoji)];
        for (0..slot_count - 1) |i| self.faces[i].fallback = emoji;
        for (0..slot_count) |i| self.caches[i] = atlas.GlyphCache.init(alloc, &self.faces[i]);
        return self;
    }

    pub fn destroy(self: *FontSet) void {
        for (&self.caches) |*c| c.deinit();
        self.alloc.destroy(self);
    }

    /// Put `face` (e.g. a system CJK font) behind the emoji face, so every style
    /// reaches it for codepoints the bundled faces lack. It must outlive the set.
    pub fn setFallback(self: *FontSet, face: *const ttf.Font) void {
        self.faces[@intFromEnum(Slot.emoji)].fallback = face;
    }

    pub fn cache(self: *FontSet, s: Style) *atlas.GlyphCache {
        return &self.caches[@intFromEnum(slotFor(s))];
    }
};

test "fontset: every bundled face parses and resolves ASCII" {
    const fs = try FontSet.create(std.testing.allocator);
    defer fs.destroy();
    for (fs.faces[0 .. slot_count - 1]) |f| try std.testing.expect(f.glyphIndex('A') != 0);
}

test "fontset: an attached fallback face serves every style for codepoints the bundled faces lack" {
    const fs = try FontSet.create(std.testing.allocator);
    defer fs.destroy();
    const Fake = struct {
        fn glyph(_: *const anyopaque, cp: u21) u16 {
            return if (cp == 0x4E2D) 3 else 0;
        }
        fn adv(_: *const anyopaque, _: u16) u16 {
            return 1000;
        }
        fn raster(_: *const anyopaque, _: std.mem.Allocator, _: u16, _: f32) std.mem.Allocator.Error!ttf.RasterGlyph {
            return .{ .width = 0, .height = 0, .data = &.{}, .left = 0, .top = 0, .advance = 0 };
        }
        const ext = ttf.External{ .ctx = undefined, .glyph_index = glyph, .advance_width = adv, .rasterize = raster };
    };
    const cjk = ttf.Font.fromExternal(&Fake.ext, 1000, 880, -120, 0);
    fs.setFallback(&cjk);
    for ([_]Style{ .{}, .{ .weight = .bold }, .{ .italic = true }, .{ .mono = true } }) |s| {
        try std.testing.expect(fs.cache(s).face.resolve(0x4E2D).face == &cjk);
    }
}

test "fontset: style to slot mapping" {
    try std.testing.expectEqual(Slot.regular, slotFor(.{}));
    try std.testing.expectEqual(Slot.semibold, slotFor(.{ .weight = .semibold }));
    try std.testing.expectEqual(Slot.bold, slotFor(.{ .weight = .heavy }));
    try std.testing.expectEqual(Slot.italic, slotFor(.{ .italic = true }));
    try std.testing.expectEqual(Slot.bold_italic, slotFor(.{ .weight = .bold, .italic = true }));
    try std.testing.expectEqual(Slot.mono_bold, slotFor(.{ .weight = .bold, .mono = true }));
}
