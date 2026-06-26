//! The zigui runtime: opens an OS window via SDL3, drives an event loop, and
//! presents frames. Rendering prefers the SDL_GPU backend (`src/gpu/gpu.zig`:
//! Metal on macOS, Vulkan on Linux/Windows) and falls back to the pure-Zig
//! software rasterizer (the `Canvas` command list rasterized on the CPU and
//! uploaded to an SDL streaming texture) when no GPU is available — same
//! command list, same output, so apps never notice which backend ran.
//!
//! This file and `gpu/gpu.zig` are the only parts of zigui that link SDL/C.
//! They are compiled into application executables, never into the core library
//! or its test suite — so `zig build test` stays headless and works in Docker.

const std = @import("std");
const zigui = @import("zigui");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const gpu = @import("gpu/gpu.zig");

pub const Config = struct {
    title: [:0]const u8 = "zigui",
    width: u32 = 900,
    height: u32 = 600,
    /// Minimum window size the user can resize to (0 = no limit). Applied via
    /// SDL_SetWindowMinimumSize after the window is created.
    min_width: u32 = 0,
    min_height: u32 = 0,
    theme: zigui.Theme = zigui.default_theme,
    /// When true, the window's close button hides the window (keeping the app
    /// alive in the tray) instead of quitting. Use with a `Tray` that offers a
    /// way back (e.g. an "Open" entry) and a "Quit". ⌘Q still quits.
    hide_on_close: bool = false,
    /// Render via the SDL_GPU backend (Metal/Vulkan) when available, falling
    /// back to the software rasterizer when it isn't. Set false to force the
    /// software path; the `ZIGUI_SOFTWARE` environment variable does the same
    /// at runtime.
    gpu: bool = true,
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

/// Whether a window-close request hides to the tray (true) or quits (false).
/// Mirrors `Config.hide_on_close`, but can be toggled at runtime from a tray
/// checkbox.
pub fn hideOnClose() bool {
    return g_hide_on_close;
}
pub fn setHideOnClose(v: bool) void {
    g_hide_on_close = v;
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

/// An optional theme provider, queried once per frame so the app can switch
/// light/dark (or any theme) live without restarting. When null the loop uses
/// the static `Config.theme`. Set by examples via `setThemeProvider`.
var g_theme_fn: ?*const fn () zigui.Theme = null;
pub fn setThemeProvider(f: ?*const fn () zigui.Theme) void {
    g_theme_fn = f;
}

/// An optional per-frame hook, invoked once each main-loop iteration (before the
/// frame is drawn). Use it to push app state into retained OS surfaces that live
/// outside the view tree — e.g. refreshing a system-tray menu's labels/icon.
/// Runs on the main thread, so it is safe to call SDL tray setters from here.
var g_frame_fn: ?*const fn () void = null;
pub fn setFrameHook(f: ?*const fn () void) void {
    g_frame_fn = f;
}

/// The OS-level light/dark preference, reported by SDL. Cross-platform: on
/// macOS it reads `AppleInterfaceStyle`, on Windows the `AppsUseLightTheme`
/// registry value, and on Linux the XDG `org.freedesktop.appearance` portal.
/// `.unknown` when the platform can't report one — callers should fall back.
///
/// An OS theme change emits `SDL_EVENT_SYSTEM_THEME_CHANGED`, which wakes the
/// run loop (every event triggers a rebuild on the next iteration), so an app
/// that re-queries this each frame follows the OS live without extra wiring.
pub const SystemTheme = enum { unknown, light, dark };
pub fn systemTheme() SystemTheme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_LIGHT => .light,
        c.SDL_SYSTEM_THEME_DARK => .dark,
        else => .unknown,
    };
}

