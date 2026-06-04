//! Layout engine: a two-pass measure/arrange protocol over a tree of layout
//! `Node`s, mirroring SwiftUI's parent-proposes / child-responds model.
//!
//!   measure(node, proposal) -> Size      "given this proposed size, how big?"
//!   arrange(node, rect)      -> Frames    "you got this rect; place yourself"
//!
//! The `Node` union is the structural vocabulary (leaves, spacers, stacks,
//! padding, frames). The view layer maps real components onto these nodes; the
//! engine itself is pure and GPU-free so it is fully unit-testable.

const std = @import("std");
const geom = @import("geometry.zig");
const stack = @import("stack.zig");

const Allocator = std.mem.Allocator;

const Size = geom.Size;
const Rect = geom.Rect;
const Point = geom.Point;
const Alignment = geom.Alignment;
const Axis = geom.Axis;

/// A proposed size. A null dimension means "unspecified" — the child should
/// report its ideal size on that axis (SwiftUI's `nil` proposal).
pub const Proposal = struct {
    width: ?f32 = null,
    height: ?f32 = null,

    pub const unspecified = Proposal{};
    pub fn fixed(s: Size) Proposal {
        return .{ .width = s.width, .height = s.height };
    }
};

/// Intrinsic sizing of a content leaf along both axes.
pub const SizingHints = struct {
    min: Size = .{},
    ideal: Size = .{},
    max: Size = .{ .width = inf, .height = inf },

    /// A content box that always reports one fixed size.
    pub fn fixedSize(s: Size) SizingHints {
        return .{ .min = s, .ideal = s, .max = s };
    }
};

pub const Direction = enum { horizontal, vertical, depth };

pub const Stack = struct {
    direction: Direction,
    spacing: f32 = 0,
    alignment: Alignment = .center,
    children: []const Node,
};

pub const Padding = struct {
    insets: geom.EdgeInsets,
    child: *const Node,
};

/// A frame modifier: fixed dimensions and/or min/max bounds with an alignment
/// for placing the child inside the resulting box.
pub const Frame = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    alignment: Alignment = .center,
    child: *const Node,
};

pub const Spacer = struct {
    min_length: f32 = 0,
};

/// A leaf whose size depends on the proposed width (or height). `measureFn`
/// answers the measure protocol directly given the live proposal — the escape
/// hatch for content like wrapped text whose height is only known once the width
/// is proposed, which the static `SizingHints` cannot express. `ctx` is an opaque
/// pointer to caller-owned measurement state (e.g. font + string).
pub const Measured = struct {
    ctx: *const anyopaque,
    measureFn: *const fn (*const anyopaque, Proposal) Size,
};

/// A node in the layout tree.
pub const Node = union(enum) {
    leaf: SizingHints,
    spacer: Spacer,
    measured: Measured,
    stack: Stack,
    padding: Padding,
    frame: Frame,
};

pub const inf = std.math.inf(f32);
const big: f32 = 1_000_000;

// ---------------------------------------------------------------------------
// Measure pass
// ---------------------------------------------------------------------------

pub fn measure(node: Node, prop: Proposal) Size {
    return switch (node) {
        .leaf => |h| .{
            .width = resolveAxis(prop.width, h.min.width, h.ideal.width, h.max.width),
            .height = resolveAxis(prop.height, h.min.height, h.ideal.height, h.max.height),
        },
        // A bare spacer outside a stack has no intrinsic size.
        .spacer => Size{},
        .measured => |m| m.measureFn(m.ctx, prop),
        .padding => |p| blk: {
            const child_size = measure(p.child.*, .{
                .width = subOpt(prop.width, p.insets.horizontal()),
                .height = subOpt(prop.height, p.insets.vertical()),
            });
            break :blk .{
                .width = child_size.width + p.insets.horizontal(),
                .height = child_size.height + p.insets.vertical(),
            };
        },
        .frame => |f| measureFrame(f, prop),
        .stack => |s| measureStack(s, prop),
    };
}

fn measureFrame(f: Frame, prop: Proposal) Size {
    const child_prop = Proposal{
        .width = frameChildProposal(f.width, f.max_width, prop.width),
        .height = frameChildProposal(f.height, f.max_height, prop.height),
    };
    const cs = measure(f.child.*, child_prop);
    return .{
        .width = frameAxisSize(f.width, f.min_width, f.max_width, prop.width, cs.width),
        .height = frameAxisSize(f.height, f.min_height, f.max_height, prop.height, cs.height),
    };
}

