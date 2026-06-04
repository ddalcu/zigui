//! Animation: easing curves plus a tiny tween engine. An `Animator` holds a set
//! of in-flight tweens, each driving a `State(f32)` from one value to another
//! over a duration. The clock is injected — `tick(dt)` takes the elapsed time as
//! a parameter (never reads a wall clock) — so animations are fully
//! deterministic and unit-testable headlessly. The app loop supplies a real
//! `dt` (e.g. from `SDL_GetTicks`) and redraws while `active()`.

const std = @import("std");
const state = @import("state/state.zig");
const Allocator = std.mem.Allocator;

/// A timing curve mapping normalized progress `t` (0..1) to eased progress.
pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,

    pub fn apply(self: Easing, t: f32) f32 {
        const x = std.math.clamp(t, 0, 1);
        return switch (self) {
            .linear => x,
            .ease_in => x * x,
            .ease_out => 1 - (1 - x) * (1 - x),
            .ease_in_out => if (x < 0.5) 2 * x * x else 1 - 2 * (1 - x) * (1 - x),
        };
    }
};

/// A single value animation: drive `target` from `from` to `to` over `duration`
/// seconds following `easing`.
pub const Tween = struct {
    target: *state.State(f32),
    from: f32,
    to: f32,
    elapsed: f32 = 0,
    duration: f32,
    easing: Easing,

    pub fn finished(self: Tween) bool {
        return self.elapsed >= self.duration;
    }
};

pub const Animator = struct {
    tweens: std.ArrayList(Tween) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Animator {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Animator) void {
        self.tweens.deinit(self.allocator);
    }

    /// True while any tween is running (the app loop should keep redrawing).
    pub fn active(self: *const Animator) bool {
        return self.tweens.items.len > 0;
    }

    /// Animate `target` from its current value to `to` over `duration` seconds.
    /// Any in-flight tween for the same target is replaced. A non-positive
    /// duration snaps to `to` immediately.
    pub fn animateTo(self: *Animator, target: *state.State(f32), to: f32, duration: f32, easing: Easing) !void {
        var i: usize = 0;
        while (i < self.tweens.items.len) {
            if (self.tweens.items[i].target == target) {
                _ = self.tweens.swapRemove(i);
            } else i += 1;
        }
        if (duration <= 0) {
            target.set(to);
            return;
        }
        try self.tweens.append(self.allocator, .{
            .target = target,
            .from = target.get(),
            .to = to,
            .duration = duration,
            .easing = easing,
        });
    }

    /// Advance every tween by `dt` seconds, writing the interpolated value to its
    /// target (which marks subscribers dirty), and dropping completed tweens.
    pub fn tick(self: *Animator, dt: f32) void {
        var i: usize = 0;
        while (i < self.tweens.items.len) {
            const tw = &self.tweens.items[i];
            tw.elapsed += dt;
            const t = std.math.clamp(tw.elapsed / tw.duration, 0, 1);
            const eased = tw.easing.apply(t);
            tw.target.set(tw.from + (tw.to - tw.from) * eased);
            if (tw.finished()) {
                tw.target.set(tw.to); // snap exactly to the end value
                _ = self.tweens.swapRemove(i);
                // do not advance i: a swapped-in tween now occupies this slot
            } else i += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Observer = @import("state/observe.zig").Observer;

test "Easing: endpoints pinned, curves monotonic, in/out bowed correctly" {
    inline for (.{ Easing.linear, Easing.ease_in, Easing.ease_out, Easing.ease_in_out }) |e| {
        try testing.expectApproxEqAbs(@as(f32, 0), e.apply(0), 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1), e.apply(1), 1e-6);
        var prev: f32 = -1;
        var i: usize = 0;
        while (i <= 10) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / 10.0;
            const y = e.apply(t);
            try testing.expect(y >= prev - 1e-6); // non-decreasing
            prev = y;
        }
    }
    try testing.expectApproxEqAbs(@as(f32, 0.5), Easing.linear.apply(0.5), 1e-6);
    try testing.expect(Easing.ease_in.apply(0.5) < 0.5); // starts slow
    try testing.expect(Easing.ease_out.apply(0.5) > 0.5); // ends slow
    try testing.expectApproxEqAbs(@as(f32, 0.5), Easing.ease_in_out.apply(0.5), 1e-6);
}

test "Animator: animateTo interpolates over ticks and drops finished tweens" {
    var s = state.State(f32).init(testing.allocator, 0);
    defer s.deinit();
    var obs = Observer{ .dirty = false };
    try s.subscribe(&obs);

    var anim = Animator.init(testing.allocator);
    defer anim.deinit();
    try anim.animateTo(&s, 1.0, 1.0, .linear);
    try testing.expect(anim.active());

    anim.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.get(), 1e-5); // linear eased(0.5)
    try testing.expect(obs.dirty); // subscriber dirtied

    anim.tick(0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.get(), 1e-5);
    try testing.expect(!anim.active()); // completed and dropped
}

test "Animator: zero duration snaps immediately; repeated target replaces tween" {
    var s = state.State(f32).init(testing.allocator, 0);
    defer s.deinit();
    var anim = Animator.init(testing.allocator);
    defer anim.deinit();

    try anim.animateTo(&s, 5.0, 0.0, .linear);
    try testing.expectEqual(@as(f32, 5.0), s.get());
    try testing.expect(!anim.active());

    // starting a new animation for the same target replaces (not stacks) it
    try anim.animateTo(&s, 10.0, 1.0, .linear);
    try anim.animateTo(&s, 20.0, 1.0, .linear);
    try testing.expectEqual(@as(usize, 1), anim.tweens.items.len);
    anim.tick(1.0);
    try testing.expectApproxEqAbs(@as(f32, 20.0), s.get(), 1e-5);
}
