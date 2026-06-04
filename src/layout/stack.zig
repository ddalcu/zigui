//! Stack space distribution — the pure numeric core of HStack/VStack layout.
//!
//! Given an available length along the main axis, inter-item spacing, and each
//! item's `min`/`max` main length, `distribute` assigns a final length to every
//! item. It follows SwiftUI's algorithm: hand out the remaining space in equal
//! shares, least-flexible item first, so rigid items take exactly what they need
//! and flexible ones (e.g. `Spacer`, `.frame(maxWidth: .infinity)`) absorb the
//! leftover. This is a leaf function with no allocation beyond the caller's
//! output buffer, which makes the trickiest part of layout trivially testable.

const std = @import("std");

pub const FlexItem = struct {
    /// Smallest main length the item will accept (its size at proposal 0).
    min: f32,
    /// Largest main length the item will grow to (its size at a huge proposal).
    max: f32,

    pub fn flexibility(self: FlexItem) f32 {
        return self.max - self.min;
    }
};

/// Fill `out` (len == items.len) with each item's assigned main length.
pub fn distribute(available: f32, spacing: f32, items: []const FlexItem, out: []f32) void {
    std.debug.assert(out.len == items.len);
    const n = items.len;
    if (n == 0) return;

    const total_spacing = spacing * @as(f32, @floatFromInt(n - 1));
    var remaining = available - total_spacing;

    // Visit indices ordered by ascending flexibility.
    var order: [256]usize = undefined;
    std.debug.assert(n <= order.len);
    for (0..n) |i| order[i] = i;
    sortByFlexibility(order[0..n], items);

    var count: f32 = @floatFromInt(n);
    for (order[0..n]) |idx| {
        const share = remaining / count;
        const sz = std.math.clamp(share, items[idx].min, items[idx].max);
        out[idx] = sz;
        remaining -= sz;
        count -= 1;
    }
}

fn sortByFlexibility(order: []usize, items: []const FlexItem) void {
    // Simple insertion sort — stable, allocation-free, and n is tiny (children
    // of one stack). Keeps original order among equally-flexible items.
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const key = order[i];
        const key_flex = items[key].flexibility();
        var j: isize = @as(isize, @intCast(i)) - 1;
        while (j >= 0 and items[order[@intCast(j)]].flexibility() > key_flex) : (j -= 1) {
            order[@intCast(j + 1)] = order[@intCast(j)];
        }
        order[@intCast(j + 1)] = key;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "distribute: rigid items take exactly their size" {
    const items = [_]FlexItem{ .{ .min = 50, .max = 50 }, .{ .min = 30, .max = 30 } };
    var out: [2]f32 = undefined;
    distribute(200, 0, &items, &out);
    try testing.expectEqual(@as(f32, 50), out[0]);
    try testing.expectEqual(@as(f32, 30), out[1]);
}

test "distribute: spacing reduces available before allocation" {
    const items = [_]FlexItem{ .{ .min = 50, .max = 50 }, .{ .min = 50, .max = 50 } };
    var out: [2]f32 = undefined;
    distribute(200, 10, &items, &out);
    try testing.expectEqual(@as(f32, 50), out[0]);
    try testing.expectEqual(@as(f32, 50), out[1]);
}

test "distribute: a flexible spacer absorbs the leftover" {
    // two rigid 50s and one fully-flexible spacer in 200 -> spacer gets 100.
    const big = 1_000_000.0;
    const items = [_]FlexItem{
        .{ .min = 50, .max = 50 },
        .{ .min = 0, .max = big },
        .{ .min = 50, .max = 50 },
    };
    var out: [3]f32 = undefined;
    distribute(200, 0, &items, &out);
    try testing.expectEqual(@as(f32, 50), out[0]);
    try testing.expectEqual(@as(f32, 100), out[1]);
    try testing.expectEqual(@as(f32, 50), out[2]);
}

test "distribute: two equal flexible items split remaining evenly" {
    const big = 1_000_000.0;
    const items = [_]FlexItem{ .{ .min = 0, .max = big }, .{ .min = 0, .max = big } };
    var out: [2]f32 = undefined;
    distribute(200, 0, &items, &out);
    try testing.expectEqual(@as(f32, 100), out[0]);
    try testing.expectEqual(@as(f32, 100), out[1]);
}

test "distribute: least-flexible-first frees space for a stretchy item" {
    // available 100; one rigid 80, one flexible [0,inf]. Flexible gets 20.
    const big = 1_000_000.0;
    const items = [_]FlexItem{ .{ .min = 0, .max = big }, .{ .min = 80, .max = 80 } };
    var out: [2]f32 = undefined;
    distribute(100, 0, &items, &out);
    try testing.expectEqual(@as(f32, 20), out[0]);
    try testing.expectEqual(@as(f32, 80), out[1]);
}

test "distribute: single item gets all available" {
    const items = [_]FlexItem{.{ .min = 0, .max = 1000 }};
    var out: [1]f32 = undefined;
    distribute(123, 10, &items, &out);
    try testing.expectEqual(@as(f32, 123), out[0]);
}