fn frameChildProposal(fixed: ?f32, max: ?f32, proposed: ?f32) ?f32 {
    if (fixed) |v| return v;
    if (max) |m| {
        if (m == inf) return proposed; // fill available
        return if (proposed) |p| @min(p, m) else m;
    }
    return proposed;
}

fn frameAxisSize(fixed: ?f32, min: ?f32, max: ?f32, proposed: ?f32, child: f32) f32 {
    if (fixed) |v| return v;
    var size = child;
    if (max) |m| {
        const upper = if (m == inf) (proposed orelse child) else m;
        size = @min(@max(size, if (m == inf) (proposed orelse child) else size), upper);
        if (m == inf) size = proposed orelse child;
    }
    if (min) |lo| size = @max(size, lo);
    return size;
}

fn measureStack(s: Stack, prop: Proposal) Size {
    if (s.children.len == 0) return .{};
    if (s.direction == .depth) return measureZStack(s, prop);

    const axis: Axis = if (s.direction == .horizontal) .horizontal else .vertical;
    const main_prop = mainOf(axis, prop);
    const cross_prop = crossOf(axis, prop);

    var sizes_buf: [256]Size = undefined;
    const sizes = sizes_buf[0..s.children.len];
    layoutStackChildren(s, axis, main_prop, cross_prop, sizes);

    var total_main: f32 = 0;
    var max_cross: f32 = 0;
    for (sizes) |cs| {
        total_main += mainAxis(axis, cs);
        max_cross = @max(max_cross, crossAxis(axis, cs));
    }
    total_main += s.spacing * @as(f32, @floatFromInt(s.children.len - 1));
    return sizeFrom(axis, total_main, max_cross);
}

fn measureZStack(s: Stack, prop: Proposal) Size {
    var w: f32 = 0;
    var h: f32 = 0;
    for (s.children) |child| {
        const cs = measure(child, prop);
        w = @max(w, cs.width);
        h = @max(h, cs.height);
    }
    return .{ .width = w, .height = h };
}

/// Resolve each child's size given the stack's main/cross proposals, writing
/// results into `sizes`. Shared by measure and arrange so both agree.
fn layoutStackChildren(s: Stack, axis: Axis, main_prop: ?f32, cross_prop: ?f32, sizes: []Size) void {
    const n = s.children.len;
    if (main_prop) |avail| {
        // Bounded main axis: distribute space.
        var items_buf: [256]stack.FlexItem = undefined;
        const items = items_buf[0..n];
        for (s.children, 0..) |child, i| {
            items[i] = .{
                .min = childMain(child, axis, 0, cross_prop),
                .max = childMain(child, axis, big, cross_prop),
            };
        }
        var mains_buf: [256]f32 = undefined;
        const mains = mains_buf[0..n];
        stack.distribute(avail, s.spacing, items, mains);
        for (s.children, 0..) |child, i| {
            const cs = measureInStack(child, axis, mains[i], cross_prop);
            sizes[i] = cs;
        }
    } else {
        // Unbounded main axis: each child takes its ideal main size.
        for (s.children, 0..) |child, i| {
            sizes[i] = measureInStack(child, axis, null, cross_prop);
        }
    }
}

/// Measure one child within a stack, where a Spacer is oriented along the main
/// axis.
fn measureInStack(child: Node, axis: Axis, main: ?f32, cross: ?f32) Size {
    switch (child) {
        .spacer => |sp| {
            const m = if (main) |v| @max(v, sp.min_length) else sp.min_length;
            return sizeFrom(axis, m, 0);
        },
        else => return measure(child, propFrom(axis, main, cross)),
    }
}

fn childMain(child: Node, axis: Axis, main: ?f32, cross: ?f32) f32 {
    return mainAxis(axis, measureInStack(child, axis, main, cross));
}

// ---------------------------------------------------------------------------
// Arrange pass
// ---------------------------------------------------------------------------

