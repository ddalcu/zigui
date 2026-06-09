//! The zigui showcase — a single window that exercises (almost) every public
//! component, styled for the macOS 26 "Liquid Glass" look. A frosted `Sidebar`
//! switches between panels (controls, text & icons, shapes & media, layout,
//! table, the multi-line editor, overlays, effects, and a navigation stack), and
//! the footer carries a **light/dark switcher** and an **accent theme switcher**
//! that recolor the whole window live.
//!
//! Build with `zig build showcase` (run with `zig build run-showcase`).
//! Headless: `showcase --screenshot <out.bmp> [section]` renders one frame.

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");

// libc file write for the headless `--screenshot` path (std.fs needs std.Io in 0.16).
const cstdio = @cImport({
    @cInclude("stdio.h");
});

// ── Theme: appearance (light/dark) × accent ───────────────────────────────────

/// Accent palette for the theme switcher. Each recolors `accent` + `selection`.
const accents = [_]struct { name: []const u8, color: zigui.Color }{
    .{ .name = "Blue", .color = zigui.Color.fromRgb8(0, 122, 255) },
    .{ .name = "Purple", .color = zigui.Color.fromRgb8(147, 112, 219) },
    .{ .name = "Pink", .color = zigui.Color.fromRgb8(255, 55, 95) },
    .{ .name = "Green", .color = zigui.Color.fromRgb8(40, 180, 99) },
    .{ .name = "Orange", .color = zigui.Color.fromRgb8(255, 149, 0) },
};
/// One tappable accent color dot; the selected one gets a ring (macOS-style).
fn accentSwatch(st: *AppState, comptime i: usize) zigui.View {
    const sel = st.accent.get() == @as(i64, @intCast(i));
    const c = accents[i].color;
    const dot = if (sel) zigui.ZStack(.{
        zigui.Circle(t().colors.label).frame(22, 22),
        zigui.Circle(t().colors.window_background).frame(18, 18),
        zigui.Circle(c).frame(14, 14),
    }).frame(22, 22) else zigui.ZStack(.{
        zigui.Circle(c).frame(16, 16),
    }).frame(22, 22);
    return dot.onTap(zigui.selectAction(st.accent.binding(), @intCast(i)));
}

fn accentSwatches(st: *AppState) zigui.View {
    return zigui.HStack(.{
        accentSwatch(st, 0), accentSwatch(st, 1), accentSwatch(st, 2),
        accentSwatch(st, 3), accentSwatch(st, 4), zigui.Spacer(),
    }).spacing(10).frameMaxWidth();
}

/// The live theme, recomputed by `themeProvider` from the app state each frame.
/// `g_app` lets the provider read the appearance/accent selections (the provider
/// runs before `body`, so every view built this frame sees the same theme).
var g_theme = zigui.default_theme;
var g_app: ?*AppState = null;

fn themeProvider() zigui.Theme {
    const st = g_app orelse return g_theme;
    var th = if (st.dark.get()) zigui.macos.dark else zigui.macos.light;
    const ai: usize = @intCast(std.math.clamp(st.accent.get(), 0, accents.len - 1));
    th.colors.accent = accents[ai].color;
    th.colors.selection = accents[ai].color;
    g_theme = th;
    return th;
}

/// Shorthand for the live theme inside view builders.
inline fn t() zigui.Theme {
    return g_theme;
}

// ── App state ─────────────────────────────────────────────────────────────────

