//! End-to-end integration tests: build a realistic SwiftUI-style screen with
//! the public component API, render it through the full pipeline (view → layout
//! → canvas → software rasterizer), and assert on the resulting pixels and on
//! interaction. This exercises the whole stack headlessly and stands in for the
//! `examples/settings` demo in CI.

const std = @import("std");
const testing = std.testing;

const zigui = @import("zigui.zig");
const v = zigui.view;
const raster = zigui.raster;
const macos = zigui.macos;

const Color = zigui.Color;
const Rect = zigui.Rect;

const Settings = struct {
    wifi: zigui.State(bool),
    brightness: zigui.State(f32),

    fn toggleWifi(self: *Settings) void {
        self.wifi.set(!self.wifi.get());
    }
};

fn settingsBody(st: *Settings) zigui.View {
    const t = macos.light;
    const card = zigui.VStack(.{
        zigui.HStack(.{
            zigui.Label("Wi‑Fi", t.colors.accent),
            zigui.Spacer(),
            zigui.Toggle("", st.wifi.binding()),
        }).frameMaxWidth(),
        zigui.Divider(),
        zigui.HStack(.{
            zigui.Text("Brightness"),
            zigui.Spacer(),
            zigui.Slider(st.brightness.binding(), 0, 1).frameWidth(160),
        }).frameMaxWidth(),
    }).spacing(10)
        .padding(14)
        .background(t.colors.control_background)
        .cornerRadius(10)
        .frameMaxWidth();

    return zigui.VStack(.{
        zigui.Text("Settings").font(.large_title).frameMaxWidth(),
        card,
        zigui.ProgressView(0.62).frameMaxWidth(),
        zigui.Spacer(),
    }).spacing(16).padding(20).frameMaxWidth();
}

const Harness = struct {
    font: zigui.Font,
    cache: zigui.GlyphCache,
    arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(v.HitRegion),

    fn init() Harness {
        return .{
            .font = zigui.Font.default(),
            .cache = undefined,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .hits = .empty,
        };
    }
    fn start(self: *Harness) void {
        self.cache = zigui.GlyphCache.init(testing.allocator, &self.font.face);
        v.beginBuild(self.arena.allocator());
    }
    fn deinit(self: *Harness) void {
        v.endBuild();
        self.cache.deinit();
        self.arena.deinit();
    }
    fn context(self: *Harness) zigui.Context {
        return zigui.Context.init(macos.light, &self.cache, self.arena.allocator(), &self.hits);
    }
};

test "integration: settings screen renders a rich, non-empty frame" {
    var h = Harness.init();
    h.start();
    defer h.deinit();

    var st = Settings{
        .wifi = zigui.State(bool).init(testing.allocator, true),
        .brightness = zigui.State(f32).init(testing.allocator, 0.7),
    };
    defer {
        st.wifi.deinit();
        st.brightness.deinit();
    }

    var ctx = h.context();
    const tree = settingsBody(&st);

    var canvas = zigui.Canvas.init(h.arena.allocator());
    const w: u32 = 400;
    const hgt: u32 = 500;
    try canvas.fillRect(.{ .x = 0, .y = 0, .width = w, .height = hgt }, macos.light.colors.window_background);
    try zigui.render(&ctx, tree, .{ .x = 0, .y = 0, .width = w, .height = hgt }, &canvas);

    var fb = try raster.Framebuffer.init(testing.allocator, w, hgt);
    defer fb.deinit();
    fb.clear(macos.light.colors.window_background);
    try raster.render(testing.allocator, &fb, canvas.commands.items);

    // The screen should produce a substantial command list...
    try testing.expect(canvas.count() > 15);
    // ...register interactive regions (toggle + slider)...
    try testing.expect(h.hits.items.len >= 2);

    // ...and ink a meaningful number of dark (text) and accent (controls) pixels.
    var dark: u32 = 0;
    var accent: u32 = 0;
    for (fb.pixels) |p| {
        if (p.luminance() < 0.45) dark += 1;
        if (p.b > p.r + 0.2 and p.b > 0.4) accent += 1;
    }
    try testing.expect(dark > 100); // title + labels rendered
    try testing.expect(accent > 50); // wifi switch (on) + slider fill + progress
}

