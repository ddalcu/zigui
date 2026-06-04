//! Geometry primitives: Point, Size, Rect, EdgeInsets, Alignment, Axis.
//! Pure value types mirroring the spatial vocabulary of SwiftUI's layout model
//! (top/leading/bottom/trailing insets, alignment guides), in plain Zig.

const std = @import("std");
const testing = std.testing;

/// A 2D point in logical (DPI-independent) coordinates. +x is right, +y down,
/// matching screen/UI conventions.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(p: Point, factor: f32) Point {
        return .{ .x = p.x * factor, .y = p.y * factor };
    }
    pub fn distance(a: Point, b: Point) f32 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

/// A 2D extent (width × height) in logical coordinates.
pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub fn area(s: Size) f32 {
        return s.width * s.height;
    }
    /// True if either dimension is zero (or negative).
    pub fn isEmpty(s: Size) bool {
        return s.width <= 0 or s.height <= 0;
    }
    pub fn scale(s: Size, factor: f32) Size {
        return .{ .width = s.width * factor, .height = s.height * factor };
    }
    pub const zero = Size{ .width = 0, .height = 0 };
};

/// An axis-aligned rectangle stored as origin + extent. Min edges are
/// inclusive, max edges exclusive (half-open), so adjacent rects tile without
/// overlap and `contains` is unambiguous.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn fromOriginSize(o: Point, s: Size) Rect {
        return .{ .x = o.x, .y = o.y, .width = s.width, .height = s.height };
    }
    pub fn origin(r: Rect) Point {
        return .{ .x = r.x, .y = r.y };
    }
    pub fn size(r: Rect) Size {
        return .{ .width = r.width, .height = r.height };
    }
    pub fn minX(r: Rect) f32 {
        return r.x;
    }
    pub fn minY(r: Rect) f32 {
        return r.y;
    }
    pub fn maxX(r: Rect) f32 {
        return r.x + r.width;
    }
    pub fn maxY(r: Rect) f32 {
        return r.y + r.height;
    }
    pub fn midX(r: Rect) f32 {
        return r.x + r.width / 2;
    }
    pub fn midY(r: Rect) f32 {
        return r.y + r.height / 2;
    }
    pub fn center(r: Rect) Point {
        return .{ .x = r.midX(), .y = r.midY() };
    }
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.minX() and p.x < r.maxX() and
            p.y >= r.minY() and p.y < r.maxY();
    }
    pub fn intersects(a: Rect, b: Rect) bool {
        return a.minX() < b.maxX() and b.minX() < a.maxX() and
            a.minY() < b.maxY() and b.minY() < a.maxY();
    }
    /// The overlapping region, or null if the rects are disjoint.
    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const x0 = @max(a.minX(), b.minX());
        const y0 = @max(a.minY(), b.minY());
        const x1 = @min(a.maxX(), b.maxX());
        const y1 = @min(a.maxY(), b.maxY());
        if (x1 <= x0 or y1 <= y0) return null;
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
    /// The smallest rect containing both inputs.
    pub fn unionRect(a: Rect, b: Rect) Rect {
        const x0 = @min(a.minX(), b.minX());
        const y0 = @min(a.minY(), b.minY());
        const x1 = @max(a.maxX(), b.maxX());
        const y1 = @max(a.maxY(), b.maxY());
        return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
    }
    /// Shrink by per-side insets (top/leading/bottom/trailing).
    pub fn inset(r: Rect, e: EdgeInsets) Rect {
        return .{
            .x = r.x + e.leading,
            .y = r.y + e.top,
            .width = r.width - e.horizontal(),
            .height = r.height - e.vertical(),
        };
    }
    /// Shrink uniformly by dx on the horizontal sides and dy on the vertical.
    pub fn insetBy(r: Rect, dx: f32, dy: f32) Rect {
        return .{
            .x = r.x + dx,
            .y = r.y + dy,
            .width = r.width - 2 * dx,
            .height = r.height - 2 * dy,
        };
    }
    pub fn offsetBy(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .width = r.width, .height = r.height };
    }
    pub const zero = Rect{};
};

/// Per-side spacing using SwiftUI's leading/trailing vocabulary (LTR: leading =
/// left, trailing = right).
pub const EdgeInsets = struct {
    top: f32 = 0,
    leading: f32 = 0,
    bottom: f32 = 0,
    trailing: f32 = 0,

    pub fn all(v: f32) EdgeInsets {
        return .{ .top = v, .leading = v, .bottom = v, .trailing = v };
    }
    /// `h` applies to leading+trailing, `v` to top+bottom.
    pub fn symmetric(h: f32, v: f32) EdgeInsets {
        return .{ .top = v, .leading = h, .bottom = v, .trailing = h };
    }
    pub fn horizontal(e: EdgeInsets) f32 {
        return e.leading + e.trailing;
    }
    pub fn vertical(e: EdgeInsets) f32 {
        return e.top + e.bottom;
    }
    pub const zero = EdgeInsets{};
};

