//! Inline-styled, word-wrapped text: a paragraph made of spans that differ in
//! weight/italic/mono/colour/background/underline/link. Pure layout (no
//! Canvas/Context): `layout` places runs into lines; the view layer paints them.

const std = @import("std");
const ttf = @import("../text/ttf.zig");
const shape = @import("../text/shape.zig");
const fontset = @import("../text/fontset.zig");
const theme = @import("../theme/theme.zig");
const Color = @import("../render/color.zig").Color;

pub const Span = struct {
    text: []const u8,
    weight: ?theme.FontWeight = null,
    italic: bool = false,
    mono: bool = false,
    strike: bool = false,
    underline: bool = false,
    color: ?Color = null,
    /// Painted behind the run (inline code ground).
    bg: ?Color = null,
    /// Tappable target; also underlined.
    link: ?[]const u8 = null,
    /// Multiplies the paragraph's base size (inline code is a touch smaller).
    size_scale: f32 = 1,
};

pub const Run = struct {
    span: u32,
    start: u32,
    end: u32,
    x: f32,
    w: f32,
};

pub const Line = struct {
    runs: []Run,
    y: f32,
    h: f32,
    /// Baseline offset from the line's top.
    baseline: f32,
    w: f32,
};

pub const Layout = struct {
    lines: []Line = &.{},
    width: f32 = 0,
    height: f32 = 0,
};

/// Resolves a span to the face used to measure and draw it.
pub const Faces = struct {
    fonts: ?*fontset.FontSet = null,
    /// Used when `fonts` is null (tests) and as the base weight source.
    fallback: *const ttf.Font,
    base_weight: theme.FontWeight = .regular,

    pub fn forSpan(self: Faces, s: Span) *const ttf.Font {
        const fs = self.fonts orelse return self.fallback;
        const st = styleOf(self, s);
        return fs.cache(st).face;
    }

    pub fn cacheFor(self: Faces, s: Span) ?*@import("../text/atlas.zig").GlyphCache {
        const fs = self.fonts orelse return null;
        return fs.cache(styleOf(self, s));
    }

    fn styleOf(self: Faces, s: Span) fontset.Style {
        return .{ .weight = s.weight orelse self.base_weight, .italic = s.italic, .mono = s.mono };
    }
};

const Token = struct { start: usize, end: usize, space: bool };

fn nextToken(text: []const u8, i: usize) ?Token {
    if (i >= text.len) return null;
    if (text[i] == '\n') return .{ .start = i, .end = i + 1, .space = true };
    const space = text[i] == ' ' or text[i] == '\t';
    var j = i;
    while (j < text.len and text[j] != '\n' and (text[j] == ' ' or text[j] == '\t') == space) j += 1;
    return .{ .start = i, .end = j, .space = space };
}

/// Lay `spans` out in `max_w`. Memory comes from `arena`.
pub fn layout(
    arena: std.mem.Allocator,
    spans: []const Span,
    faces: Faces,
    base_px: f32,
    line_mult: f32,
    max_w_in: f32,
    /// Preformatted: leading spaces survive and lines never wrap (code).
    pre: bool,
) std.mem.Allocator.Error!Layout {
    const max_w: f32 = if (pre) 1.0e9 else max_w_in;
    var lines: std.ArrayList(Line) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    var x: f32 = 0;
    var y: f32 = 0;
    var max_asc: f32 = 0;
    var max_desc: f32 = 0;
    var line_start_run: usize = 0;
    var widest: f32 = 0;
    var line_has_content = false;

    for (spans, 0..) |sp, si| {
        const face = faces.forSpan(sp);
        const px = base_px * sp.size_scale;
        const asc = shape.ascentPixels(face, px);
        const lh = shape.lineHeight(face, px);
        var i: usize = 0;
        while (nextToken(sp.text, i)) |tok| {
            i = tok.end;
            const piece = sp.text[tok.start..tok.end];
            if (piece.len == 1 and piece[0] == '\n') {
                try finishLine(arena, &lines, &runs, &line_start_run, &y, &max_asc, &max_desc, &x, line_mult, lh, &widest);
                line_has_content = false;
                continue;
            }
            const w = shape.measureLineWidth(face, piece, px);
            if (tok.space) {
                if (!line_has_content and !pre) continue; // no leading spaces on a wrapped line
                if (x + w > max_w) {
                    // A space that would overflow ends the line instead of wrapping.
                    try finishLine(arena, &lines, &runs, &line_start_run, &y, &max_asc, &max_desc, &x, line_mult, lh, &widest);
                    line_has_content = false;
                    continue;
                }
            } else if (x + w > max_w and line_has_content) {
                try finishLine(arena, &lines, &runs, &line_start_run, &y, &max_asc, &max_desc, &x, line_mult, lh, &widest);
                line_has_content = false;
            }
            // A single word wider than the line breaks at codepoint boundaries.
            if (!tok.space and w > max_w) {
                var k: usize = tok.start;
                while (k < tok.end) {
                    var e = k;
                    var cw: f32 = 0;
                    while (e < tok.end) {
                        const n = std.unicode.utf8ByteSequenceLength(sp.text[e]) catch 1;
                        const nxt = @min(e + n, tok.end);
                        const gw = shape.measureLineWidth(face, sp.text[e..nxt], px);
                        if (cw + gw > max_w - x and e > k) break;
                        cw += gw;
                        e = nxt;
                    }
                    try appendRun(arena, &runs, line_start_run, @intCast(si), k, e, x, cw);
                    max_asc = @max(max_asc, asc);
                    max_desc = @max(max_desc, lh - asc);
                    x += cw;
                    line_has_content = true;
                    k = e;
                    if (k < tok.end) {
                        try finishLine(arena, &lines, &runs, &line_start_run, &y, &max_asc, &max_desc, &x, line_mult, lh, &widest);
                        line_has_content = false;
                    }
                }
                continue;
            }
            try appendRun(arena, &runs, line_start_run, @intCast(si), tok.start, tok.end, x, w);
            max_asc = @max(max_asc, asc);
            max_desc = @max(max_desc, lh - asc);
            x += w;
            if (!tok.space) line_has_content = true;
        }
    }
    if (runs.items.len > line_start_run or lines.items.len == 0) {
        const base_face = faces.fallback;
        try finishLine(arena, &lines, &runs, &line_start_run, &y, &max_asc, &max_desc, &x, line_mult, shape.lineHeight(base_face, base_px), &widest);
    }
    return .{ .lines = try lines.toOwnedSlice(arena), .width = widest, .height = y };
}