/// The placement result for a node: its frame plus the placed children.
pub const LayoutResult = struct {
    frame: Rect,
    children: []LayoutResult = &.{},

    pub fn deinit(self: LayoutResult, allocator: std.mem.Allocator) void {
        for (self.children) |c| c.deinit(allocator);
        if (self.children.len > 0) allocator.free(self.children);
    }
};

pub fn arrange(allocator: std.mem.Allocator, node: Node, rect: Rect) Allocator.Error!LayoutResult {
    switch (node) {
        // Leaf-like nodes simply take the rect they are given.
        .leaf, .spacer, .measured => return .{ .frame = rect },
        .padding => |p| {
            const inner = rect.inset(p.insets);
            const child = try allocator.alloc(LayoutResult, 1);
            child[0] = try arrange(allocator, p.child.*, inner);
            return .{ .frame = rect, .children = child };
        },
        .frame => |f| {
            const child_prop = Proposal{
                .width = frameChildProposal(f.width, f.max_width, rect.width),
                .height = frameChildProposal(f.height, f.max_height, rect.height),
            };
            const cs = measure(f.child.*, child_prop);
            const pos = f.alignment.position(rect.size(), cs);
            const child_rect = Rect.fromOriginSize(
                .{ .x = rect.x + pos.x, .y = rect.y + pos.y },
                cs,
            );
            const child = try allocator.alloc(LayoutResult, 1);
            child[0] = try arrange(allocator, f.child.*, child_rect);
            return .{ .frame = rect, .children = child };
        },
        .stack => |s| return arrangeStack(allocator, s, rect),
    }
}

fn arrangeStack(allocator: std.mem.Allocator, s: Stack, rect: Rect) Allocator.Error!LayoutResult {
    if (s.children.len == 0) return .{ .frame = rect };
    if (s.direction == .depth) return arrangeZStack(allocator, s, rect);

    const axis: Axis = if (s.direction == .horizontal) .horizontal else .vertical;
    const cross_extent = crossAxis(axis, rect.size());

    var sizes_buf: [256]Size = undefined;
    const sizes = sizes_buf[0..s.children.len];
    layoutStackChildren(s, axis, mainAxis(axis, rect.size()), cross_extent, sizes);

    const results = try allocator.alloc(LayoutResult, s.children.len);
    errdefer allocator.free(results);

    const cross_frac = crossAlignFraction(axis, s.alignment);
    var cursor: f32 = mainOf2(axis, rect.origin());
    for (s.children, 0..) |child, i| {
        const cs = sizes[i];
        const child_cross = crossAxis(axis, cs);
        const cross_pos = crossOf2(axis, rect.origin()) + (cross_extent - child_cross) * cross_frac;
        const child_rect = rectFrom(axis, cursor, cross_pos, mainAxis(axis, cs), child_cross);
        results[i] = try arrange(allocator, child, child_rect);
        cursor += mainAxis(axis, cs) + s.spacing;
    }
    return .{ .frame = rect, .children = results };
}

fn arrangeZStack(allocator: std.mem.Allocator, s: Stack, rect: Rect) Allocator.Error!LayoutResult {
    const results = try allocator.alloc(LayoutResult, s.children.len);
    errdefer allocator.free(results);
    for (s.children, 0..) |child, i| {
        const cs = measure(child, Proposal.fixed(rect.size()));
        const pos = s.alignment.position(rect.size(), cs);
        const child_rect = Rect.fromOriginSize(
            .{ .x = rect.x + pos.x, .y = rect.y + pos.y },
            cs,
        );
        results[i] = try arrange(allocator, child, child_rect);
    }
    return .{ .frame = rect, .children = results };
}

// ---------------------------------------------------------------------------
// Axis helpers
// ---------------------------------------------------------------------------

fn resolveAxis(proposed: ?f32, min: f32, ideal: f32, max: f32) f32 {
    if (proposed) |p| return std.math.clamp(p, min, max);
    return ideal;
}

fn subOpt(a: ?f32, b: f32) ?f32 {
    return if (a) |v| v - b else null;
}

