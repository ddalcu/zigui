//! A pure-Zig TrueType (`glyf`-flavored) font parser and glyph rasterizer.
//!
//! Supports the subset zigui needs to render UI text: the offset/table
//! directory, `head`/`maxp`/`hhea`/`hmtx`, `cmap` (formats 4 and 12), `loca`,
//! and `glyf` (simple + composite glyphs). Outlines are flattened (quadratic
//! beziers) and rasterized to an 8-bit coverage bitmap with supersampled
//! anti-aliasing. No C dependencies — works identically on every platform and
//! in headless tests. Variable fonts parse fine: we read the default-master
//! outlines from `glyf` and ignore `gvar`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    InvalidFont,
    UnsupportedFormat,
    TableMissing,
};

/// Big-endian byte reader over the font blob.
const Be = struct {
    data: []const u8,
    fn u8at(self: Be, o: usize) u8 {
        return self.data[o];
    }
    fn rdU16(self: Be, o: usize) u16 {
        return std.mem.readInt(u16, self.data[o..][0..2], .big);
    }
    fn rdI16(self: Be, o: usize) i16 {
        return std.mem.readInt(i16, self.data[o..][0..2], .big);
    }
    fn rdU32(self: Be, o: usize) u32 {
        return std.mem.readInt(u32, self.data[o..][0..4], .big);
    }
};

pub const RasterGlyph = struct {
    width: u32,
    height: u32,
    /// Row-major 8-bit coverage (alpha). Empty for whitespace glyphs.
    data: []u8,
    /// Pixel offset of the bitmap's left edge from the pen origin.
    left: i32,
    /// Pixel offset of the bitmap's top edge above the baseline.
    top: i32,
    /// Horizontal advance in pixels.
    advance: f32,

    pub fn deinit(self: RasterGlyph, allocator: Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
    }
};

pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    long_loca: bool,
    loca_off: usize,
    glyf_off: usize,
    hmtx_off: usize,
    num_h_metrics: u16,
    cmap_sub_off: usize,
    cmap_format: u16,
    // vertical metrics (font units)
    ascent: i16,
    descent: i16,
    line_gap: i16,

    pub fn parse(data: []const u8) ParseError!Font {
        if (data.len < 12) return error.InvalidFont;
        const be = Be{ .data = data };
        const sfnt = be.rdU32(0);
        // 0x00010000 (TrueType) or 'true'. 'OTTO' (CFF) unsupported.
        if (sfnt != 0x00010000 and sfnt != 0x74727565) return error.UnsupportedFormat;
        const num_tables = be.rdU16(4);

        var head_off: usize = 0;
        var maxp_off: usize = 0;
        var hhea_off: usize = 0;
        var loca_off: usize = 0;
        var glyf_off: usize = 0;
        var hmtx_off: usize = 0;
        var cmap_off: usize = 0;

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + i * 16;
            if (rec + 16 > data.len) return error.InvalidFont;
            const tag = data[rec .. rec + 4];
            const off = be.rdU32(rec + 8);
            if (std.mem.eql(u8, tag, "head")) head_off = off;
            if (std.mem.eql(u8, tag, "maxp")) maxp_off = off;
            if (std.mem.eql(u8, tag, "hhea")) hhea_off = off;
            if (std.mem.eql(u8, tag, "loca")) loca_off = off;
            if (std.mem.eql(u8, tag, "glyf")) glyf_off = off;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx_off = off;
            if (std.mem.eql(u8, tag, "cmap")) cmap_off = off;
        }
        if (head_off == 0 or maxp_off == 0 or loca_off == 0 or glyf_off == 0 or
            hmtx_off == 0 or hhea_off == 0 or cmap_off == 0)
            return error.TableMissing;

        const units_per_em = be.rdU16(head_off + 18);
        const index_to_loc = be.rdI16(head_off + 50);
        const num_glyphs = be.rdU16(maxp_off + 4);
        const ascent = be.rdI16(hhea_off + 4);
        const descent = be.rdI16(hhea_off + 6);
        const line_gap = be.rdI16(hhea_off + 8);
        const num_h_metrics = be.rdU16(hhea_off + 34);

        const cmap = try findCmapSubtable(be, cmap_off);

        return .{
            .data = data,
            .units_per_em = units_per_em,
            .num_glyphs = num_glyphs,
            .long_loca = index_to_loc != 0,
            .loca_off = loca_off,
            .glyf_off = glyf_off,
            .hmtx_off = hmtx_off,
            .num_h_metrics = num_h_metrics,
            .cmap_sub_off = cmap.off,
            .cmap_format = cmap.format,
            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,
        };
    }

    const CmapSub = struct { off: usize, format: u16 };

    fn findCmapSubtable(be: Be, cmap_off: usize) ParseError!CmapSub {
        const n = be.rdU16(cmap_off + 2);
        var best: ?CmapSub = null;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = cmap_off + 4 + i * 8;
            const platform = be.rdU16(rec);
            const encoding = be.rdU16(rec + 2);
            const sub_off = cmap_off + be.rdU32(rec + 4);
            const format = be.rdU16(sub_off);
            const is_unicode = (platform == 0) or
                (platform == 3 and (encoding == 1 or encoding == 10));
            if (!is_unicode) continue;
            if (format == 12) return .{ .off = sub_off, .format = 12 }; // prefer full
            if (format == 4 and best == null) best = .{ .off = sub_off, .format = 4 };
        }
        return best orelse error.UnsupportedFormat;
    }

    /// Map a Unicode codepoint to a glyph index (0 = .notdef / missing).
    pub fn glyphIndex(self: Font, codepoint: u21) u16 {
        const be = Be{ .data = self.data };
        return switch (self.cmap_format) {
            4 => self.cmapFormat4(be, codepoint),
            12 => self.cmapFormat12(be, codepoint),
            else => 0,
        };
    }

    fn cmapFormat4(self: Font, be: Be, cp: u21) u16 {
        if (cp > 0xFFFF) return 0;
        const c: u16 = @intCast(cp);
        const base = self.cmap_sub_off;
        const seg_x2 = be.rdU16(base + 6);
        const seg_count = seg_x2 / 2;
        const end_codes = base + 14;
        const start_codes = end_codes + seg_x2 + 2; // +2 reservedPad
        const id_deltas = start_codes + seg_x2;
        const id_ranges = id_deltas + seg_x2;

        var i: usize = 0;
        while (i < seg_count) : (i += 1) {
            const end_code = be.rdU16(end_codes + i * 2);
            if (c <= end_code) {
                const start_code = be.rdU16(start_codes + i * 2);
                if (c < start_code) return 0;
                const id_delta = be.rdI16(id_deltas + i * 2);
                const id_range = be.rdU16(id_ranges + i * 2);
                if (id_range == 0) {
                    return @truncate(@as(u32, @intCast(@as(i32, c) + id_delta)));
                } else {
                    const gi_addr = id_ranges + i * 2 + id_range + (c - start_code) * 2;
                    const g = be.rdU16(gi_addr);
                    if (g == 0) return 0;
                    return @truncate(@as(u32, @intCast(@as(i32, g) + id_delta)));
                }
            }
        }
        return 0;
    }

    fn cmapFormat12(self: Font, be: Be, cp: u21) u16 {
        const base = self.cmap_sub_off;
        const n_groups = be.rdU32(base + 12);
        var i: usize = 0;
        while (i < n_groups) : (i += 1) {
            const g = base + 16 + i * 12;
            const start_char = be.rdU32(g);
            const end_char = be.rdU32(g + 4);
            const start_gid = be.rdU32(g + 8);
            if (cp >= start_char and cp <= end_char) {
                return @truncate(start_gid + (cp - start_char));
            }
        }
        return 0;
    }

    /// Horizontal advance for a glyph in font units.
    pub fn advanceWidth(self: Font, glyph: u16) u16 {
        const be = Be{ .data = self.data };
        const idx = if (glyph < self.num_h_metrics) glyph else self.num_h_metrics - 1;
        return be.rdU16(self.hmtx_off + idx * 4);
    }

    /// Em-units → pixels scale for a target em size in pixels.
    pub fn scaleForPixelSize(self: Font, pixel_size: f32) f32 {
        return pixel_size / @as(f32, @floatFromInt(self.units_per_em));
    }

    fn glyfRange(self: Font, glyph: u16) ?struct { start: usize, end: usize } {
        const be = Be{ .data = self.data };
        const start: usize, const end: usize = if (self.long_loca) .{
            be.rdU32(self.loca_off + glyph * 4),
            be.rdU32(self.loca_off + (glyph + 1) * 4),
        } else .{
            @as(usize, be.rdU16(self.loca_off + glyph * 2)) * 2,
            @as(usize, be.rdU16(self.loca_off + (glyph + 1) * 2)) * 2,
        };
        if (end <= start) return null; // empty glyph (e.g. space)
        return .{ .start = self.glyf_off + start, .end = self.glyf_off + end };
    }

    /// Rasterize a glyph to a coverage bitmap at `scale` (font units → pixels).
    pub fn rasterizeGlyph(self: Font, allocator: Allocator, glyph: u16, scale: f32) !RasterGlyph {
        const advance = @as(f32, @floatFromInt(self.advanceWidth(glyph))) * scale;

        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(allocator);
        try self.collectEdges(allocator, glyph, &edges, Transform.identity, 0);

        if (edges.items.len == 0) {
            return .{ .width = 0, .height = 0, .data = &.{}, .left = 0, .top = 0, .advance = advance };
        }

        // Bounds from the actual edges (font units).
        var min_x: f32 = std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (edges.items) |e| {
            min_x = @min(min_x, @min(e.x0, e.x1));
            min_y = @min(min_y, @min(e.y0, e.y1));
            max_x = @max(max_x, @max(e.x0, e.x1));
            max_y = @max(max_y, @max(e.y0, e.y1));
        }

        const ix0: i32 = @intFromFloat(@floor(min_x * scale));
        const iy0: i32 = @intFromFloat(@floor(min_y * scale));
        const ix1: i32 = @intFromFloat(@ceil(max_x * scale));
        const iy1: i32 = @intFromFloat(@ceil(max_y * scale));
        const w: u32 = @intCast(@max(ix1 - ix0, 1));
        const h: u32 = @intCast(@max(iy1 - iy0, 1));

        const bitmap = try allocator.alloc(u8, w * h);
        @memset(bitmap, 0);

        // Transform edges into bitmap pixel space (y flipped: font up → row down).
        const fx0: f32 = @floatFromInt(ix0);
        const fy1: f32 = @floatFromInt(iy1);
        for (edges.items) |*e| {
            e.x0 = e.x0 * scale - fx0;
            e.y0 = fy1 - e.y0 * scale;
            e.x1 = e.x1 * scale - fx0;
            e.y1 = fy1 - e.y1 * scale;
        }

        rasterize(bitmap, w, h, edges.items);

        return .{
            .width = w,
            .height = h,
            .data = bitmap,
            .left = ix0,
            .top = iy1,
            .advance = advance,
        };
    }

    fn collectEdges(self: Font, allocator: Allocator, glyph: u16, edges: *std.ArrayList(Edge), xf: Transform, depth: u8) Allocator.Error!void {
        if (depth > 5) return; // guard against pathological recursion
        const range = self.glyfRange(glyph) orelse return;
        const be = Be{ .data = self.data };
        const num_contours = be.rdI16(range.start);
        if (num_contours >= 0) {
            try self.simpleGlyphEdges(allocator, range.start, @intCast(num_contours), edges, xf);
        } else {
            try self.compositeGlyphEdges(allocator, range.start, edges, xf, depth);
        }
    }

    fn simpleGlyphEdges(self: Font, allocator: Allocator, g_start: usize, num_contours: u16, edges: *std.ArrayList(Edge), xf: Transform) Allocator.Error!void {
        const be = Be{ .data = self.data };
        var p = g_start + 10; // skip numContours(2) + bbox(8)
        const end_pts_off = p;
        const num_points: usize = if (num_contours == 0) 0 else be.rdU16(end_pts_off + (num_contours - 1) * 2) + 1;
        p += num_contours * 2;
        const instr_len = be.rdU16(p);
        p += 2 + instr_len;

        // Read flags (with repeat).
        var flags = try allocator.alloc(u8, num_points);
        defer allocator.free(flags);
        {
            var i: usize = 0;
            while (i < num_points) {
                const f = be.u8at(p);
                p += 1;
                flags[i] = f;
                i += 1;
                if (f & 0x08 != 0) { // REPEAT
                    var rep = be.u8at(p);
                    p += 1;
                    while (rep > 0 and i < num_points) : (rep -= 1) {
                        flags[i] = f;
                        i += 1;
                    }
                }
            }
        }

        // Read x coords (delta-encoded).
        const xs = try allocator.alloc(f32, num_points);
        defer allocator.free(xs);
        var x: i32 = 0;
        for (0..num_points) |i| {
            const f = flags[i];
            if (f & 0x02 != 0) { // X_SHORT
                const dx: i32 = be.u8at(p);
                p += 1;
                x += if (f & 0x10 != 0) dx else -dx;
            } else if (f & 0x10 == 0) { // not SAME -> i16 delta
                x += be.rdI16(p);
                p += 2;
            }
            xs[i] = @floatFromInt(x);
        }
        // Read y coords.
        const ys = try allocator.alloc(f32, num_points);
        defer allocator.free(ys);
        var y: i32 = 0;
        for (0..num_points) |i| {
            const f = flags[i];
            if (f & 0x04 != 0) { // Y_SHORT
                const dy: i32 = be.u8at(p);
                p += 1;
                y += if (f & 0x20 != 0) dy else -dy;
            } else if (f & 0x20 == 0) {
                y += be.rdI16(p);
                p += 2;
            }
            ys[i] = @floatFromInt(y);
        }

        // Emit edges per contour.
        var start: usize = 0;
        for (0..num_contours) |c| {
            const end = be.rdU16(end_pts_off + c * 2);
            const last: usize = end;
            try emitContour(allocator, edges, xs[start .. last + 1], ys[start .. last + 1], flags[start .. last + 1], xf);
            start = last + 1;
        }
    }

    fn compositeGlyphEdges(self: Font, allocator: Allocator, g_start: usize, edges: *std.ArrayList(Edge), xf: Transform, depth: u8) Allocator.Error!void {
        const be = Be{ .data = self.data };
        var p = g_start + 10;
        while (true) {
            const flags = be.rdU16(p);
            const comp_glyph = be.rdU16(p + 2);
            p += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
                if (flags & 0x0002 != 0) { // ARGS_ARE_XY_VALUES
                    dx = @floatFromInt(be.rdI16(p));
                    dy = @floatFromInt(be.rdI16(p + 2));
                }
                p += 4;
            } else {
                if (flags & 0x0002 != 0) {
                    dx = @floatFromInt(@as(i8, @bitCast(be.u8at(p))));
                    dy = @floatFromInt(@as(i8, @bitCast(be.u8at(p + 1))));
                }
                p += 2;
            }
            var a: f32 = 1;
            var b: f32 = 0;
            var cc: f32 = 0;
            var d: f32 = 1;
            if (flags & 0x0008 != 0) { // WE_HAVE_A_SCALE
                a = f2dot14(be.rdI16(p));
                d = a;
                p += 2;
            } else if (flags & 0x0040 != 0) { // X_AND_Y_SCALE
                a = f2dot14(be.rdI16(p));
                d = f2dot14(be.rdI16(p + 2));
                p += 4;
            } else if (flags & 0x0080 != 0) { // TWO_BY_TWO
                a = f2dot14(be.rdI16(p));
                b = f2dot14(be.rdI16(p + 2));
                cc = f2dot14(be.rdI16(p + 4));
                d = f2dot14(be.rdI16(p + 6));
                p += 8;
            }
            const comp_xf = xf.compose(.{ .a = a, .b = b, .c = cc, .d = d, .e = dx, .f = dy });
            try self.collectEdges(allocator, comp_glyph, edges, comp_xf, depth + 1);
            if (flags & 0x0020 == 0) break; // no MORE_COMPONENTS
        }
    }
};