const AppState = struct {
    // Navigation / appearance
    section: zigui.State(i64),
    dark: zigui.State(bool),
    accent: zigui.State(i64),
    nav: zigui.NavState,

    // Controls
    toggle_a: zigui.State(bool),
    toggle_b: zigui.State(bool),
    slider: zigui.State(f32),
    stepper: zigui.State(i64),
    picker: zigui.State(i64),
    segmented: zigui.State(i64),
    radio: zigui.State(i64),
    name: zigui.TextFieldState,

    // Layout
    tab: zigui.State(i64),

    // Table
    table_sel: zigui.State(i64),
    table_scroll: zigui.ScrollState,

    // Effects / overlays
    progress: zigui.State(f32),
    show_sheet: zigui.State(bool),
    show_alert: zigui.State(bool),
    show_popover: zigui.State(bool),
    menu_open: zigui.State(bool),

    // Per-panel page scroll + the multi-line editor
    page_scroll: zigui.ScrollState,
    editor: zigui.TextFieldState,
    editor_scroll: zigui.ScrollState,

    fn clearNav(self: *AppState) void {
        while (self.nav.depth() > 0) self.nav.pop();
    }
    fn animate(self: *AppState) void {
        if (app.animator()) |a| {
            const target: f32 = if (self.progress.get() > 0.5) 0 else 1;
            a.animateTo(&self.progress, target, 0.6, .ease_in_out) catch {};
        }
    }
    fn openSheet(self: *AppState) void {
        self.show_sheet.set(true);
    }
    fn closeSheet(self: *AppState) void {
        self.show_sheet.set(false);
    }
    fn openAlert(self: *AppState) void {
        self.show_alert.set(true);
    }
    fn closeAlert(self: *AppState) void {
        self.show_alert.set(false);
    }
    fn togglePopover(self: *AppState) void {
        self.show_popover.set(!self.show_popover.get());
    }
    fn noop(_: *AppState) void {}
};

// ── Static demo data ──────────────────────────────────────────────────────────

const swatches = [_]zigui.Color{
    zigui.Color.fromRgb8(255, 99, 71),   zigui.Color.fromRgb8(255, 165, 0),
    zigui.Color.fromRgb8(60, 179, 113),  zigui.Color.fromRgb8(70, 130, 180),
    zigui.Color.fromRgb8(147, 112, 219), zigui.Color.fromRgb8(255, 105, 180),
    zigui.Color.fromRgb8(0, 206, 209),   zigui.Color.fromRgb8(154, 205, 50),
};

const icon_gallery = [_]zigui.IconName{
    .home, .search,       .settings,    .user, .users,    .heart,
    .star, .bell,         .mail,        .calendar, .clock, .folder,
    .file, .image,        .download,    .upload, .trash,  .edit,
    .copy, .share,        .lock,        .unlock, .eye,    .eye_off,
    .play, .pause,        .sun,         .moon,  .sparkles, .zap,
    .cpu,  .shield_check, .badge_check, .info,  .check,    .send,
};

// A 64×64 RGBA gradient built at comptime so the `Image` component has something
// to show without shipping an asset.
const demo_image = blk: {
    @setEvalBranchQuota(200000);
    var px: [64 * 64 * 4]u8 = undefined;
    var y: usize = 0;
    while (y < 64) : (y += 1) {
        var x: usize = 0;
        while (x < 64) : (x += 1) {
            const i = (y * 64 + x) * 4;
            px[i + 0] = @intCast(x * 4);
            px[i + 1] = @intCast(y * 4);
            px[i + 2] = @intCast(255 - x * 3);
            px[i + 3] = 255;
        }
    }
    break :blk px;
};

const scroll_labels = blk: {
    var arr: [20][]const u8 = undefined;
    for (0..20) |i| arr[i] = std.fmt.comptimePrint("Row {d}", .{i + 1});
    break :blk arr;
};

const table_columns = [_]zigui.TableColumn{
    .{ .title = "Name" },
    .{ .title = "Role" },
    .{ .title = "Age", .width = 64 },
};
const table_rows = [_][]const []const u8{
    &.{ "Ada Lovelace", "Mathematician", "36" },
    &.{ "Alan Turing", "Computer Scientist", "41" },
    &.{ "Grace Hopper", "Rear Admiral", "45" },
    &.{ "Katherine Johnson", "Mathematician", "52" },
    &.{ "Margaret Hamilton", "Engineer", "33" },
};

