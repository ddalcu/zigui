//! A small-but-real plain-text editor built with zigui — in the spirit of
//! TextEdit / gedit / Notepad. It exercises the library's new multi-line
//! `TextEditor` component: line numbers, a caret you can click to position,
//! selection (Shift + arrows / ⌘A), and wheel + caret-follow scrolling.
//!
//! Features:
//!   • New / Open / Save / Save As (real file I/O via libc)
//!   • Find bar (⌘F) with Next / Prev and wrap-around, highlighting the match
//!   • Clipboard: ⌘C / ⌘X / ⌘V, Select-All ⌘A
//!   • Zoom: ⌘+ / ⌘- / ⌘0
//!   • A status bar: filename + "modified" dot, line/column, char & line counts
//!
//! Run with `zig build run-edit`, optionally passing a file to open:
//!     zig build run-edit -- /path/to/file.txt
//!
//! Headless UI iteration (no window), renders one frame to a BMP:
//!     zig build edit -Doptimize=ReleaseFast
//!     ./zig-out/bin/edit --screenshot /tmp/edit.bmp   # then: sips -s format png

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");

// File and (headless) screenshot I/O. std.fs needs the new std.Io model in Zig
// 0.16; libc is already linked into examples, so we use stdio directly — the
// same approach as examples/llm-chat.
const cstdio = @cImport({
    @cInclude("stdio.h");
});

/// The live theme, recomputed by `themeProvider` from the app state each frame
/// (so every view built this frame sees the same scheme). `g_app` lets the
/// provider read the appearance selection.
var g_theme = zigui.default_theme;

fn themeProvider() zigui.Theme {
    const st = g_app orelse return g_theme;
    // On the first frame (now that SDL is up), seed the appearance from the OS.
    if (!st.os_synced) {
        st.dark.set(app.systemTheme() == .dark);
        st.os_synced = true;
    }
    const scheme: zigui.ColorScheme = if (st.dark.get()) .dark else .light;
    g_theme = zigui.themeForScheme(.macos, scheme);
    return g_theme;
}

/// Shorthand for the live theme inside view builders / the screenshot path.
inline fn t() zigui.Theme {
    return g_theme;
}

// --- application state -------------------------------------------------------

const AppState = struct {
    gpa: std.mem.Allocator,

    /// The document buffer / caret / selection, and its vertical scroll.
    doc: zigui.TextFieldState,
    doc_scroll: zigui.ScrollState = .{},
    /// The on-disk path of the document ("" = a never-saved "Untitled").
    path: std.ArrayList(u8) = .empty,
    /// `doc.revision` at the last save/load, so dirtiness is a cheap compare.
    saved_revision: u64 = 0,

    line_numbers: zigui.State(bool),
    zoom: zigui.State(i64), // index into the font-size ladder; 3 == body

    /// Dark appearance, seeded from the OS preference on the first frame.
    dark: zigui.State(bool),
    /// Set once the appearance has been seeded from the OS (kept off in headless
    /// screenshots so they stay deterministic).
    os_synced: bool = false,

    // A single path-entry dialog, reused for Open and Save As (only one overlay
    // can be presented at a time, so `dialog_save` picks which it is).
    show_dialog: zigui.State(bool),
    dialog_save: bool = false,
    path_field: zigui.TextFieldState,

    // Find bar.
    show_find: zigui.State(bool),
    find_field: zigui.TextFieldState,

    // A transient status message (e.g. "Saved", "Not found").
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,

    fn isDirty(self: *const AppState) bool {
        return self.doc.revision != self.saved_revision;
    }
    fn name(self: *const AppState) []const u8 {
        const p = self.path.items;
        if (p.len == 0) return "Untitled";
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
        return p[slash + 1 ..];
    }
    fn status(self: *const AppState) []const u8 {
        return self.status_buf[0..self.status_len];
    }
    fn setStatus(self: *AppState, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, f, args) catch return;
        self.status_len = s.len;
    }
    fn setPath(self: *AppState, p: []const u8) void {
        self.path.clearRetainingCapacity();
        self.path.appendSlice(self.gpa, p) catch {};
    }
};

