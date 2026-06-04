//! The zigui runtime: opens an OS window via SDL3, drives an event loop, and
//! presents frames. Rendering goes through the pure-Zig software rasterizer
//! (the `Canvas` command list is uploaded to an SDL streaming texture). This is
//! the v0 backend; because drawing is expressed as a command list, the GPU
//! (wgpu) backend can be slotted in later without touching components.
//!
//! This file is the *only* part of zigui that links SDL/C. It is compiled into
//! application executables, never into the core library or its test suite — so
//! `zig build test` stays headless and works in Docker.

const std = @import("std");
const zigui = @import("zigui");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Config = struct {
    title: [:0]const u8 = "zigui",
    width: u32 = 900,
    height: u32 = 600,
    theme: zigui.Theme = zigui.default_theme,
    /// When true, the window's close button hides the window (keeping the app
    /// alive in the tray) instead of quitting. Use with a `Tray` that offers a
    /// way back (e.g. an "Open" entry) and a "Quit". ⌘Q still quits.
    hide_on_close: bool = false,
};

pub const Error = error{ SdlInit, TrayInit };

// The running window + loop flag, exposed so tray callbacks (and the window
// close handler) can show/hide the window or quit. Set for the duration of
// `run`; mirrors the `g_animator` thread-local pattern.
var g_window: ?*c.SDL_Window = null;
var g_running: ?*bool = null;
var g_hide_on_close: bool = false;

/// Show and raise the window (e.g. from a tray "Open" entry).
pub fn showWindow() void {
    if (g_window) |w| {
        _ = c.SDL_ShowWindow(w);
        _ = c.SDL_RaiseWindow(w);
    }
}
/// Hide the window without quitting (the app keeps running in the tray).
pub fn hideWindow() void {
    if (g_window) |w| _ = c.SDL_HideWindow(w);
}
/// Ask the run loop to exit (e.g. from a tray "Quit" entry).
pub fn quit() void {
    if (g_running) |r| r.* = false;
}

/// The running app's animator, exposed so view callbacks can start animations
/// (e.g. `app.animator().?.animateTo(&state, 1, 0.3, .ease_in_out)`). Set for the
/// duration of `run`. Mirrors the focused-field thread-local pattern in `view`.
var g_animator: ?*zigui.Animator = null;
pub fn animator() ?*zigui.Animator {
    return g_animator;
}

/// An optional "busy" predicate: while it returns true the loop wakes on a
/// ~60fps timeout (instead of blocking on input) and rebuilds each frame, so the
/// app's `body` can poll in-flight work (e.g. a streaming socket). Mirrors the
/// animator-active branch. Set by examples via `setBusyCheck`.
var g_busy_fn: ?*const fn () bool = null;
pub fn setBusyCheck(f: ?*const fn () bool) void {
    g_busy_fn = f;
}

/// An optional application key handler, called first on every key-down with the
/// SDL keycode (`SDLK_*`) and modifier mask (`SDL_KMOD_*`, both reachable via
/// `app.c`). Return true to mark the key consumed — the loop then skips its
/// default text-field editing for that event. Use it for app shortcuts and
/// clipboard (e.g. ⌘S / ⌘O / ⌘C / ⌘V). Mirrors `setBusyCheck`.
var g_key_fn: ?*const fn (key: u32, mods: u16) bool = null;
pub fn setKeyHandler(f: ?*const fn (key: u32, mods: u16) bool) void {
    g_key_fn = f;
}

// ---------------------------------------------------------------------------
// System tray / menu bar (cross-platform via SDL3's native tray API:
// NSStatusItem on macOS, Shell_NotifyIcon on Windows, StatusNotifierItem on
// Linux). The icon is an `SDL_Surface` — so it can be drawn with zigui's own
// rasterizer and handed over as RGBA pixels. The menu, however, is OS-drawn
// (labels/checkboxes/submenus/separators only) and *retained*: build it once,
// then mutate it imperatively — it is not part of the per-frame view tree.
//
// Note: SDL may invoke entry callbacks from a non-main thread on some
// platforms; on macOS they run on the main thread. Keep callbacks simple
// (flip app-owned state, call show/hide/quit).
// ---------------------------------------------------------------------------

fn trayThunk(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    _ = entry;
    const cb: *zigui.Callback = @ptrCast(@alignCast(userdata orelse return));
    cb.call();
}