/// The OS color scheme as a `zigui.ColorScheme`, ready to hand to
/// `zigui.themeForScheme(family, app.colorScheme())`. Falls back to `.light`
/// when the platform can't report a preference. Re-query it each frame (or in a
/// theme provider) to follow the OS live.
pub fn colorScheme() zigui.ColorScheme {
    return if (systemTheme() == .dark) .dark else .light;
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

/// When true, the loop prints rolling frame-time stats (last/avg/max ms + the
/// equivalent fps) to stderr ~once per second. Off by default; also enabled at
/// startup if the `ZIGUI_FRAME_LOG` environment variable is set. Useful for
/// profiling the software rasterizer without a GPU profiler.
/// The cursor's last known position in logical points, or null when it has left
/// the window. Fed into `Context.hover_point` each frame for hover highlights.
var g_hover_point: ?zigui.geometry.Point = null;

var g_frame_log: bool = false;
pub fn setFrameLog(on: bool) void {
    g_frame_log = on;
}

/// Rolling per-second render-time accumulator (see `g_frame_log`).
const FrameStats = struct {
    count: u32 = 0,
    sum_ns: u64 = 0,
    max_ns: u64 = 0,
    last_report_ms: u64 = 0,

    fn record(self: *FrameStats, ns: u64, now_ms: u64) void {
        self.count += 1;
        self.sum_ns += ns;
        if (ns > self.max_ns) self.max_ns = ns;
        if (self.last_report_ms == 0) self.last_report_ms = now_ms;
        if (now_ms - self.last_report_ms >= 1000 and self.count > 0) {
            const last_ms = @as(f64, @floatFromInt(ns)) / 1.0e6;
            const avg_ms = @as(f64, @floatFromInt(self.sum_ns)) / @as(f64, @floatFromInt(self.count)) / 1.0e6;
            const max_ms = @as(f64, @floatFromInt(self.max_ns)) / 1.0e6;
            std.debug.print("[zigui] render: last {d:.2}ms  avg {d:.2}ms  max {d:.2}ms  ({d} frames, {d:.0} fps-equiv)\n", .{
                last_ms, avg_ms, max_ms, self.count, if (avg_ms > 0) 1000.0 / avg_ms else 0,
            });
            self.count = 0;
            self.sum_ns = 0;
            self.max_ns = 0;
            self.last_report_ms = now_ms;
        }
    }
};

// ---------------------------------------------------------------------------
// Clipboard (SDL3's cross-platform clipboard: NSPasteboard / Win32 / X11/Wayland).
// ---------------------------------------------------------------------------

/// Put UTF-8 `text` on the system clipboard. `text` need not be NUL-terminated.
pub fn setClipboardText(allocator: std.mem.Allocator, text: []const u8) void {
    const z = allocator.dupeZ(u8, text) catch return;
    defer allocator.free(z);
    _ = c.SDL_SetClipboardText(z.ptr);
}

/// Open a URL (or `file://…` path) in the OS default handler — opens a folder in
/// Finder/Explorer/the file manager, or a web URL in the browser. Cross-platform
/// via SDL3 (`NSWorkspace` / `ShellExecute` / `xdg-open`). Returns false on failure.
pub fn openUrl(url: [*:0]const u8) bool {
    return c.SDL_OpenURL(url);
}

/// Read UTF-8 text from the system clipboard. Returns an allocator-owned copy the
/// caller must free, or null when the clipboard is empty. (SDL returns an empty
/// string rather than null on failure; we normalize that to null.)
pub fn getClipboardText(allocator: std.mem.Allocator) ?[]u8 {
    const p = c.SDL_GetClipboardText();
    defer c.SDL_free(p);
    if (p == null) return null;
    const s = std.mem.span(p);
    if (s.len == 0) return null;
    return allocator.dupe(u8, s) catch null;
}

/// Copy the focused field's current selection to the clipboard (no-op if empty).
fn clipboardCopy(f: *zigui.TextFieldState) void {
    const sel = f.selectedText();
    if (sel.len == 0) return;
    setClipboardText(f.allocator, sel);
}

/// Insert clipboard text at the focused field's caret, replacing any selection.
fn clipboardPaste(f: *zigui.TextFieldState) void {
    const s = getClipboardText(f.allocator) orelse return;
    defer f.allocator.free(s);
    f.insert(s) catch {};
}

// ---------------------------------------------------------------------------
// File dialog (SDL3's native open-file dialog: NSOpenPanel / IFileDialog /
// XDG portal). Asynchronous: the OS panel runs alongside our loop and SDL
// invokes the callback later — possibly on another thread — so the callback
// only copies the path into a static buffer and pushes a user event to wake
// `SDL_WaitEvent`; the app polls `takeFileDialogResult` from its per-frame
// hook/body. One dialog at a time.
// ---------------------------------------------------------------------------

/// A dialog file filter, e.g. `.{ .name = "WAV audio", .pattern = "wav" }`.
/// `pattern` is a semicolon-separated extension list without dots ("wav;mp3").
pub const FileFilter = c.SDL_DialogFileFilter;

pub const FileDialogResult = union(enum) {
    /// No dialog finished since the last take (still open, or none shown).
    none,
    /// The user canceled (or the dialog failed).
    canceled,
    /// The user picked a file; caller owns the path.
    picked: []u8,
};

var g_dialog_open: bool = false; // main thread only: a dialog is showing
var g_dialog_done: std.atomic.Value(bool) = .init(false);
var g_dialog_path_len: usize = 0; // 0 = canceled; guarded by g_dialog_done
var g_dialog_path_buf: [4096]u8 = undefined;

fn fileDialogThunk(userdata: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
    _ = userdata;
    _ = filter;
    g_dialog_path_len = 0;
    if (filelist != null and filelist[0] != null) {
        const path = std.mem.span(filelist[0]);
        const n = @min(path.len, g_dialog_path_buf.len);
        @memcpy(g_dialog_path_buf[0..n], path[0..n]);
        g_dialog_path_len = n;
    }
    g_dialog_done.store(true, .release);
    // Wake the (possibly blocked) event loop so the app polls the result.
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&ev);
}