// ── Shared building blocks ─────────────────────────────────────────────────────

fn header(title: []const u8) zigui.View {
    return zigui.HStack(.{ zigui.Text(title).font(.large_title), zigui.Spacer() }).frameMaxWidth();
}

/// A titled, rounded "liquid glass" card.
fn card(title: []const u8, content: zigui.View) zigui.View {
    return zigui.VStack(.{
        zigui.HStack(.{
            zigui.Text(title).font(.headline).foreground(t().colors.secondary_label),
            zigui.Spacer(),
        }).frameMaxWidth(),
        content.frameMaxWidth(),
    }).spacing(10)
        .padding(14)
        .background(t().colors.control_background)
        .cornerRadius(t().metrics.corner_radius)
        .border(t().colors.separator, t().metrics.hairline)
        .frameMaxWidth();
}

/// A leading label with the control pushed to the trailing edge.
fn row(title: []const u8, control: zigui.View) zigui.View {
    return zigui.HStack(.{ zigui.Text(title), zigui.Spacer(), control }).frameMaxWidth();
}

// ── Panels ──────────────────────────────────────────────────────────────────

const picker_options = [_][]const u8{ "Small", "Medium", "Large" };
const seg_options = [_][]const u8{ "Day", "Week", "Month" };
const radio_options = [_][]const u8{ "Automatic", "On", "Off" };

fn controlsPanel(st: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Controls"),
        card("Buttons", zigui.VStack(.{
            zigui.HStack(.{
                zigui.Button("Primary", zigui.actionCtx(AppState, st, AppState.animate)),
                zigui.ButtonRoled("Delete", .destructive, zigui.actionCtx(AppState, st, AppState.noop)),
                zigui.ButtonRoled("Plain", .plain, zigui.actionCtx(AppState, st, AppState.noop)),
                zigui.Spacer(),
            }).spacing(10),
            zigui.HStack(.{
                zigui.Button("Disabled", zigui.actionCtx(AppState, st, AppState.noop)).disabled(true),
                zigui.IconButton(.heart, 18, zigui.actionCtx(AppState, st, AppState.noop)),
                zigui.IconButton(.trash, 18, zigui.actionCtx(AppState, st, AppState.noop)),
                zigui.Spacer(),
            }).spacing(10),
        }).spacing(10)),
        card("Toggles", zigui.VStack(.{
            row("Wi‑Fi", zigui.Toggle("", st.toggle_a.binding())),
            zigui.Divider(),
            row("Notifications", zigui.Toggle("", st.toggle_b.binding())),
        }).spacing(8)),
        card("Slider & Progress", zigui.VStack(.{
            zigui.Slider(st.slider.binding(), 0, 1).frameMaxWidth(),
            zigui.ProgressView(st.slider.get()).frameMaxWidth(),
        }).spacing(12)),
        card("Stepper & Pickers", zigui.VStack(.{
            row("Quantity", zigui.Stepper("", st.stepper.binding(), 0, 10, 1)),
            zigui.Divider(),
            row("Size", zigui.Picker(st.picker.binding(), &picker_options).frameWidth(220)),
            zigui.Divider(),
            row("Range", zigui.Picker(st.segmented.binding(), &seg_options).frameWidth(220)),
        }).spacing(8)),
        card("Radio group", zigui.RadioGroup(st.radio.binding(), &radio_options)),
        card("Text field", zigui.VStack(.{
            zigui.TextField("Type your name…", &st.name).frameHeight(36).cornerRadius(8).frameMaxWidth(),
            zigui.Text("Right-click for Cut / Copy / Paste / Select All.")
                .font(.footnote).foreground(t().colors.secondary_label),
        }).spacing(8)),
    }).spacing(16);
}

fn iconCell(icon: zigui.IconName) zigui.View {
    return zigui.Icon(icon, 22, t().colors.label).frameHeight(34).frameMaxWidth();
}