var g_app: ?*AppState = null;

// --- file I/O (libc) ---------------------------------------------------------

fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const cpath = try gpa.dupeZ(u8, path);
    defer gpa.free(cpath);
    const f = cstdio.fopen(cpath.ptr, "rb") orelse return error.OpenFailed;
    defer _ = cstdio.fclose(f);
    if (cstdio.fseek(f, 0, cstdio.SEEK_END) != 0) return error.ReadFailed;
    const n = cstdio.ftell(f);
    if (n < 0) return error.ReadFailed;
    if (cstdio.fseek(f, 0, cstdio.SEEK_SET) != 0) return error.ReadFailed;
    const size: usize = @intCast(n);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);
    if (size > 0 and cstdio.fread(buf.ptr, 1, size, f) != size) return error.ReadFailed;
    return buf;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const gpa = std.heap.page_allocator;
    const cpath = try gpa.dupeZ(u8, path);
    defer gpa.free(cpath);
    const f = cstdio.fopen(cpath.ptr, "wb") orelse return error.OpenFailed;
    defer _ = cstdio.fclose(f);
    if (data.len > 0 and cstdio.fwrite(data.ptr, 1, data.len, f) != data.len) return error.WriteFailed;
}

// --- file operations ---------------------------------------------------------

fn newDoc(st: *AppState) void {
    st.doc.setText("") catch {};
    st.doc.caret = 0;
    st.doc.last_caret = 0;
    st.path.clearRetainingCapacity();
    st.saved_revision = st.doc.revision;
    st.doc_scroll.offset = 0;
    zigui.setFocus(&st.doc);
    st.setStatus("New document", .{});
}

fn loadPath(st: *AppState, path: []const u8) void {
    const contents = readFileAlloc(st.gpa, path) catch {
        st.setStatus("Could not open '{s}'", .{path});
        return;
    };
    defer st.gpa.free(contents);
    st.doc.setText(contents) catch {
        st.setStatus("Out of memory loading file", .{});
        return;
    };
    st.doc.caret = 0; // start at the top, not the end (setText leaves caret at len)
    st.doc.last_caret = 0;
    st.doc_scroll.offset = 0;
    st.setPath(path);
    st.saved_revision = st.doc.revision;
    zigui.setFocus(&st.doc);
    st.setStatus("Opened {s} ({d} bytes)", .{ st.name(), contents.len });
}

fn openDialog(st: *AppState) void {
    st.dialog_save = false;
    st.path_field.setText(st.path.items) catch {};
    st.show_dialog.set(true);
    zigui.setFocus(&st.path_field);
}

fn doOpen(st: *AppState) void {
    const p = st.path_field.text();
    if (p.len == 0) return;
    // dup so loadPath's setText (which clears the doc) can't alias the field.
    const path = st.gpa.dupe(u8, p) catch return;
    defer st.gpa.free(path);
    st.show_dialog.set(false);
    loadPath(st, path);
}

fn save(st: *AppState) void {
    if (st.path.items.len == 0) {
        saveAsDialog(st);
        return;
    }
    writeFile(st.path.items, st.doc.text()) catch {
        st.setStatus("Save failed", .{});
        return;
    };
    st.saved_revision = st.doc.revision;
    st.setStatus("Saved {s}", .{st.name()});
}

fn saveAsDialog(st: *AppState) void {
    st.dialog_save = true;
    st.path_field.setText(st.path.items) catch {};
    st.show_dialog.set(true);
    zigui.setFocus(&st.path_field);
}

fn doSaveAs(st: *AppState) void {
    const p = st.path_field.text();
    if (p.len == 0) return;
    st.setPath(p);
    st.show_dialog.set(false);
    writeFile(st.path.items, st.doc.text()) catch {
        st.setStatus("Save failed", .{});
        return;
    };
    st.saved_revision = st.doc.revision;
    zigui.setFocus(&st.doc);
    st.setStatus("Saved {s}", .{st.name()});
}

