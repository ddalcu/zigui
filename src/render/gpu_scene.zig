//! GPU scene translation: turns a `Canvas` command list into the flat,
//! GPU-friendly form the SDL_GPU backend (`src/gpu.zig`, app layer) consumes —
//! a packed per-instance array (one `Instance` per draw command, rendered as an
//! instanced quad whose fragment shader evaluates the same rounded-box /
//! segment SDFs as `raster.zig`), a glyph/image texture atlas, and a `Step`
//! list that splits the instance stream wherever a `blur_rect` needs the
//! pixels rendered so far.
//!
//! This module is pure Zig with no GPU or C dependency, so the whole
//! translation layer (packing, clip resolution, padding, atlas growth) is
//! unit-tested headlessly; only the thin SDL_GPU shell remains build-verified.

const std = @import("std");
const geom = @import("../layout/geometry.zig");
const Color = @import("color.zig").Color;
const canvas_mod = @import("canvas.zig");

const Rect = geom.Rect;
const DrawCommand = canvas_mod.DrawCommand;
const Allocator = std.mem.Allocator;

/// Shader instance kinds; must match the `switch` in `prim.frag`/`prim.metal`.
pub const Kind = enum(u32) { fill = 0, stroke = 1, gradient = 2, glyph = 3, image = 4, line = 5 };

/// One instanced quad. Layout must match the vertex attributes declared by the
/// GPU backend's pipeline (nine float4 slots, instance step rate).
pub const Instance = extern struct {
    /// The quad actually rasterized: the shape's rect padded for anti-aliasing.
    pos: [4]f32, // x, y, w, h (device px)
    /// The shape rect the fragment SDF evaluates (unpadded).
    shape: [4]f32, // x, y, w, h
    color0: [4]f32, // fill / stroke / gradient-start / glyph tint (straight alpha)
    color1: [4]f32, // gradient end
    /// Gradient start/end points, or line endpoints (ax, ay, bx, by).
    ab: [4]f32,
    /// Normalized atlas UV rect (u0, v0, u1, v1) for glyph/image kinds.
    uv: [4]f32,
    /// Axis-aligned intersection of every clip rect on the stack.
    clip: [4]f32, // x, y, w, h
    /// The innermost *rounded* clip on the stack (rect; radius in params[3]).
    clip_rrect: [4]f32,
    /// kind, corner radius, half stroke/line width, rounded-clip radius.
    params: [4]f32,
};

/// The instance stream split into draw runs and blur breaks, in paint order.
pub const Step = union(enum) {
    /// Draw `count` instances starting at `first` (indices into `Scene.instances`).
    draw: struct { first: u32, count: u32 },
    /// Blur what has been rendered so far beneath `rect`, then composite `tint`
    /// masked by the (rounded) rect and the clip state captured at emit time.
    blur: struct {
        rect: [4]f32,
        radius: f32,
        sigma: f32,
        tint: [4]f32,
        clip: [4]f32,
        clip_rrect: [4]f32,
        clip_radius: f32,
    },
};

pub const Scene = struct {
    instances: []const Instance,
    steps: []const Step,
};

fn colorArr(c: Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}
fn rectArr(r: Rect) [4]f32 {
    return .{ r.x, r.y, r.width, r.height };
}

/// The clip state distilled to what one shader instance can evaluate: the
/// axis-aligned intersection of every clip rect, plus the innermost clip that
/// has a nonzero corner radius (evaluated as a rounded-box SDF). This matches
/// the software rasterizer exactly except when two *rounded* clips nest, where
/// only the inner radius is honored — a case the component layer never emits.
const ClipState = struct {
    rect: [4]f32,
    rrect: [4]f32,
    radius: f32,

    fn resolve(clips: []const Rect, radii: []const f32, fb_w: f32, fb_h: f32) ClipState {
        var x0: f32 = 0;
        var y0: f32 = 0;
        var x1: f32 = fb_w;
        var y1: f32 = fb_h;
        var rr: [4]f32 = .{ 0, 0, fb_w, fb_h };
        var radius: f32 = 0;
        for (clips, radii) |r, rad| {
            x0 = @max(x0, r.minX());
            y0 = @max(y0, r.minY());
            x1 = @min(x1, r.maxX());
            y1 = @min(y1, r.maxY());
            if (rad > 0) {
                rr = rectArr(r);
                radius = rad;
            }
        }
        return .{
            .rect = .{ x0, y0, @max(0, x1 - x0), @max(0, y1 - y0) },
            .rrect = rr,
            .radius = radius,
        };
    }
};

