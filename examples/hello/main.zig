//! The smallest zigui app: a styled greeting and a working counter button.
//! Run with `zig build hello`.

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");

const AppState = struct {
    count: zigui.State(i32),

    fn inc(self: *AppState) void {
        self.count.set(self.count.get() + 1);
    }
};

fn body(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.Text("Hello, zigui!").font(.large_title),
        zigui.Text(zigui.components.fmt("You clicked {d} time(s)", .{st.count.get()}))
            .foreground(zigui.default_theme.colors.secondary_label),
        zigui.Button("Increment", zigui.actionCtx(AppState, st, AppState.inc)),
    }).spacing(16).padding(40);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var st = AppState{ .count = zigui.State(i32).init(alloc, 0) };
    defer st.count.deinit();
    try app.run(alloc, AppState, &st, .{ .title = "zigui — hello", .width = 480, .height = 320 }, body);
}