/// The dialog's confirm action: dispatches to open or save-as by the mode flag.
fn confirmDialog(st: *AppState) void {
    if (st.dialog_save) doSaveAs(st) else doOpen(st);
}

fn cancelDialogs(st: *AppState) void {
    st.show_dialog.set(false);
    zigui.setFocus(&st.doc);
}

// --- find --------------------------------------------------------------------

fn toggleFind(st: *AppState) void {
    const showing = !st.show_find.get();
    st.show_find.set(showing);
    if (showing) zigui.setFocus(&st.find_field) else zigui.setFocus(&st.doc);
}

fn selectMatch(st: *AppState, i: usize, len: usize) void {
    st.doc.sel_anchor = i;
    st.doc.caret = i + len; // caret moves -> the editor auto-scrolls the match into view
    st.setStatus("Match at byte {d}", .{i});
}

fn findNext(st: *AppState) void {
    const needle = st.find_field.text();
    if (needle.len == 0) return;
    const hay = st.doc.text();
    // Continue past the current caret; wrap to the top if nothing follows.
    const from = @min(st.doc.caret, hay.len);
    const hit = std.mem.indexOfPos(u8, hay, from, needle) orelse std.mem.indexOf(u8, hay, needle);
    if (hit) |i| selectMatch(st, i, needle.len) else st.setStatus("Not found", .{});
}

fn findPrev(st: *AppState) void {
    const needle = st.find_field.text();
    if (needle.len == 0) return;
    const hay = st.doc.text();
    const sel = st.doc.selectionRange();
    const before = if (sel) |s| s.start else st.doc.caret;
    const hit = (if (before > 0) std.mem.lastIndexOf(u8, hay[0..before], needle) else null) orelse
        std.mem.lastIndexOf(u8, hay, needle);
    if (hit) |i| selectMatch(st, i, needle.len) else st.setStatus("Not found", .{});
}

// --- clipboard + zoom (driven by the app key handler) ------------------------

fn copySelection() void {
    const f = zigui.focusedField() orelse return;
    const r = f.selectionRange() orelse return;
    const z = std.heap.page_allocator.dupeZ(u8, f.text()[r.start..r.end]) catch return;
    defer std.heap.page_allocator.free(z);
    _ = app.c.SDL_SetClipboardText(z.ptr);
}
fn cutSelection() void {
    const f = zigui.focusedField() orelse return;
    copySelection();
    _ = f.deleteSelection();
}
fn pasteClipboard() void {
    const f = zigui.focusedField() orelse return;
    const ct = app.c.SDL_GetClipboardText();
    if (ct == null) return;
    defer app.c.SDL_free(ct);
    const s = std.mem.span(ct);
    if (s.len > 0) f.insert(s) catch {};
}
fn zoomBy(st: *AppState, delta: i64) void {
    st.zoom.set(std.math.clamp(st.zoom.get() + delta, 0, 6));
}

/// First-refusal key handler (registered with the runtime). Returns true to
/// consume the key (skipping the default text-field editing) for ⌘/Ctrl-based
/// app shortcuts.
fn keyHandler(key: u32, mods: u16) bool {
    const st = g_app orelse return false;
    const accel = (mods & (app.c.SDL_KMOD_GUI | app.c.SDL_KMOD_CTRL)) != 0;
    if (!accel) return false;
    switch (key) {
        's' => save(st),
        'o' => openDialog(st),
        'n' => newDoc(st),
        'f' => toggleFind(st),
        'a' => if (zigui.focusedField()) |f| f.selectAll(),
        'c' => copySelection(),
        'x' => cutSelection(),
        'v' => pasteClipboard(),
        '=', '+' => zoomBy(st, 1),
        '-' => zoomBy(st, -1),
        '0' => st.zoom.set(3),
        else => return false,
    }
    return true;
}

