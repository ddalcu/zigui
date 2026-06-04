//! Observation primitive for the dirty-flag reactivity model.
//!
//! An `Observer` is anything that wants to be notified when a piece of state it
//! depends on changes. In zigui every view node embeds an Observer; when a
//! `State(T)` it reads is mutated, the node is marked dirty and re-rendered on
//! the next frame. This module keeps the mechanism decoupled from the view tree
//! so it can be tested in isolation.

const std = @import("std");
const testing = std.testing;

pub const Observer = struct {
    /// Set when a dependency changes; cleared by the render loop after redraw.
    dirty: bool = true,
    /// Optional hook fired on every transition into the dirty state (e.g. to
    /// request a frame from the windowing layer). Receives this observer.
    on_dirty: ?*const fn (*Observer) void = null,
    /// Opaque user pointer (e.g. the owning view node) for the callback.
    context: ?*anyopaque = null,

    pub fn markDirty(self: *Observer) void {
        const was_clean = !self.dirty;
        self.dirty = true;
        if (was_clean) {
            if (self.on_dirty) |cb| cb(self);
        }
    }

    pub fn clear(self: *Observer) void {
        self.dirty = false;
    }
};

test "Observer: starts dirty, clears, re-dirties" {
    var o = Observer{};
    try testing.expect(o.dirty);
    o.clear();
    try testing.expect(!o.dirty);
    o.markDirty();
    try testing.expect(o.dirty);
}

test "Observer: on_dirty fires only on clean->dirty transition" {
    const Counter = struct {
        var calls: u32 = 0;
        fn cb(_: *Observer) void {
            calls += 1;
        }
    };
    Counter.calls = 0;
    var o = Observer{ .dirty = false, .on_dirty = Counter.cb };
    o.markDirty();
    o.markDirty(); // already dirty -> no second call
    try testing.expectEqual(@as(u32, 1), Counter.calls);
    o.clear();
    o.markDirty();
    try testing.expectEqual(@as(u32, 2), Counter.calls);
}
