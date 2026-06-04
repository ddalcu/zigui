//! Headless screenshot generator — renders a representative zigui chat UI to a
//! BMP using **only the pure `zigui` module + libc** (no SDL, no window). CI
//! builds and runs this on Linux, macOS, and Windows to produce a per-OS
//! screenshot artifact, so you can confirm the rendering is identical across
//! platforms.
//!
//!     zig build run-screenshot -- out.bmp
//!
//! It deliberately mirrors the `llm-chat` look (accent bubbles, rounded sidebar
//! selection, pill input + circular send) using public components.

const std = @import("std");
const zigui = @import("zigui");

// libc file write (std.fs needs the new std.Io model in Zig 0.16).
const cstdio = @cImport({
    @cInclude("stdio.h");
});

const t = zigui.default_theme;

fn noop() zigui.Callback {
    return zigui.action(struct {
        fn f() void {}
    }.f);
}

/// Left-align a view inside a full-width row (the frame layout centers by
/// default, so a trailing Spacer is how you push to the leading edge).
fn leading(v: zigui.View) zigui.View {
    return zigui.HStack(.{ v, zigui.Spacer() }).frameMaxWidth();
}

/// Cap a view's width (chat bubbles shouldn't span the whole pane).
fn maxWidth(v: zigui.View, w: f32) zigui.View {
    var out = v;
    var f = out.mods.frame orelse zigui.view.FrameSpec{};
    f.max_width = w;
    out.mods.frame = f;
    return out;
}

fn bubble(text: []const u8, is_user: bool) zigui.View {
    const bg = if (is_user) t.colors.accent else t.colors.control_background;
    const fg = if (is_user) t.colors.on_accent else t.colors.label;
    const b = maxWidth(
        zigui.WrappedText(text)
            .foreground(fg)
            .paddingInsets(.{ .top = 8, .leading = 12, .bottom = 8, .trailing = 12 })
            .background(bg)
            .cornerRadius(14),
        420,
    );
    return if (is_user)
        zigui.HStack(.{ zigui.Spacer(), b }).frameMaxWidth()
    else
        zigui.HStack(.{ b, zigui.Spacer() }).frameMaxWidth();
}

fn sidebarRow(title: []const u8, active: bool) zigui.View {
    const fg = if (active) t.colors.on_accent else t.colors.label;
    var row = zigui.HStack(.{ zigui.Text(title).font(.subheadline).foreground(fg), zigui.Spacer() })
        .paddingInsets(.{ .top = 6, .leading = 8, .bottom = 6, .trailing = 8 })
        .cornerRadius(8)
        .frameMaxWidth();
    if (active) row = row.background(t.colors.accent);
    return row;
}

fn buildUI(input: *zigui.TextFieldState) zigui.View {
    const sidebar = zigui.VStack(.{
        leading(zigui.Text("CHATS").font(.caption2).foreground(t.colors.tertiary_label)),
        sidebarRow("Rewrite chat in Zig", true),
        sidebarRow("Weekend ideas", false),
        zigui.Spacer(),
    }).spacing(2)
        .paddingInsets(.{ .top = 12, .leading = 8, .bottom = 10, .trailing = 8 })
        .frameMaxWidth()
        .frameMaxHeight();

    const header = zigui.HStack(.{
        zigui.Text("Rewrite chat in Zig").font(.title3),
        zigui.Spacer(),
        zigui.Text("gemma-4-12b").font(.caption).foreground(t.colors.secondary_label),
        zigui.Circle(zigui.Color.fromRgb8(52, 199, 89)).frame(8, 8),
        zigui.components.ButtonRoled("Settings", .plain, noop()),
    }).spacing(10).paddingInsets(.{ .top = 10, .leading = 16, .bottom = 10, .trailing = 12 }).frameMaxWidth();

    const transcript = zigui.ScrollView(zigui.VStack(.{
        bubble("Can you rewrite the SwiftUI chat app in zigui?", true),
        zigui.VStack(.{
            bubble("Absolutely. We reuse the pure layout engine, add width-dependent WrappedText for bubbles, and stream tokens over SSE so the transcript fills in live.", false),
            leading(zigui.Text("96 tokens · 47 tok/s").font(.caption2).foreground(t.colors.tertiary_label)),
        }).spacing(3).frameMaxWidth(),
        bubble("Make it look like SwiftUI.", true),
        bubble("On it — accent bubbles on the right, a sidebar with a rounded selection highlight, and a pill input with a round send button.", false),
    }).spacing(12).padding(16).frameMaxWidth()).frameMaxWidth().frameMaxHeight();

    const send = zigui.ZStack(.{
        zigui.Circle(t.colors.accent).frame(34, 34),
        zigui.Text("↑").font(.headline).foreground(t.colors.on_accent),
    }).frame(34, 34);
    const input_bar = zigui.HStack(.{
        zigui.TextField("Message…", input).frameMaxWidth().frameHeight(38).cornerRadius(19),
        send,
    }).spacing(8).paddingInsets(.{ .top = 8, .leading = 12, .bottom = 10, .trailing = 12 }).frameMaxWidth();

    const detail = zigui.VStack(.{ header, zigui.Divider(), transcript, zigui.Divider(), input_bar })
        .frameMaxWidth()
        .frameMaxHeight();

    return zigui.NavigationSplitView(sidebar, detail, t.colors.secondary_background);
}

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

    const row = std.heap.page_allocator.alloc(u8, stride) catch return;
    defer std.heap.page_allocator.free(row);
    @memset(row, 0);
    var y: u32 = h;
    while (y > 0) {
        y -= 1; // BMP rows are bottom-up
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = fb.at(x, y).toRgba8();
            row[x * 3 + 0] = px.b;
            row[x * 3 + 1] = px.g;
            row[x * 3 + 2] = px.r;
        }
        _ = cstdio.fwrite(row.ptr, 1, stride, f);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var out: [:0]const u8 = "zigui-screenshot.bmp";
    var it = std.process.Args.iterate(init.args);
    _ = it.next(); // argv[0]
    while (it.next()) |a| out = a; // last positional arg = output path

    var input = zigui.TextFieldState.init(gpa);
    defer input.deinit();
    try input.setText("Anything else to add?");

    const w: u32 = 900;
    const h: u32 = 650;
    var font = zigui.Font.default();
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    zigui.beginBuild(arena.allocator());
    const root = buildUI(&input);
    zigui.endBuild();

    var hits: std.ArrayList(zigui.HitRegion) = .empty;
    var ctx = zigui.Context.init(t, &cache, arena.allocator(), &hits);
    var canvas = zigui.Canvas.init(arena.allocator());
    const full = zigui.Rect{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) };
    try canvas.fillRect(full, t.colors.window_background);
    try zigui.render(&ctx, root, full, &canvas);

    var fb = try zigui.Framebuffer.init(gpa, w, h);
    defer fb.deinit();
    fb.clear(t.colors.window_background);
    try zigui.raster.render(gpa, &fb, canvas.commands.items);
    writeBmp(out, &fb);
    std.debug.print("wrote {s} ({d}x{d})\n", .{ out, w, h });
}