fn textPanel(_: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Text & Icons"),
        card("Type scale", zigui.VStack(.{
            leading(zigui.Text("Large Title").font(.large_title)),
            leading(zigui.Text("Title").font(.title)),
            leading(zigui.Text("Headline").font(.headline)),
            leading(zigui.Text("Body — the quick brown fox.").font(.body)),
            leading(zigui.Text("Footnote").font(.footnote).foreground(t().colors.secondary_label)),
        }).spacing(6)),
        card("Wrapped paragraph", zigui.WrappedText(
            "WrappedText word-wraps to the width it is given, growing taller as the " ++
                "column narrows. Reach for it for paragraphs, descriptions, captions.",
        ).foreground(t().colors.label)),
        card("Label", leading(zigui.Label("Tagged item", t().colors.accent))),
        card("Icon gallery", zigui.LazyVGrid(6, 10, &icon_gallery, iconCell).frameMaxWidth()),
    }).spacing(16);
}

/// Left-align a view inside a full-width row (frame layout centers by default).
fn leading(v: zigui.View) zigui.View {
    return zigui.HStack(.{ v, zigui.Spacer() }).frameMaxWidth();
}

fn swatchCell(col: zigui.Color) zigui.View {
    return zigui.RoundedRectangle(col, 8).frameHeight(44);
}

fn shapesPanel(_: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Shapes & Media"),
        card("Primitives", zigui.HStack(.{
            zigui.Rectangle(swatches[3]).frame(56, 56),
            zigui.RoundedRectangle(swatches[2], 12).frame(56, 56),
            zigui.Circle(swatches[0]).frame(56, 56),
            zigui.Capsule(swatches[4]).frame(80, 36),
            zigui.Ellipse(swatches[6]).frame(80, 56),
            zigui.Spacer(),
        }).spacing(12)),
        card("LinearGradient", zigui.LinearGradient(
            swatches[5],
            swatches[1],
            .{ .x = 0, .y = 0 },
            .{ .x = 1, .y = 1 },
        ).frameMaxWidth().frameHeight(90).cornerRadius(12)),
        card("Dividers", zigui.VStack(.{
            leading(zigui.Text("above")),
            zigui.Divider(),
            zigui.HStack(.{
                zigui.Text("left"),
                zigui.VDivider().frameHeight(20),
                zigui.Text("right"),
                zigui.Spacer(),
            }).spacing(12),
        }).spacing(8)),
        card("Image (generated)", zigui.HStack(.{
            zigui.Image(.{ .width = 64, .height = 64, .pixels = &demo_image }).frame(64, 64),
            zigui.WrappedText("A 64×64 RGBA gradient built at comptime and drawn via the Image component."),
        }).spacing(12)),
        card("Material (frosted over gradient)", zigui.ZStack(.{
            zigui.LinearGradient(t().colors.accent, swatches[5], .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 })
                .frameMaxWidth().frameHeight(120),
            zigui.Text("Regular material").font(.headline)
                .padding(16).backgroundMaterial(.regular).cornerRadius(12),
        })),
    }).spacing(16);
}

fn scrollRow(label: []const u8) zigui.View {
    return zigui.HStack(.{ zigui.Text(label), zigui.Spacer() }).frameMaxWidth();
}

fn listRow(icon: zigui.IconName, label: []const u8) zigui.View {
    return zigui.HStack(.{
        zigui.Icon(icon, 16, t().colors.accent),
        zigui.Text(label),
        zigui.Spacer(),
        zigui.Icon(.chevron_right, 14, t().colors.tertiary_label),
    }).spacing(10).padding(8).frameMaxWidth();
}