fn mainOf(axis: Axis, p: Proposal) ?f32 {
    return if (axis == .horizontal) p.width else p.height;
}
fn crossOf(axis: Axis, p: Proposal) ?f32 {
    return if (axis == .horizontal) p.height else p.width;
}
fn mainAxis(axis: Axis, s: Size) f32 {
    return if (axis == .horizontal) s.width else s.height;
}
fn crossAxis(axis: Axis, s: Size) f32 {
    return if (axis == .horizontal) s.height else s.width;
}
fn mainOf2(axis: Axis, p: Point) f32 {
    return if (axis == .horizontal) p.x else p.y;
}
fn crossOf2(axis: Axis, p: Point) f32 {
    return if (axis == .horizontal) p.y else p.x;
}
fn sizeFrom(axis: Axis, main: f32, cross: f32) Size {
    return if (axis == .horizontal)
        .{ .width = main, .height = cross }
    else
        .{ .width = cross, .height = main };
}
fn propFrom(axis: Axis, main: ?f32, cross: ?f32) Proposal {
    return if (axis == .horizontal)
        .{ .width = main, .height = cross }
    else
        .{ .width = cross, .height = main };
}
fn rectFrom(axis: Axis, main_pos: f32, cross_pos: f32, main_len: f32, cross_len: f32) Rect {
    return if (axis == .horizontal)
        .{ .x = main_pos, .y = cross_pos, .width = main_len, .height = cross_len }
    else
        .{ .x = cross_pos, .y = main_pos, .width = cross_len, .height = main_len };
}
fn crossAlignFraction(axis: Axis, a: Alignment) f32 {
    return if (axis == .horizontal) a.vertical.fraction() else a.horizontal.fraction();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn leaf(w: f32, h: f32) Node {
    return .{ .leaf = SizingHints.fixedSize(.{ .width = w, .height = h }) };
}

test "measure: leaf reports ideal when proposal unspecified" {
    const n = Node{ .leaf = .{
        .min = .{ .width = 10, .height = 10 },
        .ideal = .{ .width = 50, .height = 20 },
        .max = .{ .width = 100, .height = 100 },
    } };
    try testing.expectEqual(Size{ .width = 50, .height = 20 }, measure(n, .unspecified));
}

test "measure: leaf clamps to proposal within min/max" {
    const n = Node{ .leaf = .{
        .min = .{ .width = 10, .height = 10 },
        .ideal = .{ .width = 50, .height = 20 },
        .max = .{ .width = 100, .height = 100 },
    } };
    // width 200 clamps down to max 100; height 50 passes through (within bounds)
    try testing.expectEqual(Size{ .width = 100, .height = 50 }, measure(n, .{ .width = 200, .height = 50 }));
}

test "measure: HStack of two fixed leaves with spacing" {
    const children = [_]Node{ leaf(50, 20), leaf(30, 40) };
    const n = Node{ .stack = .{ .direction = .horizontal, .spacing = 10, .children = &children } };
    // 50 + 10 + 30 = 90 wide, max height 40
    try testing.expectEqual(Size{ .width = 90, .height = 40 }, measure(n, .unspecified));
}

test "measure: VStack stacks heights, max width" {
    const children = [_]Node{ leaf(50, 20), leaf(30, 40) };
    const n = Node{ .stack = .{ .direction = .vertical, .spacing = 5, .children = &children } };
    try testing.expectEqual(Size{ .width = 50, .height = 65 }, measure(n, .unspecified));
}

test "arrange: HStack places children sequentially with spacing" {
    const children = [_]Node{ leaf(50, 20), leaf(30, 20) };
    const n = Node{ .stack = .{ .direction = .horizontal, .spacing = 10, .alignment = .top, .children = &children } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 90, .height = 20 });
    try testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 50, .height = 20 }, res.children[0].frame);
    try testing.expectEqual(Rect{ .x = 60, .y = 0, .width = 30, .height = 20 }, res.children[1].frame);
}

test "arrange: Spacer pushes siblings apart" {
    const children = [_]Node{ leaf(50, 20), .{ .spacer = .{} }, leaf(50, 20) };
    const n = Node{ .stack = .{ .direction = .horizontal, .children = &children } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 200, .height = 20 });
    try testing.expectEqual(@as(f32, 0), res.children[0].frame.x);
    // the spacer occupies the gap: x=50, width=100 (it draws nothing, so its
    // cross size/position is irrelevant)
    try testing.expectEqual(@as(f32, 50), res.children[1].frame.x);
    try testing.expectEqual(@as(f32, 100), res.children[1].frame.width);
    try testing.expectEqual(@as(f32, 150), res.children[2].frame.x);
}

