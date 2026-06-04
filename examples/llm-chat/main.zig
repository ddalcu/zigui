//! A streaming LLM chat client built with zigui, talking to an OpenAI-compatible
//! `/v1/chat/completions` endpoint (default: mlx-serve at http://127.0.0.1:11234).
//!
//! Run the server first, e.g.:
//!     mlx-serve --serve --model <model> --port 11234
//! then `zig build run-llm-chat`. Set the server URL, model, temperature, and
//! system prompt in the Settings sheet (gear button).
//!
//! The networking lives in the sibling `chat_client.zig`. It is single-threaded
//! and non-blocking: `body` calls `client.poll()` once per frame while a request
//! is streaming (the busy-poll hook keeps the loop awake), so all state stays on
//! the UI thread — no threads, no locks.
//!
//! Headless smoke test (no window), to prove connectivity end-to-end:
//!     zig build llm-chat && ./zig-out/bin/llm-chat --smoke "say hi in one word"
//! optionally with `--url <url>` and `--model <name>`.

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");
const chat = @import("chat_client.zig");

// Used only by the headless `--screenshot` dev mode to write a BMP (std.fs needs
// the new std.Io model in Zig 0.16; libc is already linked).
const cstdio = @cImport({
    @cInclude("stdio.h");
});

const t = zigui.default_theme;

const default_url = "http://127.0.0.1:11234";
const default_model = "local-model";
const default_system = "You are a helpful assistant.";

// --- model ------------------------------------------------------------------

