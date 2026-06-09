//! Text shaping & layout: turn a UTF-8 string into positioned glyphs, measure
//! its width, and wrap it into lines. This is intentionally simple — left-to-
//! right, one glyph per codepoint, no kerning or complex-script shaping (those
//! are post-v1, see PRD §9). It is enough for crisp Latin UI text and is fully
//! testable against the bundled font.

const std = @import("std");
const ttf = @import("ttf.zig");
const Allocator = std.mem.Allocator;

pub const PositionedGlyph = struct {
    glyph: u16,
    /// Face the glyph belongs to (the primary face or one of its fallbacks).
    /// Glyph indices are per-face, so rasterize from this, not the line's face.
    face: *const ttf.Font,
    /// Pen x at the glyph's origin (before its left-side bearing), in pixels.
    x: f32,
    advance: f32,
};

/// Measure the advance width (pixels) of a single line of text. Each codepoint
/// is resolved through the face's fallback chain, using the resolving face's own
/// units-per-em scale (fonts differ), so fallback glyphs advance correctly.
pub fn measureLineWidth(face: *const ttf.Font, text: []const u8, pixel_size: f32) f32 {
    var width: f32 = 0;
    var it = codepoints(text);
    while (it.next()) |cp| {
        const r = face.resolve(cp);
        const scale = r.face.scaleForPixelSize(pixel_size);
        width += @as(f32, @floatFromInt(r.face.advanceWidth(r.glyph))) * scale;
    }
    return width;
}

/// The line height (pixels): ascent − descent + line gap, scaled.
pub fn lineHeight(face: *const ttf.Font, pixel_size: f32) f32 {
    const scale = face.scaleForPixelSize(pixel_size);
    const a: f32 = @floatFromInt(face.ascent);
    const d: f32 = @floatFromInt(face.descent);
    const lg: f32 = @floatFromInt(face.line_gap);
    return (a - d + lg) * scale;
}

/// Distance from the top of a line to the baseline (pixels).
pub fn ascentPixels(face: *const ttf.Font, pixel_size: f32) f32 {
    return @as(f32, @floatFromInt(face.ascent)) * face.scaleForPixelSize(pixel_size);
}

/// Lay out a single line into positioned glyphs starting at pen x = `start_x`.
/// Caller owns the returned slice.
pub fn layoutLine(allocator: Allocator, face: *const ttf.Font, text: []const u8, pixel_size: f32, start_x: f32) ![]PositionedGlyph {
    var out: std.ArrayList(PositionedGlyph) = .empty;
    errdefer out.deinit(allocator);
    var pen = start_x;
    var it = codepoints(text);
    while (it.next()) |cp| {
        const r = face.resolve(cp);
        const scale = r.face.scaleForPixelSize(pixel_size);
        const adv = @as(f32, @floatFromInt(r.face.advanceWidth(r.glyph))) * scale;
        try out.append(allocator, .{ .glyph = r.glyph, .face = r.face, .x = pen, .advance = adv });
        pen += adv;
    }
    return out.toOwnedSlice(allocator);
}

pub const WrappedLine = struct { start: usize, end: usize, width: f32 };

/// Greedy word-wrap of `text` to `max_width` pixels. Returns byte ranges into
/// `text` for each line. Words are split on ASCII spaces; a word wider than a
/// whole line on its own (a path, a URL) is broken at codepoint boundaries.
/// Caller owns the slice.
pub fn wrapText(allocator: Allocator, face: *const ttf.Font, text: []const u8, pixel_size: f32, max_width: f32) ![]WrappedLine {
    var lines: std.ArrayList(WrappedLine) = .empty;
    errdefer lines.deinit(allocator);

    var line_start: usize = 0;
    var line_end: usize = 0; // exclusive end of committed content on the line
    var i: usize = 0;
    while (i < text.len) {
        // find next word [word_start, word_end) and following whitespace end
        const word_start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n') : (i += 1) {}
        const word_end = i;
        // candidate line is [line_start, word_end)
        const candidate = text[line_start..word_end];
        const w = measureLineWidth(face, candidate, pixel_size);
        if (w > max_width and line_end > line_start) {
            // commit current line, start new one at this word
            try lines.append(allocator, .{
                .start = line_start,
                .end = line_end,
                .width = measureLineWidth(face, text[line_start..line_end], pixel_size),
            });
            line_start = word_start;
        }
        // An unbreakable word that overflows a whole line by itself: emit
        // codepoint-boundary chunks; the final chunk stays as the open line so
        // following words can join it.
        if (line_start == word_start and
            measureLineWidth(face, text[word_start..word_end], pixel_size) > max_width)
        {
            var it = codepoints(text[word_start..word_end]);
            var chunk_start = word_start;
            var chunk_w: f32 = 0;
            while (true) {
                const off = word_start + it.i;
                const cp = it.next() orelse break;
                const r = face.resolve(cp);
                const adv = @as(f32, @floatFromInt(r.face.advanceWidth(r.glyph))) * r.face.scaleForPixelSize(pixel_size);
                if (chunk_w + adv > max_width and off > chunk_start) {
                    try lines.append(allocator, .{ .start = chunk_start, .end = off, .width = chunk_w });
                    chunk_start = off;
                    chunk_w = adv;
                } else {
                    chunk_w += adv;
                }
            }
            line_start = chunk_start;
        }
        line_end = word_end;

        // handle explicit newline / spaces
        if (i < text.len and text[i] == '\n') {
            try lines.append(allocator, .{
                .start = line_start,
                .end = line_end,
                .width = measureLineWidth(face, text[line_start..line_end], pixel_size),
            });
            i += 1;
            line_start = i;
            line_end = i;
        } else {
            // skip spaces
            while (i < text.len and text[i] == ' ') : (i += 1) {}
        }
    }
    if (line_end > line_start or lines.items.len == 0) {
        try lines.append(allocator, .{
            .start = line_start,
            .end = line_end,
            .width = measureLineWidth(face, text[line_start..line_end], pixel_size),
        });
    }
    return lines.toOwnedSlice(allocator);
}

