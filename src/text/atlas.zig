//! Glyph cache. Rasterizing a glyph outline is relatively expensive, so the
//! `GlyphCache` memoizes `RasterGlyph` coverage bitmaps keyed by (glyph index,
//! pixel size). The GPU backend will additionally pack these into a texture
//! atlas; for the software rasterizer and tests, the cached coverage bitmaps are
//! consumed directly. The cache owns the bitmaps and frees them on `deinit`.

const std = @import("std");
const ttf = @import("ttf.zig");
const Allocator = std.mem.Allocator;

pub const GlyphCache = struct {
    // Glyph indices are per-face, so the face is part of the key: one cache can
    // hold glyphs from the primary face and any fallback (emoji) faces.
    const Key = struct { face: usize, glyph: u16, size_milli: u32 };
    const Map = std.AutoHashMapUnmanaged(Key, ttf.RasterGlyph);

    /// Primary face — the default for `get` and what metrics callers read.
    face: *const ttf.Font,
    map: Map = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator, face: *const ttf.Font) GlyphCache {
        return .{ .face = face, .allocator = allocator };
    }

    pub fn deinit(self: *GlyphCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |g| g.deinit(self.allocator);
        self.map.deinit(self.allocator);
    }

    /// Get (rasterizing & caching on miss) the coverage bitmap for a glyph of
    /// the primary face at a pixel size. The returned pointer is valid until the
    /// cache is mutated for the same size class or deinited.
    pub fn get(self: *GlyphCache, glyph: u16, pixel_size: f32) !*const ttf.RasterGlyph {
        return self.getFace(self.face, glyph, pixel_size);
    }

    /// Like `get`, but for a glyph of an arbitrary `face` (e.g. a fallback emoji
    /// face returned by `ttf.Font.resolve`). Rasterizes at that face's own scale.
    pub fn getFace(self: *GlyphCache, face: *const ttf.Font, glyph: u16, pixel_size: f32) !*const ttf.RasterGlyph {
        const key = Key{
            .face = @intFromPtr(face),
            .glyph = glyph,
            .size_milli = @intFromFloat(@round(pixel_size * 1000)),
        };
        const gop = try self.map.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            const scale = face.scaleForPixelSize(pixel_size);
            gop.value_ptr.* = try face.rasterizeGlyph(self.allocator, glyph, scale);
        }
        return gop.value_ptr;
    }

    pub fn count(self: *const GlyphCache) usize {
        return self.map.count();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "GlyphCache: caches rasterized glyphs (one entry per glyph+size)" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    var cache = GlyphCache.init(testing.allocator, &face);
    defer cache.deinit();

    const a = face.glyphIndex('A');
    const g1 = try cache.get(a, 32);
    const g2 = try cache.get(a, 32); // cache hit -> same pointer
    try testing.expectEqual(g1, g2);
    try testing.expectEqual(@as(usize, 1), cache.count());

    _ = try cache.get(a, 48); // different size -> new entry
    _ = try cache.get(face.glyphIndex('B'), 32); // different glyph -> new entry
    try testing.expectEqual(@as(usize, 3), cache.count());

    try testing.expect(g1.width > 0 and g1.height > 0);
}
