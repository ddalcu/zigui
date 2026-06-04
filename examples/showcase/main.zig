//! A grab-bag demo exercising the post-v0 features together: a
//! `NavigationSplitView` shell, a `TabView`, a `LazyVGrid`, a `.sheet` overlay,
//! a `Menu`, a frosted `Material` background, and an animated value driven by the
//! runtime animator. Build with `zig build showcase` (run with `run-showcase`).

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");

const t = zigui.default_theme;

const swatches = [_]zigui.Color{
    zigui.Color.fromRgb8(255, 99, 71),   zigui.Color.fromRgb8(255, 165, 0),
    zigui.Color.fromRgb8(60, 179, 113),  zigui.Color.fromRgb8(70, 130, 180),
    zigui.Color.fromRgb8(147, 112, 219), zigui.Color.fromRgb8(255, 105, 180),
    zigui.Color.fromRgb8(0, 206, 209),   zigui.Color.fromRgb8(154, 205, 50),
};

const AppState = struct {
    section: zigui.State(i64), // which sidebar item is selected
    tab: zigui.State(i64), // selected tab on the Home page
    show_sheet: zigui.State(bool),
    menu_open: zigui.State(bool),
    progress: zigui.State(f32), // animated value

    fn gotoHome(self: *AppState) void {
        self.section.set(0);
    }
    fn gotoGrid(self: *AppState) void {
        self.section.set(1);
    }
    fn gotoAbout(self: *AppState) void {
        self.section.set(2);
    }
    fn openSheet(self: *AppState) void {
        self.show_sheet.set(true);
    }
    fn closeSheet(self: *AppState) void {
        self.show_sheet.set(false);
    }
    fn animate(self: *AppState) void {
        if (app.animator()) |a| {
            const target: f32 = if (self.progress.get() > 0.5) 0 else 1;
            a.animateTo(&self.progress, target, 0.6, .ease_in_out) catch {};
        }
    }
};

fn swatchCell(col: zigui.Color) zigui.View {
    return zigui.RoundedRectangle(col, 8).frameHeight(48);
}

fn overviewTab(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.Text("A frosted card over a gradient:")
            .foreground(t.colors.secondary_label)
            .frameMaxWidth(),
        zigui.ZStack(.{
            zigui.LinearGradient(t.colors.accent, t.colors.destructive, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 })
                .frameMaxWidth()
                .frameHeight(130),
            zigui.VStack(.{
                zigui.Text("Material").font(.headline),
                zigui.ProgressView(st.progress.get()).frameWidth(160),
            }).spacing(8).padding(16).backgroundMaterial(.regular).cornerRadius(12),
        }),
        zigui.HStack(.{
            zigui.Button("Animate", zigui.actionCtx(AppState, st, AppState.animate)),
            zigui.Button("Show sheet", zigui.actionCtx(AppState, st, AppState.openSheet)),
        }),
    }).spacing(12).frameMaxWidth();
}

fn statsTab(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.Text("Animated value").font(.headline),
        zigui.ProgressView(st.progress.get()).frameMaxWidth(),
        zigui.Slider(st.progress.binding(), 0, 1).frameMaxWidth(),
    }).spacing(10).padding(8).frameMaxWidth();
}

fn homeDetail(st: *AppState) zigui.View {
    const tabs = [_]zigui.Tab{
        .{ .label = "Overview", .content = overviewTab(st) },
        .{ .label = "Stats", .content = statsTab(st) },
    };
    return zigui.VStack(.{
        zigui.HStack(.{
            zigui.Text("Home").font(.title),
            zigui.Spacer(),
            zigui.Menu("Options", &st.menu_open, .{
                zigui.Button("Animate", zigui.actionCtx(AppState, st, AppState.animate)),
            }),
        }).frameMaxWidth(),
        zigui.TabView(st.tab.binding(), &tabs).frameMaxWidth(),
    }).spacing(12).padding(16).frameMaxWidth();
}

fn detail(st: *AppState) zigui.View {
    return switch (st.section.get()) {
        1 => zigui.VStack(.{
            zigui.Text("Swatches").font(.title).frameMaxWidth(),
            zigui.LazyVGrid(4, 8, &swatches, swatchCell).frameMaxWidth(),
            zigui.Spacer(),
        }).spacing(12).padding(16).frameMaxWidth(),
        2 => zigui.VStack(.{
            zigui.Text("About").font(.title).frameMaxWidth(),
            zigui.Text("A SwiftUI-like UI library in pure Zig.")
                .foreground(t.colors.secondary_label)
                .frameMaxWidth(),
            zigui.Spacer(),
        }).spacing(12).padding(16).frameMaxWidth(),
        else => homeDetail(st),
    };
}

fn body(st: *AppState) zigui.View {
    const sidebar = zigui.VStack(.{
        zigui.Text("zigui").font(.headline).padding(8),
        zigui.Button("Home", zigui.actionCtx(AppState, st, AppState.gotoHome)).frameMaxWidth(),
        zigui.Button("Grid", zigui.actionCtx(AppState, st, AppState.gotoGrid)).frameMaxWidth(),
        zigui.Button("About", zigui.actionCtx(AppState, st, AppState.gotoAbout)).frameMaxWidth(),
        zigui.Spacer(),
    }).spacing(6).padding(10).frameMaxHeight();

    const sheet_content = zigui.VStack(.{
        zigui.Text("Sheet").font(.title),
        zigui.Text("Tap outside to dismiss.").foreground(t.colors.secondary_label),
        zigui.Button("Done", zigui.actionCtx(AppState, st, AppState.closeSheet)),
    }).spacing(12).padding(20);

    return zigui.NavigationSplitView(sidebar, detail(st), t.colors.secondary_background)
        .sheet(st.show_sheet.binding(), sheet_content);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var st = AppState{
        .section = zigui.State(i64).init(alloc, 0),
        .tab = zigui.State(i64).init(alloc, 0),
        .show_sheet = zigui.State(bool).init(alloc, false),
        .menu_open = zigui.State(bool).init(alloc, false),
        .progress = zigui.State(f32).init(alloc, 0.3),
    };
    defer {
        st.section.deinit();
        st.tab.deinit();
        st.show_sheet.deinit();
        st.menu_open.deinit();
        st.progress.deinit();
    }
    try app.run(alloc, AppState, &st, .{ .title = "zigui — Showcase", .width = 760, .height = 520 }, body);
}