test "arrange: HStack cross-axis alignment centers shorter child" {
    const children = [_]Node{ leaf(50, 40), leaf(30, 10) };
    const n = Node{ .stack = .{ .direction = .horizontal, .alignment = .center, .children = &children } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 80, .height = 40 });
    // second child (height 10) centered in 40 -> y = 15
    try testing.expectEqual(@as(f32, 15), res.children[1].frame.y);
}

test "measure+arrange: padding wraps child" {
    const child = leaf(50, 20);
    const n = Node{ .padding = .{ .insets = geom.EdgeInsets.all(10), .child = &child } };
    try testing.expectEqual(Size{ .width = 70, .height = 40 }, measure(n, .unspecified));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 70, .height = 40 });
    try testing.expectEqual(Rect{ .x = 10, .y = 10, .width = 50, .height = 20 }, res.children[0].frame);
}

test "measure: fixed frame overrides child size" {
    const child = leaf(50, 20);
    const n = Node{ .frame = .{ .width = 100, .height = 100, .child = &child } };
    try testing.expectEqual(Size{ .width = 100, .height = 100 }, measure(n, .unspecified));
}

test "arrange: fixed frame centers child by default" {
    const child = leaf(50, 20);
    const n = Node{ .frame = .{ .width = 100, .height = 100, .alignment = .center, .child = &child } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    // (100-50)/2 = 25 ; (100-20)/2 = 40
    try testing.expectEqual(Rect{ .x = 25, .y = 40, .width = 50, .height = 20 }, res.children[0].frame);
}

test "measure: frame maxWidth infinity fills proposal" {
    const child = leaf(50, 20);
    const n = Node{ .frame = .{ .max_width = inf, .child = &child } };
    try testing.expectEqual(@as(f32, 300), measure(n, .{ .width = 300, .height = null }).width);
}

test "measure+arrange: .measured leaf is width-dependent and arranges to its rect" {
    const M = struct {
        // height grows as ceil(width / 10) — a stand-in for wrapped text.
        fn f(_: *const anyopaque, prop: Proposal) Size {
            const w = prop.width orelse 0;
            return .{ .width = w, .height = @ceil(w / 10) };
        }
    };
    const n = Node{ .measured = .{ .ctx = undefined, .measureFn = M.f } };
    try testing.expectEqual(@as(f32, 10), measure(n, .{ .width = 100, .height = null }).height);
    try testing.expectEqual(@as(f32, 5), measure(n, .{ .width = 50, .height = null }).height);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 1, .y = 2, .width = 30, .height = 40 });
    try testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 30, .height = 40 }, res.frame);
}

test "measure: .measured inside a VStack reports its proposed-width height" {
    const M = struct {
        fn f(_: *const anyopaque, prop: Proposal) Size {
            const w = prop.width orelse 0;
            return .{ .width = w, .height = @ceil(w / 10) };
        }
    };
    const children = [_]Node{ .{ .measured = .{ .ctx = undefined, .measureFn = M.f } }, leaf(20, 5) };
    const n = Node{ .stack = .{ .direction = .vertical, .spacing = 0, .children = &children } };
    // width 100 -> measured child is 10 tall; plus the 5-tall leaf = 15.
    try testing.expectEqual(@as(f32, 15), measure(n, .{ .width = 100, .height = null }).height);
}

test "measure+arrange: ZStack overlays children, sized to largest" {
    const children = [_]Node{ leaf(50, 20), leaf(30, 40) };
    const n = Node{ .stack = .{ .direction = .depth, .alignment = .center, .children = &children } };
    try testing.expectEqual(Size{ .width = 50, .height = 40 }, measure(n, .unspecified));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try arrange(arena.allocator(), n, .{ .x = 0, .y = 0, .width = 50, .height = 40 });
    // child0 (50x20) centered -> y=10 ; child1 (30x40) centered -> x=10
    try testing.expectEqual(Rect{ .x = 0, .y = 10, .width = 50, .height = 20 }, res.children[0].frame);
    try testing.expectEqual(Rect{ .x = 10, .y = 0, .width = 30, .height = 40 }, res.children[1].frame);
}