fn layoutPanel(st: *AppState) zigui.View {
    const tabs = [_]zigui.Tab{
        .{ .label = "Scroll", .content = zigui.ScrollView(zigui.VStack(.{
            zigui.ForEach(&scroll_labels, scrollRow),
        }).spacing(6).padding(8)) },
        .{ .label = "Info", .content = zigui.WrappedText(
            "TabView reuses Picker for its bar; the body switches on the bound " ++
                "selection. The first tab nests a ScrollView with 20 rows.",
        ).padding(12) },
    };
    return zigui.VStack(.{
        header("Layout"),
        card("HStack · Spacer · ZStack", zigui.VStack(.{
            zigui.HStack(.{ zigui.Text("leading"), zigui.Spacer(), zigui.Text("trailing") }).frameMaxWidth(),
            zigui.ZStack(.{
                zigui.RoundedRectangle(swatches[7], 10).frameMaxWidth().frameHeight(60),
                zigui.Text("ZStack overlay").foreground(zigui.Color.white).font(.headline),
            }),
        }).spacing(10)),
        card("LazyVGrid", zigui.LazyVGrid(4, 8, &swatches, swatchCell).frameMaxWidth()),
        card("LazyHGrid", zigui.LazyHGrid(2, 8, &swatches, swatchCell).frameHeight(96)),
        card("List", zigui.VStack(.{
            listRow(.user, "Profile"),
            zigui.Divider(),
            listRow(.bell, "Notifications"),
            zigui.Divider(),
            listRow(.lock, "Privacy"),
        }).spacing(0)),
        card("TabView + ScrollView", zigui.TabView(st.tab.binding(), &tabs).frameMaxWidth().frameHeight(170)),
    }).spacing(16);
}

fn tablePanel(st: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Table"),
        zigui.Text("A multi-column table with a header and selectable rows:")
            .foreground(t().colors.secondary_label).frameMaxWidth(),
        zigui.Table(&table_columns, &table_rows, st.table_sel.binding())
            .background(t().colors.control_background)
            .cornerRadius(t().metrics.corner_radius)
            .border(t().colors.separator, t().metrics.hairline)
            .frameMaxWidth()
            .frameMaxHeight(),
    }).spacing(12).padding(20).frameMaxWidth().frameMaxHeight();
}

fn editorPanel(st: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Text editor"),
        zigui.Text("Multi-line editing with selection, line numbers, and mouse drag. Click in and type.")
            .font(.footnote).foreground(t().colors.secondary_label).frameMaxWidth(),
        zigui.TextEditor(&st.editor, &st.editor_scroll, true).frameMaxWidth().frameMaxHeight(),
    }).spacing(12).padding(20).frameMaxWidth().frameMaxHeight();
}

fn overlaysPanel(st: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Overlays"),
        card("Modal presentations", zigui.HStack(.{
            zigui.Button("Show sheet", zigui.actionCtx(AppState, st, AppState.openSheet)),
            zigui.Button("Show alert", zigui.actionCtx(AppState, st, AppState.openAlert)),
            zigui.Spacer(),
        }).spacing(10)),
        card("Menu", zigui.HStack(.{
            zigui.Menu("Options ▾", &st.menu_open, .{
                zigui.Button("Animate", zigui.actionCtx(AppState, st, AppState.animate)),
                zigui.Button("Show sheet", zigui.actionCtx(AppState, st, AppState.openSheet)),
            }),
            zigui.Spacer(),
        })),
        card("Popover", zigui.HStack(.{
            zigui.Button("Toggle popover", zigui.actionCtx(AppState, st, AppState.togglePopover))
                .popover(st.show_popover.binding(), zigui.VStack(.{
                zigui.Text("Popover").font(.headline),
                zigui.WrappedText("Anchored near its trigger; tap outside to dismiss."),
            }).spacing(8).padding(14).frameWidth(220)),
            zigui.Spacer(),
        })),
    }).spacing(16);
}