/// Show the native "Open File" dialog (single file). Returns false if one is
/// already open. `filters` must point at memory that outlives the dialog (a
/// global/comptime slice is the easy way) — SDL holds the pointer until the
/// user dismisses the panel. Poll `takeFileDialogResult` each frame for the
/// outcome. Call from the main thread.
pub fn openFileDialog(filters: []const FileFilter, default_location: ?[*:0]const u8) bool {
    if (g_dialog_open) return false;
    g_dialog_open = true;
    g_dialog_done.store(false, .release);
    c.SDL_ShowOpenFileDialog(
        fileDialogThunk,
        null,
        g_window,
        if (filters.len > 0) filters.ptr else null,
        @intCast(filters.len),
        default_location orelse null,
        false, // allow_many
    );
    return true;
}

/// Show the native "Open Folder" dialog (single folder). Returns false if a
/// dialog is already open. Shares the same result plumbing as `openFileDialog`
/// — poll `takeFileDialogResult` each frame for the chosen directory path.
/// Call from the main thread.
pub fn openFolderDialog(default_location: ?[*:0]const u8) bool {
    if (g_dialog_open) return false;
    g_dialog_open = true;
    g_dialog_done.store(false, .release);
    c.SDL_ShowOpenFolderDialog(
        fileDialogThunk,
        null,
        g_window,
        default_location orelse null,
        false, // allow_many
    );
    return true;
}

/// Whether an open-file dialog is currently showing (result not yet taken).
pub fn fileDialogOpen() bool {
    return g_dialog_open;
}