// ---------------------------------------------------------------------------
// Texture atlas (CPU-side state)
// ---------------------------------------------------------------------------

/// A pending region upload: RGBA8 pixels (arena-owned, valid for one frame)
/// destined for (x, y) in the atlas texture.
pub const Upload = struct { x: u32, y: u32, w: u32, h: u32, pixels: []const u8 };

/// Shelf-packed RGBA8 atlas bookkeeping. Glyph coverage bitmaps and images are
/// packed side by side; entries are keyed by their stable source pointer (the
/// `GlyphCache` owns glyph bitmaps for the app's lifetime, so a pointer key is
/// a content key). The GPU backend mirrors this state into a real texture by
/// applying `takePending` each frame.
pub const Atlas = struct {
    const Key = struct { ptr: usize, w: u32, h: u32 };
    const Entry = struct { x: u32, y: u32, w: u32, h: u32 };
    const Shelf = struct { y: u32, height: u32, x: u32 };

    /// 1px transparent border around every entry so linear/nearest sampling at
    /// the edge never bleeds a neighbour.
    const pad = 1;
    pub const max_size = 8192;

    size: u32,
    gpa: Allocator,
    shelves: std.ArrayList(Shelf) = .empty,
    map: std.AutoHashMapUnmanaged(Key, Entry) = .empty,
    pending: std.ArrayList(Upload) = .empty,
    /// Bumped every `reset`/`grow`; the GPU backend recreates its texture when
    /// the generation it last uploaded doesn't match.
    generation: u32 = 0,

    pub fn init(gpa: Allocator, size: u32) Atlas {
        return .{ .size = size, .gpa = gpa };
    }

    pub fn deinit(self: *Atlas) void {
        self.shelves.deinit(self.gpa);
        self.map.deinit(self.gpa);
        self.pending.deinit(self.gpa);
    }

    /// Drop every packed entry (the texture is stale) and double the size, up
    /// to `max_size`. Returns false when already at the maximum — the caller
    /// can still `reset()` to evict entries from earlier frames.
    pub fn grow(self: *Atlas) bool {
        if (self.size >= max_size) return false;
        self.size = @min(self.size * 2, max_size);
        self.reset();
        return true;
    }

    /// Evict everything (entries re-pack lazily as they are next referenced).
    pub fn reset(self: *Atlas) void {
        self.shelves.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        self.generation +%= 1;
    }

    /// The uploads staged since `clearPending`. Pixel slices are arena-owned;
    /// the GPU backend must consume them (then `clearPending`) within the frame.
    pub fn pendingUploads(self: *const Atlas) []const Upload {
        return self.pending.items;
    }
    pub fn clearPending(self: *Atlas) void {
        self.pending.clearRetainingCapacity();
    }

    fn pack(self: *Atlas, w: u32, h: u32) error{ OutOfMemory, AtlasFull }!Entry {
        const pw = w + 2 * pad;
        const ph = h + 2 * pad;
        if (pw > self.size or ph > self.size) return error.AtlasFull;
        for (self.shelves.items) |*shelf| {
            if (ph <= shelf.height and shelf.x + pw <= self.size) {
                const e = Entry{ .x = shelf.x + pad, .y = shelf.y + pad, .w = w, .h = h };
                shelf.x += pw;
                return e;
            }
        }
        const top = if (self.shelves.items.len > 0) blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height;
        } else 0;
        if (top + ph > self.size) return error.AtlasFull;
        try self.shelves.append(self.gpa, .{ .y = top, .height = ph, .x = pw });
        return .{ .x = pad, .y = top + pad, .w = w, .h = h };
    }

    /// Pack (or find) an entry keyed by `ptr`, staging `rgba` for upload on a
    /// miss. Returns the normalized UV rect.
    fn place(self: *Atlas, ptr: usize, w: u32, h: u32, rgba: []const u8) error{ OutOfMemory, AtlasFull }![4]f32 {
        const key = Key{ .ptr = ptr, .w = w, .h = h };
        const gop = try self.map.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.pack(w, h) catch |e| {
                _ = self.map.remove(key);
                return e;
            };
            try self.pending.append(self.gpa, .{
                .x = gop.value_ptr.x,
                .y = gop.value_ptr.y,
                .w = w,
                .h = h,
                .pixels = rgba,
            });
        }
        const fs: f32 = @floatFromInt(self.size);
        const e = gop.value_ptr.*;
        return .{
            @as(f32, @floatFromInt(e.x)) / fs,
            @as(f32, @floatFromInt(e.y)) / fs,
            @as(f32, @floatFromInt(e.x + e.w)) / fs,
            @as(f32, @floatFromInt(e.y + e.h)) / fs,
        };
    }
};