fn effectsPanel(st: *AppState) zigui.View {
    return zigui.VStack(.{
        header("Effects"),
        card("Animation", zigui.VStack(.{
            zigui.ProgressView(st.progress.get()).frameMaxWidth(),
            zigui.HStack(.{
                zigui.Button("Animate value", zigui.actionCtx(AppState, st, AppState.animate)),
                zigui.Spacer(),
            }),
        }).spacing(10)),
        card("Opacity · border · corner radius", zigui.HStack(.{
            zigui.RoundedRectangle(swatches[0], 10).frame(64, 64).opacity(0.4),
            zigui.RoundedRectangle(swatches[2], 10).frame(64, 64).border(t().colors.label, 2),
            zigui.RoundedRectangle(swatches[3], 24).frame(64, 64),
            zigui.Spacer(),
        }).spacing(12)),
    }).spacing(16);
}

fn navPanel(st: *AppState) zigui.View {
    if (st.nav.top()) |route| {
        return zigui.VStack(.{
            leading(zigui.NavBackButton("‹ Back", &st.nav)),
            header("Detail"),
            zigui.WrappedText(zigui.view.fmt(
                "You pushed route {d}. NavState holds the route stack; NavBackButton pops it.",
                .{route},
            )),
            zigui.Spacer(),
        }).spacing(12).padding(20).frameMaxWidth().frameMaxHeight();
    }
    return zigui.VStack(.{
        header("Navigation"),
        zigui.Text("Tap a row to push a detail view onto the stack.")
            .foreground(t().colors.secondary_label).frameMaxWidth(),
        card("Stack", zigui.VStack(.{
            zigui.NavigationLink("Inbox", 1, &st.nav).frameMaxWidth(),
            zigui.NavigationLink("Archive", 2, &st.nav).frameMaxWidth(),
            zigui.NavigationLink("Trash", 3, &st.nav).frameMaxWidth(),
        }).spacing(6)),
        zigui.Spacer(),
    }).spacing(16).frameMaxHeight();
}

// ── Shell ─────────────────────────────────────────────────────────────────────

const sidebar_items = [_]zigui.SidebarItem{
    .{ .label = "Controls", .icon = .settings },
    .{ .label = "Text & Icons", .icon = .sparkles },
    .{ .label = "Shapes & Media", .icon = .image },
    .{ .label = "Layout", .icon = .boxes },
    .{ .label = "Table", .icon = .folder },
    .{ .label = "Editor", .icon = .edit },
    .{ .label = "Overlays", .icon = .menu },
    .{ .label = "Effects", .icon = .zap },
    .{ .label = "Navigation", .icon = .send },
};

fn detailPanel(st: *AppState) zigui.View {
    const panel = switch (st.section.get()) {
        1 => textPanel(st),
        2 => shapesPanel(st),
        3 => layoutPanel(st),
        4 => return tablePanel(st), // manages its own scroll
        5 => return editorPanel(st), // editor fills; no outer scroll
        6 => overlaysPanel(st),
        7 => effectsPanel(st),
        8 => return navPanel(st).padding(20),
        else => controlsPanel(st),
    };
    // Every long panel scrolls as a whole so nothing is clipped off-screen.
    return zigui.ScrollViewState(&st.page_scroll, panel.padding(20).frameMaxWidth())
        .frameMaxWidth()
        .frameMaxHeight();
}

fn sidebar(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.HStack(.{
            zigui.Icon(.boxes, 20, t().colors.accent),
            zigui.Text("zigui").font(.headline),
            zigui.Spacer(),
        }).spacing(8).paddingInsets(.{ .top = 8, .leading = 10, .bottom = 4, .trailing = 8 }),
        zigui.Sidebar(&sidebar_items, st.section.binding()),
        zigui.Spacer(),
        zigui.Divider(),
        // Appearance + accent theme switchers.
        row("Dark mode", zigui.Toggle("", st.dark.binding())).padding(6),
        zigui.VStack(.{
            leading(zigui.Text("Accent").font(.footnote).foreground(t().colors.secondary_label)),
            accentSwatches(st),
        }).spacing(6).padding(6),
    }).spacing(4).padding(8).frameMaxHeight().backgroundMaterial(.thin);
}