fn f2dot14(v: i16) f32 {
    return @as(f32, @floatFromInt(v)) / 16384.0;
}

const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    const identity = Transform{};

    fn apply(t: Transform, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f };
    }
    /// self ∘ other  (apply other first, then self).
    fn compose(self: Transform, other: Transform) Transform {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .e = self.a * other.e + self.c * other.f + self.e,
            .f = self.b * other.e + self.d * other.f + self.f,
        };
    }
};

const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

fn emitContour(allocator: Allocator, edges: *std.ArrayList(Edge), xs: []const f32, ys: []const f32, flags: []const u8, xf: Transform) Allocator.Error!void {
    const n = xs.len;
    if (n == 0) return;

    const onCurve = struct {
        fn f(fl: u8) bool {
            return fl & 0x01 != 0;
        }
    }.f;

    var sx: f32 = undefined;
    var sy: f32 = undefined;
    var first_index: usize = undefined;
    if (onCurve(flags[0])) {
        sx = xs[0];
        sy = ys[0];
        first_index = 1;
    } else if (onCurve(flags[n - 1])) {
        sx = xs[n - 1];
        sy = ys[n - 1];
        first_index = 0;
    } else {
        sx = (xs[0] + xs[n - 1]) / 2;
        sy = (ys[0] + ys[n - 1]) / 2;
        first_index = 0;
    }

    var cur_x = sx;
    var cur_y = sy;
    var have_ctrl = false;
    var ctrl_x: f32 = 0;
    var ctrl_y: f32 = 0;

    var idx = first_index;
    while (idx < n) : (idx += 1) {
        if (onCurve(flags[idx])) {
            try lineOrQuad(allocator, edges, &cur_x, &cur_y, &have_ctrl, ctrl_x, ctrl_y, xs[idx], ys[idx], xf);
            have_ctrl = false;
        } else {
            if (have_ctrl) {
                const mx = (ctrl_x + xs[idx]) / 2;
                const my = (ctrl_y + ys[idx]) / 2;
                try lineOrQuad(allocator, edges, &cur_x, &cur_y, &have_ctrl, ctrl_x, ctrl_y, mx, my, xf);
            }
            have_ctrl = true;
            ctrl_x = xs[idx];
            ctrl_y = ys[idx];
        }
    }
    // close the contour back to the start point
    try lineOrQuad(allocator, edges, &cur_x, &cur_y, &have_ctrl, ctrl_x, ctrl_y, sx, sy, xf);
}

