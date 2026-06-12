//! Navigation components: a master/detail split view and a route-stack push/pop
//! flow. All pure composition over the view primitives — "navigation" is just
//! mutating an app-owned `NavState` that the per-frame `body` switches on.

const std = @import("std");
const view = @import("../view/view.zig");
const Color = @import("../render/color.zig").Color;

const View = view.View;
const Callback = view.Callback;
const Allocator = std.mem.Allocator;

/// A navigation route stack for `NavigationStack`-style flows. Owned by the app
/// (like `TextFieldState`), so it survives across frames; the per-frame body
/// switches on `top()` to choose the screen. Routes are opaque integer tokens
/// the app interprets. Because the tree is rebuilt every frame, "navigation" is
/// just mutating this stack.
pub const NavState = struct {
    stack: std.ArrayList(i64) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) NavState {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *NavState) void {
        self.stack.deinit(self.allocator);
    }
    pub fn push(self: *NavState, route: i64) void {
        self.stack.append(self.allocator, route) catch {};
    }
    pub fn pop(self: *NavState) void {
        if (self.stack.items.len > 0) _ = self.stack.pop();
    }
    /// The current (top-most) route, or null when at the root.
    pub fn top(self: *const NavState) ?i64 {
        const n = self.stack.items.len;
        return if (n == 0) null else self.stack.items[n - 1];
    }
    pub fn depth(self: *const NavState) usize {
        return self.stack.items.len;
    }
};

/// A two-column master/detail layout: a fixed-width `sidebar` pane (filled with
/// `sidebar_fill` so it stays themable), a vertical hairline, and a `detail`
/// pane that fills the remaining width. Pure composition over `HStack`. For the
/// macOS 26 look, fill the sidebar with a `Material` (frosted glass) and put a
/// `Sidebar` list inside it.
pub fn NavigationSplitView(sidebar: View, detail: View, sidebar_fill: Color) View {
    return view.makeStack(.horizontal, 0, .center, .{
        sidebar.frameWidth(220).frameMaxHeight().background(sidebar_fill),
        view.VDivider(),
        detail.frameMaxWidth().frameMaxHeight(),
    });
}

/// The macOS 26 *inset* split view: the sidebar floats as a rounded Liquid
/// Glass panel set in from the window edges (the style of chat/notes apps),
/// with no divider — the detail pane runs over the same window background.
/// Pair with `SidebarStyled(…, .prominent)` for accent-selected content rows.
pub fn NavigationSplitViewInset(sidebar: View, detail: View) View {
    const panel = sidebar
        .frameWidth(220)
        .frameMaxHeight()
        .cornerRadius(14)
        .glassEffect();
    return view.makeStack(.horizontal, 0, .center, .{
        view.makeStack(.vertical, 0, .center, .{panel})
            .paddingInsets(.{ .top = 10, .leading = 10, .bottom = 10, .trailing = 4 })
            .frameMaxHeight(),
        detail.frameMaxWidth().frameMaxHeight(),
    });
}

/// Closure context for a `NavigationLink` tap: a (NavState, route) pair bound at
/// build time. Allocated in the per-frame build arena, which outlives the frame
/// until the next rebuild, so the hit region's callback can safely read it.
const NavPushCtx = struct { nav: *NavState, route: i64 };

fn navPushThunk(p: ?*anyopaque) void {
    const ctx: *NavPushCtx = @ptrCast(@alignCast(p.?));
    ctx.nav.push(ctx.route);
}

/// A button that, when tapped, pushes `route` onto `nav`'s route stack. Reuses
/// the plain `.callback` hit action (no new interaction kind needed).
pub fn NavigationLink(label: []const u8, route: i64, nav: *NavState) View {
    const ctx = view.buildAlloc().create(NavPushCtx) catch @panic("oom");
    ctx.* = .{ .nav = nav, .route = route };
    return view.Button(label, .{ .ctx = ctx, .func = navPushThunk });
}

/// A button that pops the top route off `nav` (the navigation "back" button).
/// Render it in the screen's top bar when `nav.depth() > 0`.
pub fn NavBackButton(label: []const u8, nav: *NavState) View {
    return view.ButtonRoled(label, .plain, view.actionCtx(NavState, nav, NavState.pop));
}