// --- view --------------------------------------------------------------------

/// Left-align a view in a full-width row (a bare `.frameMaxWidth()` centers).
fn leading(v: zigui.View) zigui.View {
    return zigui.HStack(.{ v, zigui.Spacer() }).frameMaxWidth();
}

/// Apply the current zoom level as a font token (a small size ladder).
fn zoomed(v: zigui.View, z: i64) zigui.View {
    return switch (z) {
        0 => v.font(.caption2),
        1 => v.font(.footnote),
        2 => v.font(.callout),
        4 => v.font(.headline),
        5 => v.font(.title3),
        6 => v.font(.title2),
        else => v.font(.body),
    };
}

fn toolbar(st: *AppState) zigui.View {
    const title = zigui.components.fmt("{s}{s}", .{ st.name(), if (st.isDirty()) " •" else "" });
    return zigui.HStack(.{
        zigui.Text(title).font(.headline),
        zigui.Spacer(),
        zigui.Toggle("Line numbers", st.line_numbers.binding()),
        zigui.components.ButtonRoled("New", .plain, zigui.actionCtx(AppState, st, newDoc)),
        zigui.components.ButtonRoled("Open", .plain, zigui.actionCtx(AppState, st, openDialog)),
        zigui.components.ButtonRoled("Save As", .plain, zigui.actionCtx(AppState, st, saveAsDialog)),
        zigui.Button("Save", zigui.actionCtx(AppState, st, save)),
    }).spacing(12)
        .paddingInsets(.{ .top = 9, .leading = 14, .bottom = 9, .trailing = 14 })
        .frameMaxWidth();
}

fn findBar(st: *AppState) zigui.View {
    return zigui.HStack(.{
        zigui.Text("Find").font(.subheadline).foreground(t().colors.secondary_label),
        zigui.TextField("Search…", &st.find_field)
            .frameMaxWidth()
            .onSubmit(zigui.actionCtx(AppState, st, findNext)),
        zigui.components.ButtonRoled("Prev", .plain, zigui.actionCtx(AppState, st, findPrev)),
        zigui.components.ButtonRoled("Next", .plain, zigui.actionCtx(AppState, st, findNext)),
        zigui.components.ButtonRoled("Done", .plain, zigui.actionCtx(AppState, st, toggleFind)),
    }).spacing(10)
        .paddingInsets(.{ .top = 7, .leading = 14, .bottom = 7, .trailing = 14 })
        .background(t().colors.secondary_background)
        .frameMaxWidth();
}

fn statusBar(st: *AppState) zigui.View {
    const text = st.doc.text();
    const lc = st.doc.lineCol();
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    const lines = std.mem.count(u8, text, "\n") + 1;
    const meta = zigui.components.fmt("Ln {d}, Col {d}    {d} chars    {d} lines", .{ lc.line, lc.col, chars, lines });
    return zigui.HStack(.{
        zigui.Text(meta).font(.footnote).foreground(t().colors.secondary_label),
        zigui.Spacer(),
        zigui.Text(st.status()).font(.footnote).foreground(t().colors.tertiary_label),
    }).spacing(14)
        .paddingInsets(.{ .top = 6, .leading = 14, .bottom = 6, .trailing = 14 })
        .frameMaxWidth();
}

fn dialogView(st: *AppState) zigui.View {
    const onConfirm = zigui.actionCtx(AppState, st, confirmDialog);
    return zigui.VStack(.{
        leading(zigui.Text(if (st.dialog_save) "Save As" else "Open").font(.title3)),
        leading(zigui.Text("File path:").font(.subheadline).foreground(t().colors.secondary_label)),
        zigui.TextField("/path/to/file.txt", &st.path_field)
            .frameMaxWidth()
            .onSubmit(onConfirm),
        zigui.HStack(.{
            zigui.Spacer(),
            zigui.components.ButtonRoled("Cancel", .plain, zigui.actionCtx(AppState, st, cancelDialogs)),
            zigui.Button(if (st.dialog_save) "Save" else "Open", onConfirm),
        }).frameMaxWidth(),
    }).spacing(14).padding(20).frameWidth(460);
}