fn lineOrQuad(allocator: Allocator, edges: *std.ArrayList(Edge), cur_x: *f32, cur_y: *f32, have_ctrl: *bool, ctrl_x: f32, ctrl_y: f32, tx: f32, ty: f32, xf: Transform) Allocator.Error!void {
    if (have_ctrl.*) {
        // flatten quadratic from (cur) via (ctrl) to (tx,ty)
        const steps: usize = 8;
        var i: usize = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const mt = 1 - t;
            const px = mt * mt * cur_x.* + 2 * mt * t * ctrl_x + t * t * tx;
            const py = mt * mt * cur_y.* + 2 * mt * t * ctrl_y + t * t * ty;
            try pushEdge(allocator, edges, cur_x.*, cur_y.*, px, py, xf);
            cur_x.* = px;
            cur_y.* = py;
        }
        have_ctrl.* = false;
    } else {
        try pushEdge(allocator, edges, cur_x.*, cur_y.*, tx, ty, xf);
        cur_x.* = tx;
        cur_y.* = ty;
    }
}

fn pushEdge(allocator: Allocator, edges: *std.ArrayList(Edge), x0: f32, y0: f32, x1: f32, y1: f32, xf: Transform) Allocator.Error!void {
    const a = xf.apply(x0, y0);
    const b = xf.apply(x1, y1);
    try edges.append(allocator, .{ .x0 = a[0], .y0 = a[1], .x1 = b[0], .y1 = b[1] });
}

