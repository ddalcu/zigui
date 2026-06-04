//! State(T) and Binding(T): the observable-value primitives behind zigui's
//! reactivity. `State(T)` owns a value and a list of subscribed observers;
//! mutating it (to a different value) marks every subscriber dirty. `Binding(T)`
//! is a type-erased two-way handle into some state, used by controls like
//! TextField, Toggle, and Slider.

const std = @import("std");
const testing = std.testing;
const Observer = @import("observe.zig").Observer;

/// An observable value. Mirrors SwiftUI's `@State`.
pub fn State(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,
        subscribers: std.ArrayList(*Observer) = .empty,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, initial: T) Self {
            return .{ .value = initial, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.subscribers.deinit(self.allocator);
        }

        pub fn get(self: *const Self) T {
            return self.value;
        }

        /// Pointer to the underlying value for in-place mutation. Callers that
        /// mutate through this pointer must call `notify()` afterwards.
        pub fn ptr(self: *Self) *T {
            return &self.value;
        }

        /// Assign a new value. If it differs from the current value (by
        /// `std.meta.eql`), all subscribers are marked dirty. For slice-bearing
        /// types `eql` compares by pointer+len, not contents.
        pub fn set(self: *Self, new_value: T) void {
            if (valuesEqual(self.value, new_value)) return;
            self.value = new_value;
            self.notify();
        }

        /// Apply a mutating function to the value, then notify unconditionally.
        pub fn update(self: *Self, comptime f: fn (*T) void) void {
            f(&self.value);
            self.notify();
        }

        /// Mark every subscriber dirty.
        pub fn notify(self: *Self) void {
            for (self.subscribers.items) |obs| obs.markDirty();
        }

        pub fn subscribe(self: *Self, obs: *Observer) !void {
            for (self.subscribers.items) |existing| {
                if (existing == obs) return; // idempotent
            }
            try self.subscribers.append(self.allocator, obs);
        }

        pub fn unsubscribe(self: *Self, obs: *Observer) void {
            var i: usize = 0;
            while (i < self.subscribers.items.len) {
                if (self.subscribers.items[i] == obs) {
                    _ = self.subscribers.swapRemove(i);
                } else i += 1;
            }
        }

        pub fn subscriberCount(self: *const Self) usize {
            return self.subscribers.items.len;
        }

        /// A two-way binding into this state.
        pub fn binding(self: *Self) Binding(T) {
            return .{
                .ctx = self,
                .getFn = bindingGet,
                .setFn = bindingSet,
            };
        }

        fn bindingGet(ctx: *anyopaque) T {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.get();
        }
        fn bindingSet(ctx: *anyopaque, v: T) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.set(v);
        }
    };
}

/// A type-erased two-way reference to a value of type T, decoupled from where
/// the value actually lives. Mirrors SwiftUI's `@Binding`.
pub fn Binding(comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        getFn: *const fn (*anyopaque) T,
        setFn: *const fn (*anyopaque, T) void,

        pub fn get(self: Self) T {
            return self.getFn(self.ctx);
        }
        pub fn set(self: Self, v: T) void {
            self.setFn(self.ctx, v);
        }
    };
}

fn valuesEqual(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => a == b,
        else => std.meta.eql(a, b),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "State: get/set basic value" {
    var s = State(i32).init(testing.allocator, 0);
    defer s.deinit();
    try testing.expectEqual(@as(i32, 0), s.get());
    s.set(42);
    try testing.expectEqual(@as(i32, 42), s.get());
}

test "State: set marks subscribers dirty only when value changes" {
    var s = State(i32).init(testing.allocator, 5);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);

    s.set(5); // unchanged -> no dirty
    try testing.expect(!obs.dirty);

    s.set(6); // changed -> dirty
    try testing.expect(obs.dirty);
}

test "State: multiple subscribers all notified" {
    var s = State(i32).init(testing.allocator, 0);
    defer s.deinit();
    var a = Observer{ .dirty = false };
    var b = Observer{ .dirty = false };
    try s.subscribe(&a);
    try s.subscribe(&b);
    s.set(1);
    try testing.expect(a.dirty and b.dirty);
}

test "State: subscribe is idempotent" {
    var s = State(i32).init(testing.allocator, 0);
    defer s.deinit();
    var obs = Observer{};
    try s.subscribe(&obs);
    try s.subscribe(&obs);
    try testing.expectEqual(@as(usize, 1), s.subscriberCount());
}

test "State: unsubscribe stops notifications" {
    var s = State(i32).init(testing.allocator, 0);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);
    s.unsubscribe(&obs);
    try testing.expectEqual(@as(usize, 0), s.subscriberCount());
    s.set(99);
    try testing.expect(!obs.dirty);
}

test "State: update applies mutation and notifies unconditionally" {
    var s = State(i32).init(testing.allocator, 10);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);
    s.update(struct {
        fn f(v: *i32) void {
            v.* += 5;
        }
    }.f);
    try testing.expectEqual(@as(i32, 15), s.get());
    try testing.expect(obs.dirty);
}

test "Binding: two-way read/write routes through state" {
    var s = State(i32).init(testing.allocator, 1);
    defer s.deinit();
    const b = s.binding();
    try testing.expectEqual(@as(i32, 1), b.get());
    b.set(7);
    try testing.expectEqual(@as(i32, 7), s.get());
    // mutating the state is visible through the binding
    s.set(9);
    try testing.expectEqual(@as(i32, 9), b.get());
}

test "Binding: setting through binding marks subscribers dirty" {
    var s = State(bool).init(testing.allocator, false);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);
    const b = s.binding();
    b.set(true);
    try testing.expect(obs.dirty);
    try testing.expect(s.get());
}

test "State: works with float type (exact equality guard)" {
    var s = State(f32).init(testing.allocator, 1.5);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);
    s.set(1.5);
    try testing.expect(!obs.dirty);
    s.set(2.5);
    try testing.expect(obs.dirty);
}