// ---------------------------------------------------------------------------
// Translation
// ---------------------------------------------------------------------------

/// Translate `commands` into a `Scene`. Instance/step storage is allocated in
/// `arena` (per-frame); atlas bookkeeping persists in the atlas's own
/// allocator. On `error.AtlasFull` the caller should `atlas.grow()` (or
/// `reset()`) and retry — entries staged so far were invalidated by the reset.
pub fn translate(
    arena: Allocator,
    commands: []const DrawCommand,
    atlas: *Atlas,
    fb_w: f32,
    fb_h: f32,
) error{ OutOfMemory, AtlasFull }!Scene {
    var instances: std.ArrayList(Instance) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var clip_rects: std.ArrayList(Rect) = .empty;
    var clip_radii: std.ArrayList(f32) = .empty;
    var run_start: u32 = 0;

    for (commands) |cmd| {
        switch (cmd) {
            .push_clip => |cl| {
                try clip_rects.append(arena, cl.rect);
                try clip_radii.append(arena, cl.radius);
            },
            .pop_clip => {
                if (clip_rects.items.len > 0) {
                    _ = clip_rects.pop();
                    _ = clip_radii.pop();
                }
            },
            .blur_rect => |bl| {
                const n: u32 = @intCast(instances.items.len);
                if (n > run_start) {
                    try steps.append(arena, .{ .draw = .{ .first = run_start, .count = n - run_start } });
                    run_start = n;
                }
                const clip = ClipState.resolve(clip_rects.items, clip_radii.items, fb_w, fb_h);
                try steps.append(arena, .{ .blur = .{
                    .rect = rectArr(bl.rect),
                    .radius = bl.radius,
                    .sigma = bl.sigma,
                    .tint = colorArr(bl.tint),
                    .clip = clip.rect,
                    .clip_rrect = clip.rrect,
                    .clip_radius = clip.radius,
                } });
            },
            else => {
                const clip = ClipState.resolve(clip_rects.items, clip_radii.items, fb_w, fb_h);
                var inst = Instance{
                    .pos = undefined,
                    .shape = .{ 0, 0, 0, 0 },
                    .color0 = .{ 0, 0, 0, 0 },
                    .color1 = .{ 0, 0, 0, 0 },
                    .ab = .{ 0, 0, 0, 0 },
                    .uv = .{ 0, 0, 0, 0 },
                    .clip = clip.rect,
                    .clip_rrect = clip.rrect,
                    .params = .{ 0, 0, 0, clip.radius },
                };
                switch (cmd) {
                    .fill_rrect => |f| {
                        inst.pos = paddedQuad(f.rect, 1);
                        inst.shape = rectArr(f.rect);
                        inst.color0 = colorArr(f.color);
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.fill));
                        inst.params[1] = f.radius;
                    },
                    .stroke_rrect => |s| {
                        inst.pos = paddedQuad(s.rect, s.width / 2 + 1);
                        inst.shape = rectArr(s.rect);
                        inst.color0 = colorArr(s.color);
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.stroke));
                        inst.params[1] = s.radius;
                        inst.params[2] = s.width / 2;
                    },
                    .linear_gradient => |g| {
                        inst.pos = paddedQuad(g.rect, 1);
                        inst.shape = rectArr(g.rect);
                        inst.color0 = colorArr(g.c0);
                        inst.color1 = colorArr(g.c1);
                        inst.ab = .{ g.start.x, g.start.y, g.end.x, g.end.y };
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.gradient));
                        inst.params[1] = g.radius;
                    },
                    .line => |l| {
                        const bb = Rect{
                            .x = @min(l.a.x, l.b.x),
                            .y = @min(l.a.y, l.b.y),
                            .width = @abs(l.b.x - l.a.x),
                            .height = @abs(l.b.y - l.a.y),
                        };
                        inst.pos = paddedQuad(bb, l.width / 2 + 1);
                        inst.color0 = colorArr(l.color);
                        inst.ab = .{ l.a.x, l.a.y, l.b.x, l.b.y };
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.line));
                        inst.params[2] = l.width / 2;
                    },
                    .glyph => |g| {
                        if (g.coverage.width == 0 or g.coverage.height == 0) continue;
                        inst.pos = rectArr(g.rect);
                        inst.color0 = colorArr(g.color);
                        inst.uv = try atlas.place(
                            @intFromPtr(g.coverage.data.ptr),
                            g.coverage.width,
                            g.coverage.height,
                            try coverageToRgba(arena, g.coverage),
                        );
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.glyph));
                    },
                    .image => |im| {
                        if (im.image.width == 0 or im.image.height == 0) continue;
                        inst.pos = rectArr(im.rect);
                        inst.uv = try atlas.place(
                            @intFromPtr(im.image.pixels.ptr),
                            im.image.width,
                            im.image.height,
                            im.image.pixels,
                        );
                        inst.params[0] = @floatFromInt(@intFromEnum(Kind.image));
                    },
                    else => unreachable,
                }
                try instances.append(arena, inst);
            },
        }
    }
    const n: u32 = @intCast(instances.items.len);
    if (n > run_start) {
        try steps.append(arena, .{ .draw = .{ .first = run_start, .count = n - run_start } });
    }
    return .{ .instances = instances.items, .steps = steps.items };
}