const CodepointIterator = struct {
    text: []const u8,
    i: usize = 0,
    fn next(self: *CodepointIterator) ?u21 {
        if (self.i >= self.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.text[self.i]) catch {
            self.i += 1;
            return 0xFFFD; // replacement char on invalid byte
        };
        if (self.i + len > self.text.len) {
            self.i = self.text.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.text[self.i .. self.i + len]) catch 0xFFFD;
        self.i += len;
        return cp;
    }
};

fn codepoints(text: []const u8) CodepointIterator {
    return .{ .text = text };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "shape: measureLineWidth grows with text length" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const w1 = measureLineWidth(&face, "i", 16);
    const w2 = measureLineWidth(&face, "iiii", 16);
    try testing.expect(w1 > 0);
    try testing.expect(w2 > w1 * 3); // ~4x one glyph
    try testing.expectEqual(@as(f32, 0), measureLineWidth(&face, "", 16));
}

test "shape: lineHeight and ascent are positive and ordered" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const lh = lineHeight(&face, 16);
    const asc = ascentPixels(&face, 16);
    try testing.expect(lh > 0);
    try testing.expect(asc > 0 and asc < lh);
}

test "shape: layoutLine positions glyphs left to right" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const glyphs = try layoutLine(testing.allocator, &face, "Hi", 16, 0);
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(@as(usize, 2), glyphs.len);
    try testing.expectEqual(@as(f32, 0), glyphs[0].x);
    try testing.expect(glyphs[1].x > 0); // second glyph advanced past the first
    try testing.expectApproxEqAbs(glyphs[0].advance, glyphs[1].x, 0.01);
}

test "shape: wrapText breaks on width and on newlines" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const max = measureLineWidth(&face, "hello hello", 16) - 1; // forces a break
    const lines = try wrapText(testing.allocator, &face, "hello hello hello", 16, max);
    defer testing.allocator.free(lines);
    try testing.expect(lines.len >= 2);

    const nl = try wrapText(testing.allocator, &face, "a\nb", 16, 10000);
    defer testing.allocator.free(nl);
    try testing.expectEqual(@as(usize, 2), nl.len);
}

test "shape: wrapText breaks an unbreakable over-long word mid-token" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    // A path-like token with no spaces, wrapped far narrower than its width.
    const token = "/Users/david/models/unsloth/FLUX.2-klein-4B-GGUF.safetensors";
    const max = measureLineWidth(&face, token, 16) / 3;
    const lines = try wrapText(testing.allocator, &face, token, 16, max);
    defer testing.allocator.free(lines);
    try testing.expect(lines.len >= 3);
    // every emitted line fits, and together they cover the whole token
    var covered: usize = 0;
    for (lines) |l| {
        try testing.expect(l.width <= max);
        covered += l.end - l.start;
    }
    try testing.expectEqual(token.len, covered);

    // a broken word's tail still shares its line with the following word
    const text = "/an/over/long/unbreakable/path then words";
    const max2 = measureLineWidth(&face, text, 16) / 2;
    const mixed = try wrapText(testing.allocator, &face, text, 16, max2);
    defer testing.allocator.free(mixed);
    for (mixed) |l| try testing.expect(l.width <= max2 + 0.01);
}

test "shape: invalid UTF-8 yields a measurable result (no crash)" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const bad = [_]u8{ 0xFF, 'A' };
    const w = measureLineWidth(&face, &bad, 16);
    try testing.expect(w > 0);
}