/// Build an `SDL_Surface` from row-major RGBA8 pixels (the format zigui's
/// `Framebuffer.toRgba8Alloc` produces). Returns null on failure.
fn makeSurface(rgba: []const u8, w: c_int, h: c_int) ?*c.SDL_Surface {
    const surf = c.SDL_CreateSurface(w, h, c.SDL_PIXELFORMAT_ABGR8888) orelse return null;
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    const pitch: usize = @intCast(surf.*.pitch);
    const dst: [*]u8 = @ptrCast(surf.*.pixels orelse return surf);
    var y: usize = 0;
    while (y < uh) : (y += 1) {
        @memcpy(dst[y * pitch ..][0 .. uw * 4], rgba[y * uw * 4 ..][0 .. uw * 4]);
    }
    return surf;
}

/// A submenu / menu handle. Entries are appended in order; a button entry fires
/// its `zigui.Callback` when clicked.
pub const TrayMenu = struct {
    owner: *Tray,
    menu: *c.SDL_TrayMenu,

    pub fn addItem(self: TrayMenu, label: [:0]const u8, cb: zigui.Callback) void {
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, c.SDL_TRAYENTRY_BUTTON) orelse return;
        self.owner.bind(e, cb);
    }
    /// A checkbox entry; `cb` fires on toggle (read the new state from the entry
    /// via your own model, or keep it in sync with `TrayEntry.setChecked`).
    pub fn addCheckItem(self: TrayMenu, label: [:0]const u8, checked: bool, cb: zigui.Callback) void {
        var flags: u32 = c.SDL_TRAYENTRY_CHECKBOX;
        if (checked) flags |= c.SDL_TRAYENTRY_CHECKED;
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, flags) orelse return;
        self.owner.bind(e, cb);
    }
    pub fn addSeparator(self: TrayMenu) void {
        _ = c.SDL_InsertTrayEntryAt(self.menu, -1, null, 0);
    }
    /// Append a submenu entry and return its menu for nesting.
    pub fn addSubmenu(self: TrayMenu, label: [:0]const u8) ?TrayMenu {
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, c.SDL_TRAYENTRY_SUBMENU) orelse return null;
        const sub = c.SDL_CreateTraySubmenu(e) orelse return null;
        return .{ .owner = self.owner, .menu = sub };
    }
};

/// A system-tray icon with a root menu. Create once (after/around `run`), keep
/// it alive for the app's lifetime, and `deinit` on exit.
pub const Tray = struct {
    handle: *c.SDL_Tray,
    root: *c.SDL_TrayMenu,
    icon: ?*c.SDL_Surface,
    gpa: std.mem.Allocator,
    callbacks: std.ArrayList(*zigui.Callback) = .empty,

    /// Create the tray with an RGBA8 icon (`w`×`h`) and a tooltip. SDL is
    /// initialized if it isn't already (idempotent), so this may be called
    /// before `run`.
    pub fn create(gpa: std.mem.Allocator, rgba: []const u8, w: c_int, h: c_int, tooltip: [:0]const u8) !Tray {
        _ = c.SDL_Init(c.SDL_INIT_VIDEO);
        const surf = makeSurface(rgba, w, h) orelse return Error.TrayInit;
        const handle = c.SDL_CreateTray(surf, tooltip.ptr) orelse {
            c.SDL_DestroySurface(surf);
            return Error.TrayInit;
        };
        const root = c.SDL_CreateTrayMenu(handle) orelse {
            c.SDL_DestroyTray(handle);
            c.SDL_DestroySurface(surf);
            return Error.TrayInit;
        };
        return .{ .handle = handle, .root = root, .icon = surf, .gpa = gpa };
    }

    pub fn deinit(self: *Tray) void {
        c.SDL_DestroyTray(self.handle);
        if (self.icon) |s| c.SDL_DestroySurface(s);
        for (self.callbacks.items) |cb| self.gpa.destroy(cb);
        self.callbacks.deinit(self.gpa);
    }

    /// The root menu, to which entries are added.
    pub fn menu(self: *Tray) TrayMenu {
        return .{ .owner = self, .menu = self.root };
    }

    /// Replace the icon (e.g. to reflect a status change). Copies `rgba`, so the
    /// caller may free it afterwards.
    pub fn setIcon(self: *Tray, rgba: []const u8, w: c_int, h: c_int) void {
        const surf = makeSurface(rgba, w, h) orelse return;
        c.SDL_SetTrayIcon(self.handle, surf);
        if (self.icon) |old| c.SDL_DestroySurface(old);
        self.icon = surf;
    }

    /// Box `cb` so it outlives this call (SDL keeps the userdata pointer), and
    /// wire it to `entry` through the C-ABI thunk.
    fn bind(self: *Tray, entry: *c.SDL_TrayEntry, cb: zigui.Callback) void {
        const boxed = self.gpa.create(zigui.Callback) catch return;
        boxed.* = cb;
        self.callbacks.append(self.gpa, boxed) catch {
            self.gpa.destroy(boxed);
            return;
        };
        c.SDL_SetTrayEntryCallback(entry, trayThunk, boxed);
    }
};