fn body(st: *AppState) zigui.View {
    const editor = zoomed(zigui.TextEditor(&st.doc, &st.doc_scroll, st.line_numbers.get()), st.zoom.get())
        .frameMaxWidth()
        .frameMaxHeight()
        .paddingInsets(.{ .top = 8, .leading = 10, .bottom = 8, .trailing = 10 });

    // Assemble the main column, splicing in the find bar only when visible.
    var rows: [6]zigui.View = undefined;
    var n: usize = 0;
    rows[n] = toolbar(st);
    n += 1;
    rows[n] = zigui.Divider();
    n += 1;
    rows[n] = editor;
    n += 1;
    if (st.show_find.get()) {
        rows[n] = findBar(st);
        n += 1;
    }
    rows[n] = zigui.Divider();
    n += 1;
    rows[n] = statusBar(st);
    n += 1;

    return zigui.VStack(rows[0..n])
        .spacing(0)
        .frameMaxWidth()
        .frameMaxHeight()
        .alert(st.show_dialog.binding(), dialogView(st));
}

// --- headless screenshot (dev tool) -----------------------------------------

const sample_doc =
    \\// edit.zig — a zigui text editor
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    const greeting = "Hello, zigui!";
    \\    std.debug.print("{s}\n", .{greeting});
    \\
    \\    // Click to place the caret, drag to select (or Shift+arrows),
    \\    // ⌘F to find, ⌘S to save.
    \\    var total: usize = 0;
    \\    for (0..10) |i| total += i;
    \\}
;

fn renderScreenshot(gpa: std.mem.Allocator, st: *AppState, path: [:0]const u8, drag: bool) !void {
    const w: u32 = 880;
    const h: u32 = 600;
    var font = zigui.Font.default();
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const full = zigui.Rect{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) };

    var hits: std.ArrayList(zigui.HitRegion) = .empty;
    var overlays: std.ArrayList(zigui.OverlayReq) = .empty;
    var scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;
    var canvas = zigui.Canvas.init(arena);

    // A render pass: rebuild the tree, lay out, and paint (collecting hit regions).
    const pass = struct {
        fn run(a: std.mem.Allocator, s: *AppState, ca: *zigui.Canvas, ce: *zigui.GlyphCache, hh: *std.ArrayList(zigui.HitRegion), oo: *std.ArrayList(zigui.OverlayReq), ss: *std.ArrayList(zigui.ScrollRegion), rect: zigui.Rect) !void {
            hh.clearRetainingCapacity();
            oo.clearRetainingCapacity();
            ss.clearRetainingCapacity();
            ca.clearCommands();
            zigui.beginBuild(a);
            const root = body(s);
            zigui.endBuild();
            var ctx = zigui.Context.initFull(t(), ce, a, hh, oo, null);
            ctx.scroll_regions = ss;
            try ca.fillRect(rect, t().colors.window_background);
            try zigui.render(&ctx, root, rect, ca);
        }
    }.run;

    try pass(arena, st, &canvas, &cache, &hits, &overlays, &scrolls, full);

    // Simulate a real mouse drag through the collected hit regions, then re-render
    // so the screenshot shows what the dispatched selection actually produces.
    if (drag) {
        const lh = zigui.shape.lineHeight(&font.face, t().typography.body.size);
        _ = zigui.dispatchTap(hits.items, .{ .x = 70, .y = 8 + 4 * lh + 2 }); // press on line 5
        zigui.dispatchDrag(hits.items, .{ .x = 250, .y = 8 + 7 * lh + 2 }); // drag to line 8
        zigui.endDrag();
        try pass(arena, st, &canvas, &cache, &hits, &overlays, &scrolls, full);
    }

    var fb = try zigui.Framebuffer.init(gpa, w, h);
    defer fb.deinit();
    fb.clear(t().colors.window_background);
    try zigui.raster.render(gpa, &fb, canvas.commands.items);
    writeBmp(path, &fb);
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
        y -= 1; // BMP rows are stored bottom-up
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