fn body(st: *AppState) zigui.View {
    // Switching away from the Navigation panel resets its push/pop stack.
    if (st.section.get() != 8) st.clearNav();

    const sheet_content = zigui.VStack(.{
        zigui.Text("Sheet").font(.title),
        zigui.WrappedText("A bottom sheet drawn over a dimming scrim. Tap outside or Done to dismiss."),
        zigui.HStack(.{
            zigui.Spacer(),
            zigui.Button("Done", zigui.actionCtx(AppState, st, AppState.closeSheet)),
        }).frameMaxWidth(),
    }).spacing(12).padding(20).frameWidth(340);

    const alert_content = zigui.VStack(.{
        zigui.Icon(.info, 28, t().colors.accent),
        zigui.Text("Heads up").font(.headline),
        zigui.Text("This is a centered alert overlay."),
        zigui.Button("OK", zigui.actionCtx(AppState, st, AppState.closeAlert)),
    }).spacing(12).padding(20).frameWidth(300);

    return zigui.NavigationSplitView(sidebar(st), detailPanel(st), t().colors.secondary_background)
        .sheet(st.show_sheet.binding(), sheet_content)
        .alert(st.show_alert.binding(), alert_content);
}

// ── Headless screenshot (no window) ───────────────────────────────────────────

fn writeBmp(path: [:0]const u8, fb: *const zigui.Framebuffer) void {
    const w = fb.width;
    const h = fb.height;
    const stride = w * 3 + (4 - (w * 3) % 4) % 4;
    const img_size = stride * h;
    const f = cstdio.fopen(path.ptr, "wb") orelse return;
    defer _ = cstdio.fclose(f);
    var hdr = [_]u8{0} ** 54;
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], @intCast(54 + img_size), .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(i32, hdr[18..22], @intCast(w), .little);
    std.mem.writeInt(i32, hdr[22..26], @intCast(h), .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 24, .little);
    std.mem.writeInt(u32, hdr[34..38], @intCast(img_size), .little);
    _ = cstdio.fwrite(&hdr, 1, 54, f);
    const scanline = std.heap.page_allocator.alloc(u8, stride) catch return;
    defer std.heap.page_allocator.free(scanline);
    @memset(scanline, 0);
    var y: u32 = h;
    while (y > 0) {
        y -= 1; // BMP rows are bottom-up
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = fb.at(x, y).toRgba8();
            scanline[x * 3 + 0] = px.b;
            scanline[x * 3 + 1] = px.g;
            scanline[x * 3 + 2] = px.r;
        }
        _ = cstdio.fwrite(scanline.ptr, 1, stride, f);
    }
}