/// Run the app. `body` is invoked each frame to (re)build the view tree from the
/// current application state; state mutations triggered by events cause the next
/// frame to reflect the change.
pub fn run(
    gpa: std.mem.Allocator,
    comptime AppState: type,
    st: *AppState,
    cfg: Config,
    comptime body: fn (*AppState) zigui.View,
) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return Error.SdlInit;
    }
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        cfg.title.ptr,
        @intCast(cfg.width),
        @intCast(cfg.height),
        c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    ) orelse {
        std.log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return Error.SdlInit;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
        return Error.SdlInit;
    };
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_StartTextInput(window);

    var font = zigui.Font.default();
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // Animations are driven here: the loop ticks the animator each frame while
    // it is active, and view callbacks reach it via `app.animator()`.
    var anim = zigui.Animator.init(gpa);
    defer anim.deinit();
    g_animator = &anim;
    defer g_animator = null;
    var last_ms: u64 = c.SDL_GetTicks();

    var texture: ?*c.SDL_Texture = null;
    var tex_w: c_int = 0;
    var tex_h: c_int = 0;
    defer if (texture) |t| c.SDL_DestroyTexture(t);

    var running = true;
    // Expose the window/loop to tray callbacks and the close handler.
    g_window = window;
    g_running = &running;
    g_hide_on_close = cfg.hide_on_close;
    defer {
        g_window = null;
        g_running = null;
    }

    while (running) {
        // When hidden (e.g. closed-to-tray), don't render — just pump events so
        // tray entries and a re-open still work, and block efficiently.
        if ((c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0) {
            const no_hits: []const zigui.HitRegion = &.{};
            const no_scrolls: []const zigui.ScrollRegion = &.{};
            var ev: c.SDL_Event = undefined;
            if (c.SDL_WaitEvent(&ev)) handleEvent(&ev, &running, no_hits, no_scrolls);
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, no_hits, no_scrolls);
            continue;
        }
        // Logical size (points) drives layout; pixel size drives the framebuffer
        // so output is crisp on Retina. Their ratio is the content scale.
        var lw: c_int = 0;
        var lh: c_int = 0;
        _ = c.SDL_GetWindowSize(window, &lw, &lh);
        var pw: c_int = 0;
        var ph: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &pw, &ph);
        if (lw <= 0 or lh <= 0 or pw <= 0 or ph <= 0) {
            _ = waitOne(&running, st, cfg);
            continue;
        }
        const scale: f32 = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(lw));
        const uw: u32 = @intCast(pw);
        const uh: u32 = @intCast(ph);

        // (Re)build the view tree for this frame.
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        zigui.beginBuild(arena);
        const root = body(st);
        zigui.endBuild();

        var hits: std.ArrayList(zigui.HitRegion) = .empty;
        var overlays: std.ArrayList(zigui.OverlayReq) = .empty;
        var scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;
        var ctx = zigui.Context.initFull(cfg.theme, &cache, arena, &hits, &overlays, null);
        ctx.scroll_regions = &scrolls;

        var canvas = zigui.Canvas.init(arena);
        // Background in device pixels (renderScaled only scales the view commands
        // it appends, so the backdrop must already be in pixel space).
        try canvas.fillRect(.{ .x = 0, .y = 0, .width = @floatFromInt(uw), .height = @floatFromInt(uh) }, cfg.theme.colors.window_background);
        zigui.renderScaled(&ctx, root, .{ .x = 0, .y = 0, .width = @floatFromInt(lw), .height = @floatFromInt(lh) }, scale, &canvas) catch {};

        var fb = try zigui.Framebuffer.init(arena, uw, uh);
        fb.clear(cfg.theme.colors.window_background);
        try zigui.raster.render(arena, &fb, canvas.commands.items);
        const rgba = try fb.toRgba8Alloc(arena);

        // Upload to an SDL streaming texture (sized in device pixels) and present.
        if (texture == null or tex_w != pw or tex_h != ph) {
            if (texture) |t| c.SDL_DestroyTexture(t);
            texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, pw, ph);
            tex_w = pw;
            tex_h = ph;
        }
        _ = c.SDL_UpdateTexture(texture, null, rgba.ptr, @intCast(uw * 4));
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, texture, null, null);
        _ = c.SDL_RenderPresent(renderer);

        // Event handling. Hit/scroll regions stay in logical points (renderScaled
        // leaves them unscaled) and SDL reports mouse coordinates in points too,
        // so no conversion is needed before dispatch. While animating *or* while a
        // busy predicate is set (e.g. a streaming request in flight), wake on a
        // ~60fps timeout and rebuild each frame; otherwise block for input.
        var ev: c.SDL_Event = undefined;
        const busy = anim.active() or (if (g_busy_fn) |f| f() else false);
        if (busy) {
            if (c.SDL_WaitEventTimeout(&ev, 16)) handleEvent(&ev, &running, hits.items, scrolls.items);
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
            const now = c.SDL_GetTicks();
            const dt: f32 = @as(f32, @floatFromInt(now - last_ms)) / 1000.0;
            last_ms = now;
            anim.tick(dt);
        } else {
            if (c.SDL_WaitEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
            last_ms = c.SDL_GetTicks();
        }
    }
}