// --- entry point -------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    var st = AppState{
        .gpa = gpa,
        .doc = zigui.TextFieldState.init(gpa),
        .line_numbers = zigui.State(bool).init(gpa, true),
        .zoom = zigui.State(i64).init(gpa, 3),
        .dark = zigui.State(bool).init(gpa, false),
        .show_dialog = zigui.State(bool).init(gpa, false),
        .path_field = zigui.TextFieldState.init(gpa),
        .show_find = zigui.State(bool).init(gpa, false),
        .find_field = zigui.TextFieldState.init(gpa),
    };
    defer {
        st.doc.deinit();
        st.path.deinit(gpa);
        st.line_numbers.deinit();
        st.zoom.deinit();
        st.dark.deinit();
        st.show_dialog.deinit();
        st.path_field.deinit();
        st.show_find.deinit();
        st.find_field.deinit();
    }
    st.doc.multiline = true;
    st.setStatus("Ready", .{});
    g_app = &st;

    // Args: an optional file to open, and a headless --screenshot <path>.
    var open_path: ?[]const u8 = null;
    var screenshot_path: ?[:0]const u8 = null;
    var demo_find = false;
    var demo_dialog = false;
    var demo_select = false;
    var demo_drag = false;
    var force_dark = false;
    var arg_it = try std.process.Args.iterateAllocator(init.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // argv[0]
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--screenshot")) {
            if (arg_it.next()) |p| screenshot_path = p;
        } else if (std.mem.eql(u8, a, "--demo-find")) {
            demo_find = true;
        } else if (std.mem.eql(u8, a, "--demo-dialog")) {
            demo_dialog = true;
        } else if (std.mem.eql(u8, a, "--demo-select")) {
            demo_select = true;
        } else if (std.mem.eql(u8, a, "--demo-drag")) {
            demo_drag = true;
        } else if (std.mem.eql(u8, a, "--dark")) {
            force_dark = true;
        } else if (!std.mem.startsWith(u8, a, "-")) {
            open_path = a;
        }
    }

    if (open_path) |p| loadPath(&st, p);

    if (screenshot_path) |path| {
        // Deterministic theme: honor --dark, never probe the OS when headless.
        st.dark.set(force_dark);
        st.os_synced = true;
        _ = themeProvider();
        if (st.doc.text().len == 0) {
            st.doc.setText(sample_doc) catch {};
            st.doc.caret = 0;
            st.doc.last_caret = 0;
            st.saved_revision = st.doc.revision;
        }
        zigui.setFocus(&st.doc);
        if (demo_find) {
            st.show_find.set(true);
            st.find_field.setText("greeting") catch {};
            findNext(&st);
        }
        if (demo_dialog) openDialog(&st);
        if (demo_select) {
            // Select from the middle of line 4 down into line 6 (a multi-line span).
            const txt = st.doc.text();
            const l3 = std.mem.indexOf(u8, txt, "const greeting") orelse 0;
            const l6 = std.mem.indexOf(u8, txt, "// Click") orelse txt.len;
            st.doc.sel_anchor = l3;
            st.doc.caret = l6;
        }
        renderScreenshot(gpa, &st, path, demo_drag) catch |e| std.debug.print("screenshot failed: {s}\n", .{@errorName(e)});
        return;
    }

    app.setKeyHandler(&keyHandler);
    app.setThemeProvider(themeProvider); // follow the OS dark/light appearance
    zigui.setFocus(&st.doc); // ready to type immediately

    try app.run(gpa, AppState, &st, .{
        .title = "zigui — Editor",
        .width = 880,
        .height = 600,
    }, body);
}