fn appendRun(arena: std.mem.Allocator, runs: *std.ArrayList(Run), line_start: usize, span: u32, start: usize, end: usize, x: f32, w: f32) !void {
    // Merge with the previous run on THIS line when it continues the same span.
    if (runs.items.len > line_start) {
        const last = &runs.items[runs.items.len - 1];
        if (last.span == span and last.end == start) {
            last.end = @intCast(end);
            last.w += w;
            return;
        }
    }
    try runs.append(arena, .{ .span = span, .start = @intCast(start), .end = @intCast(end), .x = x, .w = w });
}

fn finishLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    runs: *std.ArrayList(Run),
    line_start: *usize,
    y: *f32,
    asc: *f32,
    desc: *f32,
    x: *f32,
    mult: f32,
    fallback_h: f32,
    widest: *f32,
) !void {
    const content_h = asc.* + desc.*;
    const h = (if (content_h > 0) content_h else fallback_h) * mult;
    const owned = try arena.dupe(Run, runs.items[line_start.*..]);
    try lines.append(arena, .{
        .runs = owned,
        .y = y.*,
        .h = h,
        .baseline = (h - content_h) / 2 + asc.*,
        .w = x.*,
    });
    widest.* = @max(widest.*, x.*);
    y.* += h;
    asc.* = 0;
    desc.* = 0;
    x.* = 0;
    line_start.* = runs.items.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "richtext: one short span is one line" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const l = try layout(arena_s.allocator(), &.{.{ .text = "hello world" }}, faces, 14, 1.2, 500, false);
    try testing.expectEqual(@as(usize, 1), l.lines.len);
    try testing.expect(l.height > 14);
}

test "richtext: wraps at a space and drops the leading space" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const w = shape.measureLineWidth(&f, "hello wor", 14);
    const l = try layout(arena_s.allocator(), &.{.{ .text = "hello world again" }}, faces, 14, 1.0, w, false);
    try testing.expect(l.lines.len >= 2);
    const first = l.lines[1].runs[0];
    try testing.expect("hello world again"[first.start] != ' ');
}

test "richtext: explicit newline breaks a line" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const l = try layout(arena_s.allocator(), &.{.{ .text = "a\nb" }}, faces, 14, 1.0, 500, false);
    try testing.expectEqual(@as(usize, 2), l.lines.len);
}

test "richtext: a word wider than the line splits across lines" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const l = try layout(arena_s.allocator(), &.{.{ .text = "supercalifragilisticexpialidocious" }}, faces, 14, 1.0, 60, false);
    try testing.expect(l.lines.len >= 3);
    for (l.lines) |ln| try testing.expect(ln.w <= 60.5);
}

test "richtext: pre mode keeps leading spaces and never wraps" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const l = try layout(arena_s.allocator(), &.{.{ .text = "    return value_that_is_quite_long_indeed" }}, faces, 14, 1.0, 40, true);
    try testing.expectEqual(@as(usize, 1), l.lines.len);
    try testing.expectEqual(@as(u32, 0), l.lines[0].runs[0].start);
}

test "richtext: styled spans share a line and keep order" {
    var arena_s = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_s.deinit();
    const f = try ttf.Font.parse(ttf.inter_ttf);
    const faces = Faces{ .fallback = &f };
    const l = try layout(arena_s.allocator(), &.{
        .{ .text = "see " },
        .{ .text = "code", .mono = true },
        .{ .text = " here" },
    }, faces, 14, 1.0, 500, false);
    try testing.expectEqual(@as(usize, 1), l.lines.len);
    var prev: f32 = -1;
    for (l.lines[0].runs) |r| {
        try testing.expect(r.x >= prev);
        prev = r.x;
    }
    try testing.expectEqual(@as(u32, 1), l.lines[0].runs[1].span);
}