const Role = enum {
    system,
    user,
    assistant,

    fn wire(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

/// One chat message. Heap-allocated (the transcript holds `*Message`) so its
/// `content` buffer address is stable while the client streams into it, even as
/// the transcript array grows.
const Message = struct {
    role: Role,
    content: std.ArrayList(u8) = .empty,
    streaming: bool = false,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    tps: f32 = 0,

    fn create(gpa: std.mem.Allocator, role: Role) !*Message {
        const m = try gpa.create(Message);
        m.* = .{ .role = role };
        return m;
    }
    fn destroy(m: *Message, gpa: std.mem.Allocator) void {
        m.content.deinit(gpa);
        gpa.destroy(m);
    }
};

const Session = struct {
    title: std.ArrayList(u8) = .empty,
    messages: std.ArrayList(*Message) = .empty,

    fn create(gpa: std.mem.Allocator, title: []const u8) !*Session {
        const s = try gpa.create(Session);
        s.* = .{};
        try s.title.appendSlice(gpa, title);
        return s;
    }
    fn destroy(s: *Session, gpa: std.mem.Allocator) void {
        for (s.messages.items) |m| m.destroy(gpa);
        s.messages.deinit(gpa);
        s.title.deinit(gpa);
        gpa.destroy(s);
    }
};

const AppState = struct {
    gpa: std.mem.Allocator,
    sessions: std.ArrayList(*Session) = .empty,
    active: usize = 0,

    input: zigui.TextFieldState,
    scroll: zigui.ScrollState = .{},
    show_settings: zigui.State(bool),

    server_url: zigui.TextFieldState,
    model: zigui.TextFieldState,
    system_prompt: zigui.TextFieldState,
    temperature: zigui.State(f32),

    client: chat.ChatClient,
    status: bool = false, // last /health result (drives the dot)
    was_streaming: bool = false,
    pending: ?*Message = null, // assistant message currently being streamed

    // A per-frame arena for callback contexts bound to row indices (mirrors the
    // library's build-arena lifetime: valid until the next `body`).
    frame_arena: std.heap.ArenaAllocator,

    fn activeSession(st: *AppState) ?*Session {
        if (st.active >= st.sessions.items.len) return null;
        return st.sessions.items[st.active];
    }

    fn newChat(st: *AppState) void {
        const s = Session.create(st.gpa, "New Chat") catch return;
        st.sessions.append(st.gpa, s) catch return;
        st.active = st.sessions.items.len - 1;
        st.scroll.offset = 0;
    }

    fn deleteSessionAt(st: *AppState, index: usize) void {
        if (index >= st.sessions.items.len) return;
        st.client.cancel(); // an in-flight stream may target this session
        st.pending = null;
        st.was_streaming = false;
        const s = st.sessions.orderedRemove(index);
        s.destroy(st.gpa);
        if (st.sessions.items.len == 0) {
            const s0 = Session.create(st.gpa, "New Chat") catch return;
            st.sessions.append(st.gpa, s0) catch return;
        }
        if (st.active >= st.sessions.items.len) st.active = st.sessions.items.len - 1;
    }

    /// Append the user's message + an empty assistant placeholder, assemble the
    /// OpenAI `messages` array (system prompt + history), and start streaming.
    fn send(st: *AppState) void {
        if (st.client.isStreaming()) return;
        const text = st.input.text();
        if (text.len == 0) return;
        const sess = st.activeSession() orelse return;

        const um = Message.create(st.gpa, .user) catch return;
        um.content.appendSlice(st.gpa, text) catch {};
        sess.messages.append(st.gpa, um) catch return;

        // Title a fresh chat from its first user message.
        if (sess.messages.items.len == 1) {
            sess.title.clearRetainingCapacity();
            sess.title.appendSlice(st.gpa, text[0..@min(text.len, 28)]) catch {};
        }

        const am = Message.create(st.gpa, .assistant) catch return;
        am.streaming = true;
        sess.messages.append(st.gpa, am) catch return;
        st.pending = am;

        var wire: std.ArrayList(chat.WireMessage) = .empty;
        defer wire.deinit(st.gpa);
        if (st.system_prompt.text().len > 0) {
            wire.append(st.gpa, .{ .role = "system", .content = st.system_prompt.text() }) catch {};
        }
        for (sess.messages.items) |m| {
            if (m == am) continue; // skip the empty placeholder
            wire.append(st.gpa, .{ .role = m.role.wire(), .content = m.content.items }) catch {};
        }

        const params = chat.Params{
            .model = st.model.text(),
            .temperature = st.temperature.get(),
            .max_tokens = 1024,
        };
        st.status = chat.checkHealth(st.server_url.text());
        st.client.start(st.server_url.text(), &am.content, wire.items, params);
        st.was_streaming = st.client.isStreaming();
        st.input.setText("") catch {};
        st.scroll.offset = 1_000_000; // pin to bottom (clamped during paint)
    }

    fn stop(st: *AppState) void {
        st.client.cancel();
        if (st.pending) |am| am.streaming = false;
        st.pending = null;
        st.was_streaming = false;
    }
};

// --- callbacks bound to a session row index ---------------------------------

const RowCtx = struct { st: *AppState, index: usize };

fn rowCtx(st: *AppState, index: usize) *RowCtx {
    const cx = st.frame_arena.allocator().create(RowCtx) catch unreachable;
    cx.* = .{ .st = st, .index = index };
    return cx;
}
fn onSelectRow(p: ?*anyopaque) void {
    const cx: *RowCtx = @ptrCast(@alignCast(p.?));
    cx.st.active = cx.index;
    cx.st.scroll.offset = 1_000_000;
}
fn onDeleteRow(p: ?*anyopaque) void {
    const cx: *RowCtx = @ptrCast(@alignCast(p.?));
    cx.st.deleteSessionAt(cx.index);
}

// --- views ------------------------------------------------------------------

/// Cap a view's width to `w` points (keeps chat bubbles from spanning the pane).
fn maxWidth(v: zigui.View, w: f32) zigui.View {
    var out = v;
    var f = out.mods.frame orelse zigui.view.FrameSpec{};
    f.max_width = w;
    out.mods.frame = f;
    return out;
}

const bubble_max: f32 = 520;

/// macOS "system green" for the healthy status dot.
fn statusGreen() zigui.Color {
    return zigui.Color.fromRgb8(52, 199, 89);
}

/// Wrap `v` so it sits on the leading edge of a full-width row (the frame layout
/// centers by default, so a trailing Spacer is how you left-align).
fn leading(v: zigui.View) zigui.View {
    return zigui.HStack(.{ v, zigui.Spacer() }).frameMaxWidth();
}

/// A single chat bubble: user messages on the accent on the right, assistant
/// messages in the control color on the left (corner radius 14, 12×8 padding),
/// with an optional tokens/sec caption under finished assistant replies.
fn bubbleView(msg: *Message) zigui.View {
    const is_user = msg.role == .user;
    const bg = if (is_user) t.colors.accent else t.colors.control_background;
    const fg = if (is_user) t.colors.on_accent else t.colors.label;
    // A trailing ellipsis hints "still generating" while streaming.
    const shown = if (msg.streaming)
        zigui.components.fmt("{s}…", .{msg.content.items})
    else
        msg.content.items;

    const bubble = maxWidth(
        zigui.WrappedText(shown)
            .foreground(fg)
            .paddingInsets(.{ .top = 8, .leading = 12, .bottom = 8, .trailing = 12 })
            .background(bg)
            .cornerRadius(14),
        bubble_max,
    );

    const row = if (is_user)
        zigui.HStack(.{ zigui.Spacer(), bubble }).frameMaxWidth()
    else
        zigui.HStack(.{ bubble, zigui.Spacer() }).frameMaxWidth();

    if (!is_user and !msg.streaming and msg.completion_tokens > 0) {
        const cap = zigui.Text(zigui.components.fmt("{d} tokens · {d:.0} tok/s", .{ msg.completion_tokens, msg.tps }))
            .font(.caption2)
            .foreground(t.colors.tertiary_label);
        return zigui.VStack(.{
            row,
            leading(cap.paddingInsets(.{ .leading = 2, .top = 0, .bottom = 0, .trailing = 0 })),
        }).spacing(3).frameMaxWidth();
    }
    return row;
}

/// A sidebar chat row: leading title, a rounded accent fill when selected, and a
/// subtle trailing delete affordance. Built as siblings (not a wrapping button)
/// so the title taps select and the "×" taps delete without overlap.
fn sidebarRow(st: *AppState, i: usize, title: []const u8, active: bool) zigui.View {
    const fg = if (active) t.colors.on_accent else t.colors.label;
    const del_color = if (active) t.colors.on_accent.withAlpha(0.7) else t.colors.tertiary_label;
    const title_area = zigui.HStack(.{
        zigui.Text(title).font(.subheadline).foreground(fg),
        zigui.Spacer(),
    }).frameMaxWidth().onTap(.{ .ctx = rowCtx(st, i), .func = onSelectRow });
    const del = zigui.Text("×").foreground(del_color).onTap(.{ .ctx = rowCtx(st, i), .func = onDeleteRow });

    var row = zigui.HStack(.{ title_area, del })
        .spacing(6)
        .paddingInsets(.{ .top = 6, .leading = 8, .bottom = 6, .trailing = 8 })
        .cornerRadius(8)
        .frameMaxWidth();
    if (active) row = row.background(t.colors.accent);
    return row;
}

/// A subtle, full-width bordered button (macOS `.bordered` style).
fn borderedButton(label: []const u8, cb: zigui.Callback) zigui.View {
    return zigui.HStack(.{ zigui.Spacer(), zigui.Text(label).foreground(t.colors.accent), zigui.Spacer() })
        .paddingInsets(.{ .top = 7, .leading = 10, .bottom = 7, .trailing = 10 })
        .background(t.colors.control_background)
        .cornerRadius(8)
        .border(t.colors.separator, t.metrics.hairline)
        .onTap(cb)
        .frameMaxWidth();
}

fn sidebarView(st: *AppState) zigui.View {
    const fa = st.frame_arena.allocator();
    var rows: std.ArrayList(zigui.View) = .empty;
    rows.append(fa, leading(zigui.Text("CHATS").font(.caption2).foreground(t.colors.tertiary_label))
        .paddingInsets(.{ .top = 2, .leading = 8, .bottom = 4, .trailing = 8 })) catch {};

    for (st.sessions.items, 0..) |s, i| {
        const title = if (s.title.items.len == 0) "New Chat" else s.title.items;
        rows.append(fa, sidebarRow(st, i, title, i == st.active)) catch {};
    }

    rows.append(fa, zigui.Spacer()) catch {};
    rows.append(fa, borderedButton("+  New Chat", zigui.actionCtx(AppState, st, AppState.newChat))) catch {};
    return zigui.VStack(rows.items)
        .spacing(2)
        .paddingInsets(.{ .top = 12, .leading = 8, .bottom = 10, .trailing = 8 })
        .frameMaxWidth()
        .frameMaxHeight();
}

/// The circular send / stop button (accent up-arrow, or red stop while streaming).
fn sendButton(st: *AppState) zigui.View {
    const streaming = st.client.isStreaming();
    const cb = if (streaming)
        zigui.actionCtx(AppState, st, AppState.stop)
    else
        zigui.actionCtx(AppState, st, AppState.send);
    const fill = if (streaming) t.colors.destructive else t.colors.accent;
    const glyph: []const u8 = if (streaming) "■" else "↑";
    return zigui.ZStack(.{
        zigui.Circle(fill).frame(34, 34),
        zigui.Text(glyph).font(.headline).foreground(t.colors.on_accent),
    }).frame(34, 34).onTap(cb);
}

fn detailView(st: *AppState) zigui.View {
    const sess = st.activeSession();
    const title = if (sess) |s| (if (s.title.items.len == 0) "New Chat" else s.title.items) else "Chat";

    const dot_color = if (st.status) statusGreen() else t.colors.destructive;
    const header = zigui.HStack(.{
        zigui.Text(title).font(.title3),
        zigui.Spacer(),
        zigui.Text(st.model.text()).font(.caption).foreground(t.colors.secondary_label),
        zigui.Circle(dot_color).frame(8, 8),
        zigui.components.ButtonRoled("Settings", .plain, zigui.actionCtx(AppState, st, showSettings)),
    }).spacing(10).paddingInsets(.{ .top = 10, .leading = 16, .bottom = 10, .trailing = 12 }).frameMaxWidth();

    // Transcript.
    var bubbles: zigui.View = zigui.Spacer();
    if (sess) |s| {
        bubbles = zigui.VStack(.{zigui.ForEach(s.messages.items, bubbleView)})
            .spacing(12)
            .padding(16)
            .frameMaxWidth();
    }
    const transcript = zigui.ScrollViewState(&st.scroll, bubbles)
        .frameMaxWidth()
        .frameMaxHeight();

    // Input bar: a pill-shaped field + circular send button.
    const input_field = zigui.TextField("Message…", &st.input)
        .onSubmit(zigui.actionCtx(AppState, st, AppState.send))
        .frameMaxWidth()
        .frameHeight(38)
        .cornerRadius(19);
    const input_bar = zigui.HStack(.{ input_field, sendButton(st) })
        .spacing(8)
        .paddingInsets(.{ .top = 8, .leading = 12, .bottom = 10, .trailing = 12 })
        .frameMaxWidth();

    return zigui.VStack(.{
        header,
        zigui.Divider(),
        transcript,
        zigui.Divider(),
        input_bar,
    }).frameMaxWidth().frameMaxHeight();
}

fn showSettings(st: *AppState) void {
    st.show_settings.set(true);
}
fn hideSettings(st: *AppState) void {
    st.show_settings.set(false);
}

fn field(label: []const u8, control: zigui.View) zigui.View {
    return zigui.VStack(.{
        leading(zigui.Text(label).font(.subheadline).foreground(t.colors.secondary_label)),
        control.frameMaxWidth(),
    }).spacing(5).frameMaxWidth();
}

fn settingsForm(st: *AppState) zigui.View {
    // A grouped "card" section like macOS settings.
    const card = zigui.VStack(.{
        field("Server URL", zigui.TextField(default_url, &st.server_url)),
        field("Model", zigui.TextField(default_model, &st.model)),
        field(
            zigui.components.fmt("Temperature: {d:.2}", .{st.temperature.get()}),
            zigui.Slider(st.temperature.binding(), 0, 2),
        ),
        field("System Prompt", zigui.TextField("System prompt", &st.system_prompt)),
    }).spacing(14)
        .padding(16)
        .background(t.colors.secondary_background)
        .cornerRadius(10)
        .border(t.colors.separator, t.metrics.hairline)
        .frameMaxWidth();

    return zigui.VStack(.{
        leading(zigui.Text("Settings").font(.title3)),
        card,
        zigui.HStack(.{
            zigui.Spacer(),
            zigui.Button("Done", zigui.actionCtx(AppState, st, hideSettings)),
        }).frameMaxWidth(),
    }).spacing(16).padding(20).frameWidth(440);
}

fn body(st: *AppState) zigui.View {
    _ = st.frame_arena.reset(.retain_capacity);

    // Pump the streaming socket. Pin to the bottom while following a live reply.
    const was_at_bottom = st.scroll.atBottom();
    _ = st.client.poll();
    if (st.client.isStreaming() and was_at_bottom) st.scroll.offset = 1_000_000;

    // Detect stream completion: finalize the assistant bubble + refresh status.
    const streaming_now = st.client.isStreaming();
    if (st.was_streaming and !streaming_now) {
        if (st.pending) |am| {
            am.streaming = false;
            am.prompt_tokens = st.client.usage.prompt_tokens;
            am.completion_tokens = st.client.usage.completion_tokens;
            const elapsed = @as(f32, @floatFromInt(st.client.elapsed_ms)) / 1000.0;
            am.tps = if (elapsed > 0) @as(f32, @floatFromInt(am.completion_tokens)) / elapsed else 0;
            st.pending = null;
        }
        st.status = chat.checkHealth(st.server_url.text());
        st.was_streaming = false;
    }

    // Keep the tray dot in sync with the server status.
    if (st.status != g_tray_status) {
        g_tray_status = st.status;
        refreshTrayIcon(st.gpa, st.status);
    }

    return zigui.NavigationSplitView(sidebarView(st), detailView(st), t.colors.secondary_background)
        .alert(st.show_settings.binding(), settingsForm(st));
}

// --- busy-poll hook ---------------------------------------------------------

var g_app: ?*AppState = null;
fn busyCheck() bool {
    return if (g_app) |a| a.client.isStreaming() else false;
}

// --- entry point ------------------------------------------------------------

fn runSmoke(gpa: std.mem.Allocator, url: []const u8, model: []const u8, prompt: []const u8) void {
    var client = chat.ChatClient.init(gpa);
    defer client.deinit();
    const messages = [_]chat.WireMessage{.{ .role = "user", .content = prompt }};
    const params = chat.Params{ .model = model, .temperature = 0.7, .max_tokens = 256 };
    const reply = client.request(url, &messages, params) catch |err| {
        std.debug.print("smoke: request to {s} failed: {s} — is mlx-serve running?\n", .{ url, @errorName(err) });
        return;
    };
    defer gpa.free(reply);
    std.debug.print("{s}\n", .{reply});
}

/// Headless exercise of the streaming SSE path (the GUI's primary path): start a
/// stream and pump `poll()` to EOF, printing the accumulated reply. Mirrors what
/// `body` does each frame, minus the window.
fn runStreamSmoke(gpa: std.mem.Allocator, url: []const u8, model: []const u8, prompt: []const u8) void {
    var client = chat.ChatClient.init(gpa);
    defer client.deinit();
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    const messages = [_]chat.WireMessage{.{ .role = "user", .content = prompt }};
    const params = chat.Params{ .model = model, .temperature = 0.7, .max_tokens = 256 };

    client.start(url, &content, messages[0..], params);
    var spins: usize = 0;
    while (client.isStreaming() and spins < 100_000) : (spins += 1) {
        _ = client.poll();
        chat.sleepMs(8);
    }
    std.debug.print("{s}\n", .{content.items});
    std.debug.print("[stream: {d} completion tokens, {d} ms]\n", .{ client.usage.completion_tokens, client.elapsed_ms });
}

// --- headless screenshot (dev tool) -----------------------------------------
// Renders one frame of the real `body` to a BMP without opening a window, so the
// UI can be inspected/iterated on headlessly:
//     zig build llm-chat -Doptimize=ReleaseFast
//     ./zig-out/bin/llm-chat --screenshot /tmp/chat.bmp
// then convert with `sips -s format png`.

fn addMockMsg(s: *Session, gpa: std.mem.Allocator, role: Role, text: []const u8) *Message {
    const m = Message.create(gpa, role) catch unreachable;
    m.content.appendSlice(gpa, text) catch {};
    s.messages.append(gpa, m) catch {};
    return m;
}

fn populateMock(st: *AppState) void {
    const gpa = st.gpa;
    const s = st.sessions.items[0];
    s.title.clearRetainingCapacity();
    s.title.appendSlice(gpa, "Rewrite chat in Zig") catch {};
    _ = addMockMsg(s, gpa, .user, "Can you rewrite the SwiftUI chat app in zigui?");
    const a1 = addMockMsg(s, gpa, .assistant, "Absolutely. We reuse the pure layout engine, add width-dependent WrappedText for bubbles, and stream tokens over SSE so the transcript fills in live. Bubbles word-wrap to the pane and pin to the bottom while generating.");
    a1.completion_tokens = 96;
    a1.tps = 47.3;
    _ = addMockMsg(s, gpa, .user, "Make it look like SwiftUI.");
    const a2 = addMockMsg(s, gpa, .assistant, "On it — accent bubbles on the right, a sidebar with a rounded selection highlight, and a pill-shaped input with a round send button.");
    a2.completion_tokens = 38;
    a2.tps = 44.1;
    st.sessions.append(gpa, Session.create(gpa, "Weekend ideas") catch return) catch {};
    st.status = true;
}

fn renderScreenshot(gpa: std.mem.Allocator, st: *AppState, path: [:0]const u8) !void {
    const w: u32 = 900;
    const h: u32 = 650;
    var font = zigui.Font.default();
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    zigui.beginBuild(arena);
    const root = body(st);
    zigui.endBuild();

    var hits: std.ArrayList(zigui.HitRegion) = .empty;
    var overlays: std.ArrayList(zigui.OverlayReq) = .empty;
    var scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;
    var ctx = zigui.Context.initFull(t, &cache, arena, &hits, &overlays, null);
    ctx.scroll_regions = &scrolls;

    var canvas = zigui.Canvas.init(arena);
    const full = zigui.Rect{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) };
    try canvas.fillRect(full, t.colors.window_background);
    try zigui.render(&ctx, root, full, &canvas);

    var fb = try zigui.Framebuffer.init(gpa, w, h);
    defer fb.deinit();
    fb.clear(t.colors.window_background);
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

// --- system tray -------------------------------------------------------------
// A menu-bar / tray icon whose dot mirrors the server `/health` status, plus a
// menu (Open / New Chat / Settings / Quit). The icon is drawn with zigui's own
// rasterizer and handed to SDL as RGBA pixels. Built once at startup (the tray
// is retained/imperative, not part of the per-frame view tree).

const tray_icon_px: u32 = 22;
var g_tray: ?app.Tray = null;
var g_tray_status: bool = false;

/// Rasterize a filled status dot to RGBA (transparent background) using the same
/// pipeline that draws the window — the synergy that makes a zigui-drawn tray
/// icon trivial.
fn statusIconRGBA(gpa: std.mem.Allocator, size: u32, color: zigui.Color) ![]u8 {
    var canvas = zigui.Canvas.init(gpa);
    defer canvas.deinit();
    const s: f32 = @floatFromInt(size);
    try canvas.fillCircle(.{ .x = s / 2, .y = s / 2 }, s / 2 - 2, color);
    var fb = try zigui.Framebuffer.init(gpa, size, size);
    defer fb.deinit();
    fb.clear(zigui.Color.transparent);
    try zigui.raster.render(gpa, &fb, canvas.commands.items);
    return fb.toRgba8Alloc(gpa);
}

fn refreshTrayIcon(gpa: std.mem.Allocator, up: bool) void {
    if (g_tray) |*tr| {
        const px = statusIconRGBA(gpa, tray_icon_px, if (up) statusGreen() else t.colors.destructive) catch return;
        defer gpa.free(px);
        tr.setIcon(px, @intCast(tray_icon_px), @intCast(tray_icon_px));
    }
}

fn openSettingsFromTray(st: *AppState) void {
    st.show_settings.set(true);
    app.showWindow();
}

fn setupTray(gpa: std.mem.Allocator, st: *AppState) void {
    const px = statusIconRGBA(gpa, tray_icon_px, if (st.status) statusGreen() else t.colors.destructive) catch return;
    defer gpa.free(px);
    const created = app.Tray.create(gpa, px, @intCast(tray_icon_px), @intCast(tray_icon_px), "zigui — LLM Chat") catch return;
    g_tray = created;
    g_tray_status = st.status;
    const m = g_tray.?.menu();
    m.addItem("Open", zigui.action(app.showWindow));
    m.addItem("New Chat", zigui.actionCtx(AppState, st, AppState.newChat));
    m.addItem("Settings", zigui.actionCtx(AppState, st, openSettingsFromTray));
    m.addSeparator();
    m.addItem("Quit", zigui.action(app.quit));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.page_allocator;

    // Args: --smoke "<prompt>", --url <url>, --model <name>. (Zig 0.16 passes
    // them via the entry-point `Init.Minimal`.)
    var smoke_prompt: ?[]const u8 = null;
    var url: []const u8 = default_url;
    var model: []const u8 = default_model;
    var stream = false;
    var screenshot_path: ?[:0]const u8 = null;
    var open_settings = false;
    // iterateAllocator (not iterate): the simple iterator @compileErrors on
    // Windows, where argv must be decoded from the WTF-16 command line.
    var arg_it = try std.process.Args.iterateAllocator(init.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip argv[0]
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--smoke")) {
            if (arg_it.next()) |p| smoke_prompt = p;
        } else if (std.mem.eql(u8, a, "--url")) {
            if (arg_it.next()) |u| url = u;
        } else if (std.mem.eql(u8, a, "--model")) {
            if (arg_it.next()) |m| model = m;
        } else if (std.mem.eql(u8, a, "--stream")) {
            stream = true;
        } else if (std.mem.eql(u8, a, "--screenshot")) {
            if (arg_it.next()) |p| screenshot_path = p;
        } else if (std.mem.eql(u8, a, "--settings")) {
            open_settings = true;
        }
    }

    if (smoke_prompt) |p| {
        if (stream) runStreamSmoke(gpa, url, model, p) else runSmoke(gpa, url, model, p);
        return;
    }

    var st = AppState{
        .gpa = gpa,
        .input = zigui.TextFieldState.init(gpa),
        .show_settings = zigui.State(bool).init(gpa, false),
        .server_url = zigui.TextFieldState.init(gpa),
        .model = zigui.TextFieldState.init(gpa),
        .system_prompt = zigui.TextFieldState.init(gpa),
        .temperature = zigui.State(f32).init(gpa, 0.7),
        .client = chat.ChatClient.init(gpa),
        .frame_arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer {
        for (st.sessions.items) |s| s.destroy(gpa);
        st.sessions.deinit(gpa);
        st.input.deinit();
        st.show_settings.deinit();
        st.server_url.deinit();
        st.model.deinit();
        st.system_prompt.deinit();
        st.temperature.deinit();
        st.client.deinit();
        st.frame_arena.deinit();
    }
    try st.server_url.setText(url);
    try st.model.setText(model);
    try st.system_prompt.setText(default_system);
    st.sessions.append(gpa, try Session.create(gpa, "New Chat")) catch {};

    if (screenshot_path) |path| {
        populateMock(&st);
        if (open_settings) st.show_settings.set(true);
        renderScreenshot(gpa, &st, path) catch |e| std.debug.print("screenshot failed: {s}\n", .{@errorName(e)});
        return;
    }

    st.status = chat.checkHealth(st.server_url.text());
    g_app = &st;
    app.setBusyCheck(&busyCheck);

    setupTray(gpa, &st);
    defer if (g_tray) |*tr| tr.deinit();

    try app.run(gpa, AppState, &st, .{
        .title = "zigui — LLM Chat",
        .width = 900,
        .height = 650,
        .hide_on_close = true, // close button hides to the tray; Quit from the tray
    }, body);
}