fn screenshot(gpa: std.mem.Allocator, st: *AppState, out: [:0]const u8) !void {
    const w: u32 = 900;
    const h: u32 = 640;
    const theme = themeProvider();
    var font = zigui.Font.default();
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();
    var icon_font = zigui.Font.icons();
    var icon_cache = zigui.GlyphCache.init(gpa, &icon_font.face);
    defer icon_cache.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    zigui.setThemeTokens(theme);
    zigui.beginBuild(arena.allocator());
    const root = body(st);
    zigui.endBuild();

    var hits: std.ArrayList(zigui.HitRegion) = .empty;
    var overlays: std.ArrayList(zigui.OverlayReq) = .empty;
    var ctx = zigui.Context.init(theme, &cache, arena.allocator(), &hits);
    ctx.icon_cache = &icon_cache;
    ctx.overlays = &overlays; // so sheets/alerts/popovers are drawn headlessly too
    var canvas = zigui.Canvas.init(arena.allocator());
    const full = zigui.Rect{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) };
    try canvas.fillRect(full, theme.colors.window_background);
    try zigui.render(&ctx, root, full, &canvas);

    var fb = try zigui.Framebuffer.init(gpa, w, h);
    defer fb.deinit();
    fb.clear(theme.colors.window_background);
    try zigui.raster.render(gpa, &fb, canvas.commands.items);
    writeBmp(out, &fb);
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out, w, h });
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    var st = AppState{
        .section = zigui.State(i64).init(alloc, 0),
        .dark = zigui.State(bool).init(alloc, false),
        .accent = zigui.State(i64).init(alloc, 0),
        .nav = zigui.NavState.init(alloc),
        .toggle_a = zigui.State(bool).init(alloc, true),
        .toggle_b = zigui.State(bool).init(alloc, false),
        .slider = zigui.State(f32).init(alloc, 0.5),
        .stepper = zigui.State(i64).init(alloc, 2),
        .picker = zigui.State(i64).init(alloc, 1),
        .segmented = zigui.State(i64).init(alloc, 0),
        .radio = zigui.State(i64).init(alloc, 0),
        .name = zigui.TextFieldState.init(alloc),
        .tab = zigui.State(i64).init(alloc, 0),
        .table_sel = zigui.State(i64).init(alloc, 0),
        .table_scroll = .{},
        .progress = zigui.State(f32).init(alloc, 0.3),
        .show_sheet = zigui.State(bool).init(alloc, false),
        .show_alert = zigui.State(bool).init(alloc, false),
        .show_popover = zigui.State(bool).init(alloc, false),
        .menu_open = zigui.State(bool).init(alloc, false),
        .page_scroll = .{},
        .editor = zigui.TextFieldState.init(alloc),
        .editor_scroll = .{},
    };
    defer {
        st.section.deinit();
        st.dark.deinit();
        st.accent.deinit();
        st.nav.deinit();
        st.toggle_a.deinit();
        st.toggle_b.deinit();
        st.slider.deinit();
        st.stepper.deinit();
        st.picker.deinit();
        st.segmented.deinit();
        st.radio.deinit();
        st.name.deinit();
        st.tab.deinit();
        st.table_sel.deinit();
        st.progress.deinit();
        st.show_sheet.deinit();
        st.show_alert.deinit();
        st.show_popover.deinit();
        st.menu_open.deinit();
        st.editor.deinit();
    }
    st.editor.setText(
        "// zigui TextEditor\n" ++
            "fn greet(name: []const u8) void {\n" ++
            "    std.debug.print(\"Hello, {s}!\\n\", .{name});\n" ++
            "}\n\n" ++
            "Select with the mouse, use arrows + Shift,\n" ++
            "and scroll with the wheel.\n",
    ) catch {};
    g_app = &st;
    app.setThemeProvider(themeProvider);

    // `--screenshot <out.bmp> [section]` renders one frame headlessly (no window).
    var shot: ?[:0]const u8 = null;
    var section: i64 = 0;
    var it = try std.process.Args.iterateAllocator(init.args, alloc);
    defer it.deinit();
    _ = it.next(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--screenshot")) {
            shot = it.next();
        } else if (std.mem.eql(u8, a, "--dark")) {
            st.dark.set(true);
        } else if (std.mem.eql(u8, a, "--accent")) {
            if (it.next()) |n| st.accent.set(std.fmt.parseInt(i64, n, 10) catch 0);
        } else if (std.mem.eql(u8, a, "--sheet")) {
            st.show_sheet.set(true);
        } else if (std.mem.eql(u8, a, "--alert")) {
            st.show_alert.set(true);
        } else {
            section = std.fmt.parseInt(i64, a, 10) catch section;
        }
    }
    if (shot) |out| {
        st.section.set(section);
        return screenshot(alloc, &st, out);
    }

    try app.run(alloc, AppState, &st, .{ .title = "zigui — Showcase", .width = 980, .height = 660 }, body);
}