test "integration: tapping the Wi‑Fi toggle flips state across a rebuild" {
    var h = Harness.init();
    h.start();
    defer h.deinit();

    var st = Settings{
        .wifi = zigui.State(bool).init(testing.allocator, true),
        .brightness = zigui.State(f32).init(testing.allocator, 0.5),
    };
    defer {
        st.wifi.deinit();
        st.brightness.deinit();
    }

    var ctx = h.context();
    var canvas = zigui.Canvas.init(h.arena.allocator());
    const w: u32 = 400;
    const hgt: u32 = 500;
    try zigui.render(&ctx, settingsBody(&st), .{ .x = 0, .y = 0, .width = w, .height = hgt }, &canvas);

    // Find the toggle hit region and tap its center.
    var tapped = false;
    for (h.hits.items) |r| {
        if (r.action == .toggle) {
            try testing.expect(zigui.dispatchTap(h.hits.items, r.rect.center()));
            tapped = true;
            break;
        }
    }
    try testing.expect(tapped);
    try testing.expect(!st.wifi.get()); // flipped from true to false
}

// ---------------------------------------------------------------------------
// Post-v0 features, exercised together end-to-end.
// ---------------------------------------------------------------------------

const Showcase = struct {
    tab: zigui.State(i64),
    wifi: zigui.State(bool),
    show_sheet: zigui.State(bool),

    fn openSheet(self: *Showcase) void {
        self.show_sheet.set(true);
    }
};

fn showcaseBody(st: *Showcase) zigui.View {
    const tabs = [_]v.Tab{
        .{
            .label = "General",
            .content = zigui.VStack(.{
                zigui.Toggle("Wi‑Fi", st.wifi.binding()).frameMaxWidth(),
                // a frosted material card -> emits a blur_rect
                zigui.Text("Frosted").padding(10).backgroundMaterial(.regular),
            }).spacing(8).frameMaxWidth(),
        },
        .{ .label = "Advanced", .content = zigui.Text("Advanced") },
    };
    const sidebar = zigui.VStack(.{
        zigui.Text("Settings").font(.headline),
        zigui.Button("Open Sheet", zigui.actionCtx(Showcase, st, Showcase.openSheet)),
        zigui.Spacer(),
    }).spacing(8);
    const detail = zigui.TabView(st.tab.binding(), &tabs).frameMaxWidth();
    return v.NavigationSplitView(sidebar, detail, macos.light.colors.secondary_background)
        .sheet(st.show_sheet.binding(), zigui.Text("This is a sheet").padding(20));
}

test "integration: nav + tabs + sheet + material + a11y compose in one render" {
    var h = Harness.init();
    h.start();
    defer h.deinit();

    var st = Showcase{
        .tab = zigui.State(i64).init(testing.allocator, 0),
        .wifi = zigui.State(bool).init(testing.allocator, true),
        .show_sheet = zigui.State(bool).init(testing.allocator, true),
    };
    defer {
        st.tab.deinit();
        st.wifi.deinit();
        st.show_sheet.deinit();
    }

    var ctx = h.context();
    var overlays: std.ArrayList(v.OverlayReq) = .empty;
    var a11y: std.ArrayList(v.A11yNode) = .empty;
    ctx.overlays = &overlays;
    ctx.a11y = &a11y;

    var canvas = zigui.Canvas.init(h.arena.allocator());
    const w: u32 = 600;
    const hgt: u32 = 460;
    try zigui.render(&ctx, showcaseBody(&st), .{ .x = 0, .y = 0, .width = w, .height = hgt }, &canvas);

    // the .sheet was presented -> one overlay collected, drawn as a scrim
    try testing.expectEqual(@as(usize, 1), overlays.items.len);
    try testing.expectEqual(v.OverlayStyle.sheet, overlays.items[0].style);

    // the material card emitted a blur command
    var has_blur = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .blur_rect) has_blur = true;
    }
    try testing.expect(has_blur);

    // the accessibility tree captured the toggle (as a switch) and the button
    var switch_on = false;
    var has_button = false;
    for (a11y.items) |n| {
        if (n.role == .switch_ and std.mem.eql(u8, n.value, "on")) switch_on = true;
        if (n.role == .button and std.mem.eql(u8, n.label, "Open Sheet")) has_button = true;
    }
    try testing.expect(switch_on);
    try testing.expect(has_button);

    // Dismiss the modal (its scrim correctly blocks taps to the content beneath),
    // then re-render and tap the second tab segment to switch tabs.
    st.show_sheet.set(false);
    h.hits.clearRetainingCapacity();
    overlays.clearRetainingCapacity();
    canvas.clearCommands();
    try zigui.render(&ctx, showcaseBody(&st), .{ .x = 0, .y = 0, .width = w, .height = hgt }, &canvas);
    try testing.expectEqual(@as(usize, 0), overlays.items.len); // no overlay now

    var switched = false;
    for (h.hits.items) |r| {
        if (r.action == .select and r.action.select.value == 1) {
            try testing.expect(zigui.dispatchTap(h.hits.items, r.rect.center()));
            switched = true;
            break;
        }
    }
    try testing.expect(switched);
    try testing.expectEqual(@as(i64, 1), st.tab.get());
}