/// Scanline rasterizer with SSxSS supersampling and nonzero winding.
fn rasterize(bitmap: []u8, w: u32, h: u32, edges: []const Edge) void {
    const ss: u32 = 4;
    const ss_f: f32 = @floatFromInt(ss);
    const inv_samples: f32 = 1.0 / @as(f32, @floatFromInt(ss * ss));

    var py: u32 = 0;
    while (py < h) : (py += 1) {
        var px: u32 = 0;
        while (px < w) : (px += 1) {
            var inside_count: u32 = 0;
            var sy: u32 = 0;
            while (sy < ss) : (sy += 1) {
                const fy = @as(f32, @floatFromInt(py)) + (@as(f32, @floatFromInt(sy)) + 0.5) / ss_f;
                var sx: u32 = 0;
                while (sx < ss) : (sx += 1) {
                    const fx = @as(f32, @floatFromInt(px)) + (@as(f32, @floatFromInt(sx)) + 0.5) / ss_f;
                    if (windingInside(edges, fx, fy)) inside_count += 1;
                }
            }
            const cov = @as(f32, @floatFromInt(inside_count)) * inv_samples;
            bitmap[py * w + px] = @intFromFloat(@round(cov * 255.0));
        }
    }
}

fn windingInside(edges: []const Edge, sx: f32, sy: f32) bool {
    var winding: i32 = 0;
    for (edges) |e| {
        if (e.y0 <= sy and e.y1 > sy) {
            const t = (sy - e.y0) / (e.y1 - e.y0);
            const xint = e.x0 + t * (e.x1 - e.x0);
            if (xint > sx) winding += 1;
        } else if (e.y1 <= sy and e.y0 > sy) {
            const t = (sy - e.y0) / (e.y1 - e.y0);
            const xint = e.x0 + t * (e.x1 - e.x0);
            if (xint > sx) winding -= 1;
        }
    }
    return winding != 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
pub const inter_ttf = @embedFile("inter_font");

fn coverageSum(g: RasterGlyph) u64 {
    var s: u64 = 0;
    for (g.data) |v| s += v;
    return s;
}

test "ttf: parse Inter header" {
    const font = try Font.parse(inter_ttf);
    try testing.expect(font.units_per_em >= 1000);
    try testing.expect(font.num_glyphs > 100);
    try testing.expect(font.ascent > 0);
}

test "ttf: cmap maps ASCII letters to nonzero glyphs" {
    const font = try Font.parse(inter_ttf);
    try testing.expect(font.glyphIndex('A') != 0);
    try testing.expect(font.glyphIndex('g') != 0);
    try testing.expect(font.glyphIndex('0') != 0);
    // 'A' and 'B' map to distinct glyphs
    try testing.expect(font.glyphIndex('A') != font.glyphIndex('B'));
}

test "ttf: advance widths are positive and proportional" {
    const font = try Font.parse(inter_ttf);
    const a = font.advanceWidth(font.glyphIndex('i'));
    const m = font.advanceWidth(font.glyphIndex('M'));
    try testing.expect(a > 0 and m > 0);
    try testing.expect(m > a); // 'M' is wider than 'i'
}

test "ttf: rasterize 'A' produces a non-empty inked bitmap" {
    const font = try Font.parse(inter_ttf);
    const scale = font.scaleForPixelSize(48);
    const g = try font.rasterizeGlyph(testing.allocator, font.glyphIndex('A'), scale);
    defer g.deinit(testing.allocator);
    try testing.expect(g.width > 5 and g.height > 5);
    try testing.expect(coverageSum(g) > 0); // some pixels inked
    // 'A' top should be above the baseline
    try testing.expect(g.top > 0);
}

test "ttf: space glyph has zero ink but positive advance" {
    const font = try Font.parse(inter_ttf);
    const scale = font.scaleForPixelSize(48);
    const g = try font.rasterizeGlyph(testing.allocator, font.glyphIndex(' '), scale);
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), coverageSum(g));
    try testing.expect(g.advance > 0);
}

test "ttf: unmapped codepoint returns glyph 0" {
    const font = try Font.parse(inter_ttf);
    // a Plane-1 codepoint Inter almost certainly lacks
    try testing.expectEqual(@as(u16, 0), font.glyphIndex(0x10FFFF));
}

test "ttf: rejects non-TrueType data" {
    var junk = [_]u8{0} ** 16;
    junk[0] = 'O';
    junk[1] = 'T';
    junk[2] = 'T';
    junk[3] = 'O';
    try testing.expectError(error.UnsupportedFormat, Font.parse(&junk));
}