fn paddedQuad(r: Rect, pad: f32) [4]f32 {
    return .{ r.x - pad, r.y - pad, r.width + 2 * pad, r.height + 2 * pad };
}

/// Expand an 8-bit coverage mask to the RGBA8 the atlas stores: white with the
/// coverage in alpha, so the shader's `color0 * texel.a` reproduces the
/// software rasterizer's tinted-glyph blend.
fn coverageToRgba(arena: Allocator, cov: canvas_mod.Coverage) ![]const u8 {
    const out = try arena.alloc(u8, @as(usize, cov.width) * cov.height * 4);
    for (cov.data, 0..) |a, i| {
        out[i * 4 + 0] = 255;
        out[i * 4 + 1] = 255;
        out[i * 4 + 2] = 255;
        out[i * 4 + 3] = a;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testTranslate(arena: Allocator, commands: []const DrawCommand, atlas: *Atlas) !Scene {
    return translate(arena, commands, atlas, 800, 600);
}

test "gpu_scene: fill becomes one padded instance and one draw step" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const cmds = [_]DrawCommand{
        .{ .fill_rrect = .{ .rect = .{ .x = 10, .y = 20, .width = 30, .height = 40 }, .radius = 5, .color = Color.red } },
    };
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);

    try testing.expectEqual(@as(usize, 1), scene.instances.len);
    const i = scene.instances[0];
    try testing.expectEqual([4]f32{ 9, 19, 32, 42 }, i.pos); // padded by 1
    try testing.expectEqual([4]f32{ 10, 20, 30, 40 }, i.shape);
    try testing.expectEqual(@as(f32, @floatFromInt(@intFromEnum(Kind.fill))), i.params[0]);
    try testing.expectEqual(@as(f32, 5), i.params[1]);
    try testing.expectEqual(@as(usize, 1), scene.steps.len);
    try testing.expectEqual(@as(u32, 1), scene.steps[0].draw.count);
}

test "gpu_scene: stroke and line pad by half width + 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const cmds = [_]DrawCommand{
        .{ .stroke_rrect = .{ .rect = .{ .x = 10, .y = 10, .width = 20, .height = 20 }, .width = 4, .color = Color.black } },
        .{ .line = .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 10, .y = 10 }, .width = 2, .color = Color.black } },
    };
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);

    try testing.expectEqual([4]f32{ 7, 7, 26, 26 }, scene.instances[0].pos); // 4/2+1 = 3
    try testing.expectEqual(@as(f32, 2), scene.instances[0].params[2]); // half width
    try testing.expectEqual([4]f32{ -2, -2, 14, 14 }, scene.instances[1].pos); // 2/2+1 = 2
    try testing.expectEqual([4]f32{ 0, 0, 10, 10 }, scene.instances[1].ab);
}