/// Collect the finished dialog's outcome, once. Returns `.none` while the
/// dialog is still up (or when none was shown); `.picked` hands the caller an
/// allocator-owned copy of the chosen path. Call from the main thread.
pub fn takeFileDialogResult(allocator: std.mem.Allocator) FileDialogResult {
    if (!g_dialog_open) return .none;
    if (!g_dialog_done.load(.acquire)) return .none;
    g_dialog_open = false;
    if (g_dialog_path_len == 0) return .canceled;
    const copy = allocator.dupe(u8, g_dialog_path_buf[0..g_dialog_path_len]) catch return .canceled;
    return .{ .picked = copy };
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

/// A handle to a single tray menu entry, returned by the `add*` builders so its
/// label / enabled / checked state can be mutated later (the menu is retained
/// and OS-drawn, not rebuilt per frame). SDL copies the label string, so a
/// transient buffer is fine. Call these on the main thread (e.g. a frame hook).
pub const TrayEntry = struct {
    entry: *c.SDL_TrayEntry,

    pub fn setLabel(self: TrayEntry, label: [:0]const u8) void {
        c.SDL_SetTrayEntryLabel(self.entry, label.ptr);
    }
    pub fn setEnabled(self: TrayEntry, enabled: bool) void {
        c.SDL_SetTrayEntryEnabled(self.entry, enabled);
    }
    pub fn setChecked(self: TrayEntry, checked: bool) void {
        c.SDL_SetTrayEntryChecked(self.entry, checked);
    }
};

/// A submenu / menu handle. Entries are appended in order; a button entry fires
/// its `zigui.Callback` when clicked.
pub const TrayMenu = struct {
    owner: *Tray,
    menu: *c.SDL_TrayMenu,

    pub fn addItem(self: TrayMenu, label: [:0]const u8, cb: zigui.Callback) ?TrayEntry {
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, c.SDL_TRAYENTRY_BUTTON) orelse return null;
        self.owner.bind(e, cb);
        return .{ .entry = e };
    }
    /// A non-interactive label row (a disabled button), useful as a status line.
    pub fn addLabel(self: TrayMenu, label: [:0]const u8) ?TrayEntry {
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, c.SDL_TRAYENTRY_BUTTON) orelse return null;
        c.SDL_SetTrayEntryEnabled(e, false);
        return .{ .entry = e };
    }
    /// A checkbox entry; `cb` fires on toggle (read the new state from the entry
    /// via your own model, or keep it in sync with `TrayEntry.setChecked`).
    pub fn addCheckItem(self: TrayMenu, label: [:0]const u8, checked: bool, cb: zigui.Callback) ?TrayEntry {
        var flags: u32 = c.SDL_TRAYENTRY_CHECKBOX;
        if (checked) flags |= c.SDL_TRAYENTRY_CHECKED;
        const e = c.SDL_InsertTrayEntryAt(self.menu, -1, label.ptr, flags) orelse return null;
        self.owner.bind(e, cb);
        return .{ .entry = e };
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

    if (cfg.min_width > 0 and cfg.min_height > 0)
        _ = c.SDL_SetWindowMinimumSize(window, @intCast(cfg.min_width), @intCast(cfg.min_height));

    // Prefer the GPU backend; when device/swapchain creation fails (no Vulkan
    // driver, headless CI, ZIGUI_SOFTWARE set) fall back to the software
    // rasterizer presented through an SDL streaming texture.
    const want_gpu = cfg.gpu and c.SDL_getenv("ZIGUI_SOFTWARE") == null;
    var gpu_backend: ?gpu.Gpu = if (want_gpu) gpu.Gpu.init(gpa, window) else null;
    defer if (gpu_backend) |*g| g.deinit();
    if (gpu_backend) |*g| std.log.info("zigui: rendering via SDL_GPU ({s})", .{g.driverName()});

    const renderer: ?*c.SDL_Renderer = if (gpu_backend != null) null else c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("SDL_CreateRenderer failed: {s}", .{c.SDL_GetError()});
        return Error.SdlInit;
    };
    defer if (renderer) |r| c.SDL_DestroyRenderer(r);

    _ = c.SDL_StartTextInput(window);

    var font = zigui.Font.default();
    // Bundled monochrome emoji font, wired as a fallback so codepoints Inter
    // lacks (emoji, etc.) still render. Lives for the whole loop, so the
    // `&emoji_font.face` pointer stays valid.
    var emoji_font = zigui.Font.emoji();
    font.face.fallback = &emoji_font.face;
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();

    var icon_font = zigui.Font.icons();
    var icon_cache = zigui.GlyphCache.init(gpa, &icon_font.face);
    defer icon_cache.deinit();

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

    // Persistent render buffers (reused across frames; freed at shutdown).
    var fb: zigui.Framebuffer = .empty;
    defer fb.deinit();
    var rgba: []u8 = &.{};
    defer if (rgba.len > 0) gpa.free(rgba);
    const perf_freq = c.SDL_GetPerformanceFrequency();
    var stats: FrameStats = .{};
    // Opt-in frame profiling via env var (in addition to `setFrameLog`).
    if (c.SDL_getenv("ZIGUI_FRAME_LOG") != null) g_frame_log = true;

    // Let the (platform-free) context menu copy/paste via the SDL clipboard.
    zigui.setClipboardOps(.{ .copy = clipboardCopy, .paste = clipboardPaste });

    // Cache wrapped-text layout across frames so a long, static transcript isn't
    // re-wrapped on every redraw (only changing text actually re-wraps).
    var wrap_cache = zigui.WrapCache.init(gpa);
    defer wrap_cache.deinit();
    zigui.setWrapCache(&wrap_cache);
    defer zigui.setWrapCache(null);

    // A dedicated arena + scratch region lists for redraws issued from the macOS
    // live-resize event watch, so a watch-triggered frame never aliases the main
    // loop's arena (which is mid-use when the watch fires). The lists are backed
    // by `resize_arena` (their items hold arena-allocated callbacks), so they are
    // never deinit'd with gpa — `resize_arena.deinit()` reclaims everything.
    var resize_arena = std.heap.ArenaAllocator.init(gpa);
    defer resize_arena.deinit();
    var resize_hits: std.ArrayList(zigui.HitRegion) = .empty;
    var resize_scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;

    var running = true;
    // Expose the window/loop to tray callbacks and the close handler.
    g_window = window;
    g_running = &running;
    g_hide_on_close = cfg.hide_on_close;
    defer {
        g_window = null;
        g_running = null;
    }

    // Everything one `drawFrame` needs, shared by the main loop and the resize
    // watch (which run on the same thread, never concurrently).
    const Frame = struct {
        gpa: std.mem.Allocator,
        window: *c.SDL_Window,
        renderer: ?*c.SDL_Renderer,
        gpu_backend: ?*gpu.Gpu,
        cache: *zigui.GlyphCache,
        icon_cache: *zigui.GlyphCache,
        cfg: Config,
        st: *AppState,
        texture: *?*c.SDL_Texture,
        tex_w: *c_int,
        tex_h: *c_int,
        // Persistent pixel buffers reused across frames (realloc only on resize),
        // so steady-state frames allocate no per-frame framebuffer/RGBA scratch.
        fb: *zigui.Framebuffer,
        rgba: *[]u8,
        perf_freq: u64,
        stats: *FrameStats,
        resize_arena: *std.heap.ArenaAllocator,
        resize_hits: *std.ArrayList(zigui.HitRegion),
        resize_scrolls: *std.ArrayList(zigui.ScrollRegion),
    };

    const Render = struct {
        /// Build, rasterize and present one frame into `arena_state`, recording
        /// hit/scroll regions into the given lists. Returns false (no present) if
        /// the window is hidden or has a degenerate size.
        fn drawFrame(
            fr: *Frame,
            frame_arena: *std.heap.ArenaAllocator,
            hits: *std.ArrayList(zigui.HitRegion),
            scrolls: *std.ArrayList(zigui.ScrollRegion),
        ) bool {
            if ((c.SDL_GetWindowFlags(fr.window) & c.SDL_WINDOW_HIDDEN) != 0) return false;
            // Logical size (points) drives layout; pixel size drives the
            // framebuffer so output is crisp on Retina. Their ratio is the scale.
            var lw: c_int = 0;
            var lh: c_int = 0;
            _ = c.SDL_GetWindowSize(fr.window, &lw, &lh);
            var pw: c_int = 0;
            var ph: c_int = 0;
            _ = c.SDL_GetWindowSizeInPixels(fr.window, &pw, &ph);
            if (lw <= 0 or lh <= 0 or pw <= 0 or ph <= 0) return false;
            const t0 = c.SDL_GetPerformanceCounter();
            const scale: f32 = @as(f32, @floatFromInt(pw)) / @as(f32, @floatFromInt(lw));
            const uw: u32 = @intCast(pw);
            const uh: u32 = @intCast(ph);

            // Frame clock for time-based UI (auto-hiding scrollbars, etc.).
            zigui.setFrameTime(c.SDL_GetTicks());

            // Live theme: query the provider (if any) so light/dark switches take
            // effect without a restart. Read it after `body` builds the tree so the
            // framebuffer clear and Context agree with whatever the body painted.
            _ = frame_arena.reset(.retain_capacity);
            const arena = frame_arena.allocator();
            const theme = if (g_theme_fn) |f| f() else fr.cfg.theme;
            // Publish the active theme's selection tints so composed constructors
            // (Sidebar/Table/RadioGroup) pick up dark mode and custom accents.
            zigui.setThemeTokens(theme);
            zigui.beginBuild(arena);
            const root = body(fr.st);
            zigui.endBuild();

            // Reset to empty (not clearRetainingCapacity): the previous buffer was
            // arena-allocated and the reset above reclaimed it, so keeping the old
            // pointer would alias freshly handed-out arena memory.
            hits.* = .empty;
            scrolls.* = .empty;
            var overlays: std.ArrayList(zigui.OverlayReq) = .empty;
            var ctx = zigui.Context.initFull(theme, fr.cache, arena, hits, &overlays, null);
            ctx.scroll_regions = scrolls;
            ctx.icon_cache = fr.icon_cache;
            ctx.hover_point = g_hover_point;

            var canvas = zigui.Canvas.init(arena);
            // No background fill command here: the framebuffer's `clear` below paints
            // the window background with a fast @memset, so emitting a full-window
            // fill_rrect would just re-rasterize every pixel through the SDF path.
            zigui.renderScaled(&ctx, root, .{ .x = 0, .y = 0, .width = @floatFromInt(lw), .height = @floatFromInt(lh) }, scale, &canvas) catch {};

            if (fr.gpu_backend) |g| {
                // GPU backend: translate + replay the command list on the GPU.
                if (!g.frame(arena, canvas.commands.items, theme.colors.window_background)) return false;
            } else {
                // Software backend. Persistent framebuffer + RGBA buffer:
                // reallocated only when the pixel size changes, so a
                // steady-state frame does zero pixel-buffer allocation.
                const rend = fr.renderer.?;
                fr.fb.ensureSize(fr.gpa, uw, uh) catch return false;
                fr.fb.clear(theme.colors.window_background);
                zigui.raster.render(arena, fr.fb, canvas.commands.items) catch return false;
                const need: usize = @as(usize, uw) * @as(usize, uh) * 4;
                if (fr.rgba.*.len != need) {
                    if (fr.rgba.*.len > 0) fr.gpa.free(fr.rgba.*);
                    fr.rgba.* = fr.gpa.alloc(u8, need) catch return false;
                }
                fr.fb.toRgba8(fr.rgba.*);

                if (fr.texture.* == null or fr.tex_w.* != pw or fr.tex_h.* != ph) {
                    if (fr.texture.*) |t| c.SDL_DestroyTexture(t);
                    fr.texture.* = c.SDL_CreateTexture(rend, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, pw, ph);
                    fr.tex_w.* = pw;
                    fr.tex_h.* = ph;
                }
                _ = c.SDL_UpdateTexture(fr.texture.*, null, fr.rgba.*.ptr, @intCast(uw * 4));
                _ = c.SDL_RenderClear(rend);
                _ = c.SDL_RenderTexture(rend, fr.texture.*, null, null);
                _ = c.SDL_RenderPresent(rend);
            }

            if (g_frame_log) {
                const t1 = c.SDL_GetPerformanceCounter();
                const ns = (t1 -% t0) *% 1_000_000_000 / fr.perf_freq;
                fr.stats.record(ns, c.SDL_GetTicks());
            }
            return true;
        }

        /// SDL event watch: fires synchronously while events are pumped, INCLUDING
        /// during the macOS modal live-resize loop (when the main loop is blocked
        /// in SDL_WaitEvent). Redraw on resize/expose so content reflows live
        /// instead of the old texture being stretched until the mouse is released.
        fn resizeWatch(userdata: ?*anyopaque, ev: [*c]c.SDL_Event) callconv(.c) bool {
            const fr: *Frame = @ptrCast(@alignCast(userdata.?));
            switch (ev.*.type) {
                c.SDL_EVENT_WINDOW_RESIZED,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
                c.SDL_EVENT_WINDOW_EXPOSED,
                => _ = drawFrame(fr, fr.resize_arena, fr.resize_hits, fr.resize_scrolls),
                else => {},
            }
            return true;
        }
    };

    var frame = Frame{
        .gpa = gpa,
        .window = window,
        .renderer = renderer,
        .gpu_backend = if (gpu_backend) |*g| g else null,
        .cache = &cache,
        .icon_cache = &icon_cache,
        .cfg = cfg,
        .st = st,
        .texture = &texture,
        .tex_w = &tex_w,
        .tex_h = &tex_h,
        .fb = &fb,
        .rgba = &rgba,
        .perf_freq = perf_freq,
        .stats = &stats,
        .resize_arena = &resize_arena,
        .resize_hits = &resize_hits,
        .resize_scrolls = &resize_scrolls,
    };
    _ = c.SDL_AddEventWatch(Render.resizeWatch, &frame);
    defer c.SDL_RemoveEventWatch(Render.resizeWatch, &frame);

    while (running) {
        // Per-frame hook (e.g. refresh the system-tray menu). Runs whether or not
        // the window is visible, so the tray tracks status even when hidden.
        if (g_frame_fn) |f| f();

        // When hidden (e.g. closed-to-tray), don't render — just pump events so
        // tray entries and a re-open still work, and block efficiently. While a
        // busy predicate is set (e.g. a generation in flight), wake on a ~60fps
        // timeout so the frame hook keeps the tray status live.
        if ((c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0) {
            const no_hits: []const zigui.HitRegion = &.{};
            const no_scrolls: []const zigui.ScrollRegion = &.{};
            const busy = if (g_busy_fn) |f| f() else false;
            var ev: c.SDL_Event = undefined;
            if (busy) {
                if (c.SDL_WaitEventTimeout(&ev, 16)) handleEvent(&ev, &running, no_hits, no_scrolls);
            } else {
                if (c.SDL_WaitEvent(&ev)) handleEvent(&ev, &running, no_hits, no_scrolls);
            }
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, no_hits, no_scrolls);
            continue;
        }

        // Fresh per-frame region lists (arena-backed via drawFrame); discarded at
        // the next arena reset, exactly like the pre-refactor loop.
        var hits: std.ArrayList(zigui.HitRegion) = .empty;
        var scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;
        if (!Render.drawFrame(&frame, &arena_state, &hits, &scrolls)) {
            waitOne(&running, st, cfg);
            continue;
        }

        // Event handling. Hit/scroll regions stay in logical points (renderScaled
        // leaves them unscaled) and SDL reports mouse coordinates in points too,
        // so no conversion is needed before dispatch. While animating *or* while a
        // busy predicate is set (e.g. a streaming request in flight), wake on a
        // ~60fps timeout and rebuild each frame; otherwise block for input.
        var ev: c.SDL_Event = undefined;
        const busy = anim.active() or zigui.scrollbarsAnimating(c.SDL_GetTicks()) or (if (g_busy_fn) |f| f() else false);
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
    // With frame logging on, also log which events wake the loop (each wake
    // costs a full rebuild+raster) so redraw storms can be attributed.
    if (g_frame_log) std.debug.print("[zigui] event 0x{x}\n", .{ev.type});
    switch (ev.type) {
        c.SDL_EVENT_QUIT => running.* = false,
        // The close button: hide-to-tray when configured, else quit. (⌘Q still
        // sends SDL_EVENT_QUIT.)
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => if (g_hide_on_close) hideWindow() else {
            running.* = false;
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const p = zigui.geometry.Point{ .x = ev.button.x, .y = ev.button.y };
            if (ev.button.button == c.SDL_BUTTON_RIGHT) {
                // Right-click pops the text context menu when over an editable
                // field; elsewhere it just dismisses any open menu.
                if (zigui.fieldAt(hits, p)) |field| {
                    zigui.openContextMenu(field, p);
                } else {
                    zigui.closeContextMenu();
                }
            } else if (zigui.contextMenuOpen()) {
                // A left-click while the menu is open routes to the menu (an item
                // or the dismiss region) without disturbing focus.
                _ = zigui.dispatchTap(hits, p);
            } else {
                zigui.clearFocus(); // a click defocuses; dispatch may refocus a field
                zigui.endDrag(); // reset any stale drag; dispatchTap re-arms over an editor
                // In a text field, double-click selects the word and triple-click
                // selects all; any other target falls back to a normal tap.
                if (ev.button.clicks >= 3 and zigui.dispatchTripleClick(hits, p)) {} else if (ev.button.clicks == 2 and zigui.dispatchDoubleClick(hits, p)) {} else {
                    _ = zigui.dispatchTap(hits, p);
                }
            }
        },
        // Drag the mouse with the left button held to extend a text selection.
        c.SDL_EVENT_MOUSE_MOTION => {
            const mp = zigui.geometry.Point{ .x = ev.motion.x, .y = ev.motion.y };
            g_hover_point = mp; // drives Modifiers.hover_fill highlights
            // Track the hovered context-menu item (the loop redraws after this
            // event, so the highlight follows the cursor).
            if (zigui.contextMenuOpen()) zigui.hoverContextMenu(hits, mp);
            if ((ev.motion.state & c.SDL_BUTTON_LMASK) != 0) {
                zigui.dispatchDrag(hits, mp);
            }
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => zigui.endDrag(),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => g_hover_point = null,
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
            // Escape closes an open context menu before anything else sees the key.
            if (zigui.contextMenuOpen() and ev.key.key == c.SDLK_ESCAPE) {
                zigui.closeContextMenu();
                return;
            }
            if (zigui.focusedField()) |f| {
                // Clipboard shortcuts (⌘ on macOS, Ctrl elsewhere) take priority
                // over plain editing. With the command/ctrl modifier held SDL does
                // not emit a matching TEXT_INPUT, so consuming the key here is safe.
                if ((ev.key.mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0) {
                    switch (ev.key.key) {
                        c.SDLK_C => {
                            clipboardCopy(f);
                            return;
                        },
                        c.SDLK_X => {
                            clipboardCopy(f);
                            _ = f.deleteSelection();
                            return;
                        },
                        c.SDLK_V => {
                            clipboardPaste(f);
                            return;
                        },
                        c.SDLK_A => {
                            f.selectAll();
                            return;
                        },
                        else => {},
                    }
                }
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