/// Horizontal alignment guide. `fraction()` maps to a 0..1 position used when
/// placing a child in available width.
pub const HorizontalAlignment = enum {
    leading,
    center,
    trailing,

    pub fn fraction(a: HorizontalAlignment) f32 {
        return switch (a) {
            .leading => 0.0,
            .center => 0.5,
            .trailing => 1.0,
        };
    }
};

/// Vertical alignment guide. `fraction()` maps to a 0..1 position used when
/// placing a child in available height.
pub const VerticalAlignment = enum {
    top,
    center,
    bottom,

    pub fn fraction(a: VerticalAlignment) f32 {
        return switch (a) {
            .top => 0.0,
            .center => 0.5,
            .bottom => 1.0,
        };
    }
};

/// A 2D alignment combining a horizontal and vertical guide, with the common
/// SwiftUI presets.
pub const Alignment = struct {
    horizontal: HorizontalAlignment,
    vertical: VerticalAlignment,

    pub const center = Alignment{ .horizontal = .center, .vertical = .center };
    pub const leading = Alignment{ .horizontal = .leading, .vertical = .center };
    pub const trailing = Alignment{ .horizontal = .trailing, .vertical = .center };
    pub const top = Alignment{ .horizontal = .center, .vertical = .top };
    pub const bottom = Alignment{ .horizontal = .center, .vertical = .bottom };
    pub const topLeading = Alignment{ .horizontal = .leading, .vertical = .top };
    pub const topTrailing = Alignment{ .horizontal = .trailing, .vertical = .top };
    pub const bottomLeading = Alignment{ .horizontal = .leading, .vertical = .bottom };
    pub const bottomTrailing = Alignment{ .horizontal = .trailing, .vertical = .bottom };

    /// Top-left origin at which a `child` of the given size should be placed so
    /// that it is aligned within a `parent`-sized box.
    pub fn position(a: Alignment, parent: Size, child: Size) Point {
        return .{
            .x = (parent.width - child.width) * a.horizontal.fraction(),
            .y = (parent.height - child.height) * a.vertical.fraction(),
        };
    }
};

