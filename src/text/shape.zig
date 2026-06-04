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
    /// Pen x at the glyph's origin (before its left-side bearing), in pixels.
    x: f32,
    advance: f32,
};

/// Measure the advance width (pixels) of a single line of text.
pub fn measureLineWidth(face: *const ttf.Font, text: []const u8, pixel_size: f32) f32 {
    const scale = face.scaleForPixelSize(pixel_size);
    var width: f32 = 0;
    var it = codepoints(text);
    while (it.next()) |cp| {
        const g = face.glyphIndex(cp);
        width += @as(f32, @floatFromInt(face.advanceWidth(g))) * scale;
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
    const scale = face.scaleForPixelSize(pixel_size);
    var out: std.ArrayList(PositionedGlyph) = .empty;
    errdefer out.deinit(allocator);
    var pen = start_x;
    var it = codepoints(text);
    while (it.next()) |cp| {
        const g = face.glyphIndex(cp);
        const adv = @as(f32, @floatFromInt(face.advanceWidth(g))) * scale;
        try out.append(allocator, .{ .glyph = g, .x = pen, .advance = adv });
        pen += adv;
    }
    return out.toOwnedSlice(allocator);
}

pub const WrappedLine = struct { start: usize, end: usize, width: f32 };

/// Greedy word-wrap of `text` to `max_width` pixels. Returns byte ranges into
/// `text` for each line. Words are split on ASCII spaces; an over-long word is
/// placed on its own line (no mid-word breaking). Caller owns the slice.
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

test "shape: invalid UTF-8 yields a measurable result (no crash)" {
    var face = try ttf.Font.parse(ttf.inter_ttf);
    const bad = [_]u8{ 0xFF, 'A' };
    const w = measureLineWidth(&face, &bad, 16);
    try testing.expect(w > 0);
}