fn waitOne(running: *bool, st: anytype, cfg: Config) void {
    _ = st;
    _ = cfg;
    var ev: c.SDL_Event = undefined;
    if (c.SDL_WaitEvent(&ev)) {
        if (ev.type == c.SDL_EVENT_QUIT) running.* = false;
    }
}

fn handleEvent(ev: *c.SDL_Event, running: *bool, hits: []const zigui.HitRegion, scrolls: []const zigui.ScrollRegion) void {
    switch (ev.type) {
        c.SDL_EVENT_QUIT => running.* = false,
        // The close button: hide-to-tray when configured, else quit. (⌘Q still
        // sends SDL_EVENT_QUIT.)
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => if (g_hide_on_close) hideWindow() else {
            running.* = false;
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const p = zigui.geometry.Point{ .x = ev.button.x, .y = ev.button.y };
            zigui.clearFocus(); // a click defocuses; dispatch may refocus a field
            zigui.endDrag(); // reset any stale drag; dispatchTap re-arms over an editor
            _ = zigui.dispatchTap(hits, p);
        },
        // Drag the mouse with the left button held to extend a text selection.
        c.SDL_EVENT_MOUSE_MOTION => {
            if ((ev.motion.state & c.SDL_BUTTON_LMASK) != 0) {
                zigui.dispatchDrag(hits, .{ .x = ev.motion.x, .y = ev.motion.y });
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => zigui.endDrag(),
        c.SDL_EVENT_MOUSE_WHEEL => {
            var mx: f32 = 0;
            var my: f32 = 0;
            _ = c.SDL_GetMouseState(&mx, &my);
            _ = zigui.dispatchScroll(scrolls, .{ .x = mx, .y = my }, ev.wheel.y);
        },
        c.SDL_EVENT_TEXT_INPUT => {
            if (zigui.focusedField()) |f| {
                const s = std.mem.span(ev.text.text);
                f.insert(s) catch {};
            }
        },
        c.SDL_EVENT_KEY_DOWN => {
            // App shortcuts/clipboard get first refusal; a true return consumes
            // the key so default editing below is skipped.
            if (g_key_fn) |kf| {
                if (kf(ev.key.key, @intCast(ev.key.mod))) return;
            }
            if (zigui.focusedField()) |f| {
                const shift = (ev.key.mod & c.SDL_KMOD_SHIFT) != 0;
                switch (ev.key.key) {
                    c.SDLK_BACKSPACE => f.backspace(),
                    c.SDLK_DELETE => f.deleteForward(),
                    c.SDLK_LEFT => f.moveLeft(shift),
                    c.SDLK_RIGHT => f.moveRight(shift),
                    c.SDLK_UP => f.moveUp(shift),
                    c.SDLK_DOWN => f.moveDown(shift),
                    c.SDLK_HOME => f.home(shift),
                    c.SDLK_END => f.end(shift),
                    // Multi-line editors insert a newline; single-line fields submit.
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => if (f.multiline) f.insert("\n") catch {} else zigui.submitFocused(),
                    // Tab indents a multi-line editor (no focus traversal here).
                    c.SDLK_TAB => if (f.multiline) f.insert("    ") catch {},
                    c.SDLK_ESCAPE => zigui.clearFocus(),
                    else => {},
                }
            }
        },
        else => {},
    }
}