test "gpu_scene: clip stack intersects rects and keeps innermost rounded clip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const cmds = [_]DrawCommand{
        .{ .push_clip = .{ .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .radius = 8 } },
        .{ .push_clip = .{ .rect = .{ .x = 50, .y = 50, .width = 100, .height = 100 } } },
        .{ .fill_rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .color = Color.red } },
        .pop_clip,
        .pop_clip,
        .{ .fill_rrect = .{ .rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 }, .color = Color.red } },
    };
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);

    const clipped = scene.instances[0];
    try testing.expectEqual([4]f32{ 50, 50, 50, 50 }, clipped.clip); // intersection
    try testing.expectEqual([4]f32{ 0, 0, 100, 100 }, clipped.clip_rrect);
    try testing.expectEqual(@as(f32, 8), clipped.params[3]);

    const unclipped = scene.instances[1];
    try testing.expectEqual([4]f32{ 0, 0, 800, 600 }, unclipped.clip); // full fb
    try testing.expectEqual(@as(f32, 0), unclipped.params[3]);
}

test "gpu_scene: glyphs pack into the atlas once and share UVs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const cov_data = [_]u8{ 255, 0, 0, 255 };
    const cov = canvas_mod.Coverage{ .width = 2, .height = 2, .data = &cov_data };
    const cmds = [_]DrawCommand{
        .{ .glyph = .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .color = Color.red, .coverage = cov } },
        .{ .glyph = .{ .rect = .{ .x = 5, .y = 5, .width = 2, .height = 2 }, .color = Color.blue, .coverage = cov } },
    };
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);

    try testing.expectEqual(scene.instances[0].uv, scene.instances[1].uv);
    const pend = atlas.pendingUploads();
    try testing.expectEqual(@as(usize, 1), pend.len); // same coverage -> one upload
    try testing.expectEqual(@as(u32, 2), pend[0].w);
    // coverage expanded to white RGBA with coverage alpha
    try testing.expectEqual(@as(u8, 255), pend[0].pixels[0]); // r
    try testing.expectEqual(@as(u8, 255), pend[0].pixels[3]); // a of first texel
    try testing.expectEqual(@as(u8, 0), pend[0].pixels[7]); // a of second texel
    atlas.clearPending();
    try testing.expectEqual(@as(usize, 0), atlas.pendingUploads().len); // drained
}

test "gpu_scene: blur splits the instance stream into steps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 64);
    defer atlas.deinit();

    const r = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const cmds = [_]DrawCommand{
        .{ .fill_rrect = .{ .rect = r, .color = Color.red } },
        .{ .blur_rect = .{ .rect = r, .sigma = 4, .tint = Color.white.withAlpha(0.5) } },
        .{ .fill_rrect = .{ .rect = r, .color = Color.blue } },
    };
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);

    try testing.expectEqual(@as(usize, 3), scene.steps.len);
    try testing.expectEqual(@as(u32, 1), scene.steps[0].draw.count);
    try testing.expectEqual(@as(f32, 4), scene.steps[1].blur.sigma);
    try testing.expectEqual(@as(u32, 1), scene.steps[2].draw.first);
    try testing.expectEqual(@as(u32, 1), scene.steps[2].draw.count);
}

test "gpu_scene: atlas reports full and recovers by growing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var atlas = Atlas.init(testing.allocator, 8);
    defer atlas.deinit();

    // An 8x8 mask + 1px pad cannot fit an 8x8 atlas.
    const data = [_]u8{255} ** 64;
    const cov = canvas_mod.Coverage{ .width = 8, .height = 8, .data = &data };
    const cmds = [_]DrawCommand{
        .{ .glyph = .{ .rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .color = Color.red, .coverage = cov } },
    };
    try testing.expectError(error.AtlasFull, testTranslate(arena_state.allocator(), &cmds, &atlas));

    const gen = atlas.generation;
    try testing.expect(atlas.grow());
    try testing.expectEqual(@as(u32, 16), atlas.size);
    try testing.expect(atlas.generation != gen);
    const scene = try testTranslate(arena_state.allocator(), &cmds, &atlas);
    try testing.expectEqual(@as(usize, 1), scene.instances.len);
}

test "gpu_scene: shelf packer separates entries with padding" {
    var atlas = Atlas.init(testing.allocator, 32);
    defer atlas.deinit();
    const px = [_]u8{0} ** (4 * 4 * 4);
    const a = try atlas.place(1, 4, 4, &px);
    const b = try atlas.place(2, 4, 4, &px);
    try testing.expect(a[0] != b[0] or a[1] != b[1]); // distinct slots
    // entries are 1px-padded: second entry starts at x = 1 + (4 + 2*1)
    const pend = atlas.pendingUploads();
    try testing.expectEqual(@as(u32, 1), pend[0].x);
    try testing.expectEqual(@as(u32, 7), pend[1].x);
}