/// The two layout axes. Stacks lay out along their main axis.
pub const Axis = enum {
    horizontal,
    vertical,

    pub fn cross(a: Axis) Axis {
        return switch (a) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests (written first — TDD).
// ---------------------------------------------------------------------------

test "Point: arithmetic and distance" {
    const a = Point{ .x = 1, .y = 2 };
    const b = Point{ .x = 4, .y = 6 };
    try testing.expectEqual(Point{ .x = 5, .y = 8 }, a.add(b));
    try testing.expectEqual(Point{ .x = 3, .y = 4 }, b.sub(a));
    try testing.expectEqual(@as(f32, 5), a.distance(b)); // 3-4-5 triangle
    try testing.expectEqual(Point{ .x = 2, .y = 4 }, a.scale(2));
}

test "Size: helpers" {
    const s = Size{ .width = 10, .height = 20 };
    try testing.expectEqual(@as(f32, 200), s.area());
    try testing.expect(!s.isEmpty());
    try testing.expect((Size{ .width = 0, .height = 5 }).isEmpty());
    try testing.expectEqual(Size{ .width = 12, .height = 24 }, s.scale(1.2));
}

test "Rect: edges, center, contains" {
    const r = Rect{ .x = 10, .y = 20, .width = 100, .height = 40 };
    try testing.expectEqual(@as(f32, 10), r.minX());
    try testing.expectEqual(@as(f32, 110), r.maxX());
    try testing.expectEqual(@as(f32, 20), r.minY());
    try testing.expectEqual(@as(f32, 60), r.maxY());
    try testing.expectEqual(@as(f32, 60), r.midX());
    try testing.expectEqual(@as(f32, 40), r.midY());
    try testing.expectEqual(Point{ .x = 60, .y = 40 }, r.center());
    try testing.expect(r.contains(.{ .x = 60, .y = 40 }));
    try testing.expect(!r.contains(.{ .x = 0, .y = 0 }));
    // Boundary: min edge inclusive, max edge exclusive (half-open).
    try testing.expect(r.contains(.{ .x = 10, .y = 20 }));
    try testing.expect(!r.contains(.{ .x = 110, .y = 20 }));
}

test "Rect: origin/size round trip" {
    const r = Rect.fromOriginSize(.{ .x = 5, .y = 6 }, .{ .width = 7, .height = 8 });
    try testing.expectEqual(Point{ .x = 5, .y = 6 }, r.origin());
    try testing.expectEqual(Size{ .width = 7, .height = 8 }, r.size());
}

test "Rect: intersection" {
    const a = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const b = Rect{ .x = 50, .y = 50, .width = 100, .height = 100 };
    const i = a.intersection(b).?;
    try testing.expectEqual(Rect{ .x = 50, .y = 50, .width = 50, .height = 50 }, i);
    // disjoint rects -> null
    const c = Rect{ .x = 200, .y = 200, .width = 10, .height = 10 };
    try testing.expect(a.intersection(c) == null);
    try testing.expect(a.intersects(b));
    try testing.expect(!a.intersects(c));
}

test "Rect: union" {
    const a = Rect{ .x = 0, .y = 0, .width = 50, .height = 50 };
    const b = Rect{ .x = 100, .y = 100, .width = 50, .height = 50 };
    try testing.expectEqual(
        Rect{ .x = 0, .y = 0, .width = 150, .height = 150 },
        a.unionRect(b),
    );
}

test "Rect: inset by EdgeInsets shrinks from each side" {
    const r = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    const insets = EdgeInsets{ .top = 10, .leading = 20, .bottom = 30, .trailing = 40 };
    try testing.expectEqual(
        Rect{ .x = 20, .y = 10, .width = 40, .height = 60 },
        r.inset(insets),
    );
}

test "Rect: insetBy uniform dx/dy" {
    const r = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try testing.expectEqual(
        Rect{ .x = 10, .y = 10, .width = 80, .height = 80 },
        r.insetBy(10, 10),
    );
}

test "Rect: offsetBy translates" {
    const r = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    try testing.expectEqual(
        Rect{ .x = 8, .y = 1, .width = 10, .height = 10 },
        r.offsetBy(3, -4),
    );
}

test "EdgeInsets: constructors and sums" {
    try testing.expectEqual(
        EdgeInsets{ .top = 5, .leading = 5, .bottom = 5, .trailing = 5 },
        EdgeInsets.all(5),
    );
    try testing.expectEqual(
        EdgeInsets{ .top = 2, .leading = 3, .bottom = 2, .trailing = 3 },
        EdgeInsets.symmetric(3, 2),
    );
    const e = EdgeInsets{ .top = 1, .leading = 2, .bottom = 3, .trailing = 4 };
    try testing.expectEqual(@as(f32, 6), e.horizontal());
    try testing.expectEqual(@as(f32, 4), e.vertical());
}

test "Alignment: presets resolve fractions" {
    try testing.expectEqual(@as(f32, 0.0), HorizontalAlignment.leading.fraction());
    try testing.expectEqual(@as(f32, 0.5), HorizontalAlignment.center.fraction());
    try testing.expectEqual(@as(f32, 1.0), HorizontalAlignment.trailing.fraction());
    try testing.expectEqual(@as(f32, 0.0), VerticalAlignment.top.fraction());
    try testing.expectEqual(@as(f32, 1.0), VerticalAlignment.bottom.fraction());

    const a = Alignment.center;
    try testing.expectEqual(HorizontalAlignment.center, a.horizontal);
    try testing.expectEqual(VerticalAlignment.center, a.vertical);
    try testing.expectEqual(HorizontalAlignment.leading, Alignment.topLeading.horizontal);
    try testing.expectEqual(VerticalAlignment.top, Alignment.topLeading.vertical);
}

test "Alignment: position a child size within a parent size" {
    const parent = Size{ .width = 100, .height = 100 };
    const child = Size{ .width = 20, .height = 10 };
    // center -> (40, 45)
    try testing.expectEqual(Point{ .x = 40, .y = 45 }, Alignment.center.position(parent, child));
    // topLeading -> (0, 0)
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, Alignment.topLeading.position(parent, child));
    // bottomTrailing -> (80, 90)
    try testing.expectEqual(Point{ .x = 80, .y = 90 }, Alignment.bottomTrailing.position(parent, child));
}

test "Axis: cross axis" {
    try testing.expectEqual(Axis.vertical, Axis.horizontal.cross());
    try testing.expectEqual(Axis.horizontal, Axis.vertical.cross());
}
