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

const builtin = @import("builtin");
pub const c = @import("sdl_c");

pub const gpu = @import("gpu/gpu.zig");

/// Row-major RGBA8 window icon (`rgba` is `w*h*4` bytes). See `Config.icon`.
pub const WindowIcon = struct { rgba: []const u8, w: c_int, h: c_int };

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
    /// Optional window/taskbar icon, set via `SDL_SetWindowIcon` after the window
    /// is created. `rgba` is row-major RGBA8 (`w*h*4` bytes); the surface is
    /// copied by SDL, so the caller may free `rgba` after `run` sets it.
    icon: ?WindowIcon = null,
    /// Supersampling factor: the UI is rendered into a framebuffer this many
    /// times larger per axis, then downscaled on present (SSAA). On a low-DPI
    /// (100%) display this is what makes text crisp — gamma adds weight, but
    /// only extra device pixels add edge resolution. 1 = off (default). 2 is a
    /// good value for 96-dpi monitors; it costs ~4× the fill (negligible on the
    /// GPU, heavier on the software fallback). Capped internally so an already
    /// HiDPI display isn't oversampled past ~2× effective device pixels.
    supersample: f32 = 1,
    /// macOS: hide the title and let the content run under a transparent,
    /// toolbar-height titlebar (the traffic lights float over the app's own
    /// top band, as in Finder / the Swift apps). The top `drag_band` points that
    /// hold no control then drag the window everywhere (on every OS), so an app
    /// that draws its own band behaves like a native titlebar.
    unified_titlebar: bool = false,
    drag_band: f32 = 0,
    /// macOS menu bar menus, after the application menu (ignored elsewhere:
    /// there is no menu bar to put them in).
    menus: []const Menu = &.{},
    /// A face behind the bundled emoji font for codepoints no bundled face has
    /// (a system CJK font, `zigui.Font.fromExternal`). Must outlive `run`.
    fallback_font: ?*const zigui.ttf.Font = null,
};

/// One menu-bar entry. An empty title is a separator. `action` runs on the UI
/// thread; `selector` instead sends a standard Cocoa action down the responder
/// chain ("performMiniaturize:"). `key` + modifiers is the key equivalent
/// (Command is implied).
pub const MenuItem = struct {
    title: [:0]const u8 = "",
    key: [:0]const u8 = "",
    shift: bool = false,
    ctrl: bool = false,
    option: bool = false,
    action: ?zigui.Callback = null,
    selector: ?[:0]const u8 = null,
};

pub const Menu = struct { title: [:0]const u8, items: []const MenuItem };

/// A secondary, borderless window that hosts a view tree — the custom tray
/// popover (Swift's `MenuBarExtra(.window)` panel). Created hidden; the app
/// shows it under the pointer via `showPanel()` (typically from a status-item
/// click). Drawn with the software rasterizer so it never competes with the
/// main window's GPU swapchain.
pub fn PanelSpec(comptime AppState: type) type {
    return struct {
        /// Builds the panel's view tree, once per frame while it is visible.
        body: *const fn (*AppState) zigui.View,
        /// Logical (point) size. HiDPI backing is handled like the main window.
        width: u32 = 340,
        height: u32 = 620,
    };
}

pub const Error = error{ SdlInit, TrayInit };

// The running window + loop flag, exposed so tray callbacks (and the window
// close handler) can show/hide the window or quit. Set for the duration of
// `run`; mirrors the `g_animator` thread-local pattern.
var g_window: ?*c.SDL_Window = null;
var g_running: ?*bool = null;
var g_hide_on_close: bool = false;

// The popover panel (see `PanelSpec`): created hidden at startup and toggled by
// a status-item click. Its hit regions live in their own lists so clicks on the
// panel never resolve against the main window's tree.
var g_panel_window: ?*c.SDL_Window = null;
var g_panel_id: c.SDL_WindowID = 0;
var g_panel_shown: bool = false;
var g_panel_hits: []const zigui.HitRegion = &.{};
var g_panel_scrolls: []const zigui.ScrollRegion = &.{};
var g_panel_hover: ?zigui.geometry.Point = null;
/// Size key of the frame already written by ZIGUI_PANEL_DUMP (see drawFrame).
var g_dump_written: u64 = 0;

pub fn panelVisible() bool {
    return g_panel_shown;
}

/// Position the panel under the pointer (a tray click leaves the cursor on the
/// icon), clamped to the screen's usable area, then show and focus it.
pub fn showPanel() void {
    const w = g_panel_window orelse return;
    var lw: c_int = 0;
    var lh: c_int = 0;
    _ = c.SDL_GetWindowSize(w, &lw, &lh);
    var mx: f32 = 0;
    var my: f32 = 0;
    _ = c.SDL_GetGlobalMouseState(&mx, &my);
    var x: c_int = @intFromFloat(@as(f32, mx) - @as(f32, @floatFromInt(lw)) / 2);
    var y: c_int = @intFromFloat(my + 10);
    var pt = c.SDL_Point{ .x = @intFromFloat(mx), .y = @intFromFloat(my) };
    const disp = c.SDL_GetDisplayForPoint(&pt);
    var bounds: c.SDL_Rect = undefined;
    if (c.SDL_GetDisplayUsableBounds(disp, &bounds)) {
        const max_x = bounds.x + bounds.w - lw;
        const max_y = bounds.y + bounds.h - lh;
        if (max_y < bounds.y) y = bounds.y else if (y > max_y) y = max_y;
        if (x < bounds.x) x = bounds.x else if (x > max_x) x = max_x;
    }
    _ = c.SDL_SetWindowPosition(w, x, y);
    _ = c.SDL_ShowWindow(w);
    _ = c.SDL_RaiseWindow(w);
    _ = c.SDL_StartTextInput(w);
    g_panel_shown = true;
    wake();
}

/// Resize the panel window without showing it (the launcher restores the tray
/// size before hiding, so the next tray click anchors correctly).
pub fn setPanelSize(width: u32, height: u32) void {
    const w = g_panel_window orelse return;
    _ = c.SDL_SetWindowSize(w, @intCast(width), @intCast(height));
}

/// Spotlight-style placement for the Quick Launcher: centered horizontally on
/// the primary display, top edge 25% down, wherever the pointer is. `height` is
/// the content's fixed size; the auto-height frame can grow it when a
/// conversation starts without moving the top edge.
pub fn showPanelCentered(width: u32, height: u32) void {
    const w = g_panel_window orelse return;
    _ = c.SDL_SetWindowSize(w, @intCast(width), @intCast(height));
    var bounds: c.SDL_Rect = undefined;
    var x: c_int = 0;
    var y: c_int = 0;
    if (c.SDL_GetDisplayUsableBounds(c.SDL_GetPrimaryDisplay(), &bounds)) {
        x = bounds.x + @divTrunc(bounds.w - @as(c_int, @intCast(width)), 2);
        y = bounds.y + @as(c_int, @intFromFloat(@as(f32, @floatFromInt(bounds.h)) * 0.25));
        const max_y = bounds.y + bounds.h - @as(c_int, @intCast(height));
        if (y > max_y) y = @max(bounds.y, max_y);
    }
    _ = c.SDL_SetWindowPosition(w, x, y);
    _ = c.SDL_ShowWindow(w);
    _ = c.SDL_RaiseWindow(w);
    _ = c.SDL_StartTextInput(w);
    g_panel_shown = true;
    wake();
}

pub fn hidePanel() void {
    if (!g_panel_shown) return;
    g_panel_shown = false;
    if (g_panel_window) |w| {
        _ = c.SDL_StopTextInput(w);
        _ = c.SDL_HideWindow(w);
    }
    if (zigui.focusedField() != null) zigui.clearFocus();
    wake();
}

pub fn togglePanel() void {
    if (g_panel_shown) hidePanel() else showPanel();
}

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
/// Wake the event loop from any thread (a worker finished something the UI
/// should show). Safe to call before/after `run`; a no-op while SDL is down.
pub fn wake() void {
    var ev = std.mem.zeroes(c.SDL_Event);
    ev.type = c.SDL_EVENT_USER;
    _ = c.SDL_PushEvent(&ev);
}

/// Ask the run loop to exit (e.g. from a tray "Quit" entry). Only flips the
/// flag: a tray/menu callback fires inside macOS's Cocoa menu-tracking loop,
/// which swallows any SDL wakeup event we'd push here, so the loop can't be
/// woken from this context. Instead the loop caps its idle wait (`idle_wake_ms`)
/// and re-checks `running` on the timeout — see the wait sites in `run`.
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
/// Bundled faces for weight/italic/mono (see `zigui.FontSet`); set for the run.
var g_fonts: ?*zigui.FontSet = null;
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

/// A cadence-returning generalization of `setBusyCheck`: while the provider
/// returns a non-zero interval (ms), the loop wakes on that timeout instead of
/// blocking on input and rebuilds each frame — so a heavy GPU job can repaint a
/// spinner at 10 fps (not fighting the worker for the GPU at 60) while video
/// playback keeps its own smooth cadence. 0 means fully idle (block on input).
/// Takes precedence over the boolean predicate when both are set.
var g_busy_interval_fn: ?*const fn () u32 = null;
pub fn setBusyInterval(f: ?*const fn () u32) void {
    g_busy_interval_fn = f;
}

/// Ceiling on the idle wait (ms) when the app has no busy work. A fully
/// blocking `SDL_WaitEvent` only returns on an SDL event, so state changed by a
/// context that posts none — most importantly a tray/menu callback — isn't
/// observed until the next incidental event. When the window is visible that's
/// the user's next mouse-over; when it's hidden-to-tray there's no window to
/// receive one, so `app.quit()` from the tray would hang the process forever.
/// Capping the wait lets the loop re-check `running` (and re-run the frame hook,
/// e.g. tray status) ~every 250 ms while idle. Both idle wait sites skip the
/// redraw on a timeout (nothing changed), so this stays ~free — measured <0.5%
/// CPU idle — while bounding worst-case tray-action latency to this interval
/// instead of "until the next incidental event".
const idle_wake_ms: c_int = 1000;

/// The caret blinks ~530 ms per phase (the macOS default); any key or click
/// restarts the cycle solid, so the caret never vanishes while typing.
const blink_ms: u64 = 530;
var g_blink_epoch: u64 = 0;
/// The phase the last frame drew, so idle waits know when a redraw is due.
var g_caret_drawn: bool = true;

fn caretPhaseOn(now: u64) bool {
    return ((now -| g_blink_epoch) / blink_ms) % 2 == 0;
}

/// Wait slice while idle: up to the next caret flip when a field is focused.
fn idleWaitMs() c_int {
    if (zigui.focusedField() == null) return idle_wake_ms;
    const left = blink_ms - (c.SDL_GetTicks() -| g_blink_epoch) % blink_ms;
    return @intCast(@min(left + 1, @as(u64, @intCast(idle_wake_ms))));
}

/// The app-requested wake cadence in ms (0 = idle): the interval provider when
/// set, else 16 ms while the boolean busy predicate holds.
fn busyIntervalMs() u32 {
    if (g_busy_interval_fn) |f| return f();
    if (g_busy_fn) |f| {
        if (f()) return 16;
    }
    return 0;
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

/// Called with the path of each file dropped onto the window.
var g_drop_fn: ?*const fn (path: []const u8) void = null;
pub fn setDropHandler(f: ?*const fn (path: []const u8) void) void {
    g_drop_fn = f;
}

/// When true, the loop prints rolling frame-time stats (last/avg/max ms + the
/// equivalent fps) to stderr ~once per second. Off by default; also enabled at
/// startup if the `ZIGUI_FRAME_LOG` environment variable is set. Useful for
/// profiling the software rasterizer without a GPU profiler.
/// The cursor's last known position in logical points, or null when it has left
/// the window. Fed into `Context.hover_point` each frame for hover highlights.
var g_hover_point: ?zigui.geometry.Point = null;

/// Scale converting SDL mouse coordinates (logical window points) into the
/// design-point space that hit/scroll regions live in. `drawFrame` updates it
/// each frame to `pixel_density / display_scale`: 1.0 on macOS (where the OS UI
/// scale rides on the backing scale), but <1 on Windows/Linux at a non-100% OS
/// display-scale setting, where the two diverge. See `drawFrame`.
var g_event_scale: f32 = 1;

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
/// The I-beam over text (fields, editors, selectable text), else the arrow.
var g_cursors: [2]?*c.SDL_Cursor = .{ null, null };
var g_text_cursor = false;
fn setTextCursor(on: bool) void {
    if (on == g_text_cursor) return;
    g_text_cursor = on;
    const i: usize = @intFromBool(on);
    if (g_cursors[i] == null) g_cursors[i] = c.SDL_CreateSystemCursor(if (on) c.SDL_SYSTEM_CURSOR_TEXT else c.SDL_SYSTEM_CURSOR_DEFAULT);
    if (g_cursors[i]) |cur| _ = c.SDL_SetCursor(cur);
}

pub fn setClipboardText(allocator: std.mem.Allocator, text: []const u8) void {
    const z = allocator.dupeSentinel(u8, text, 0) catch return;
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
/// The clipboard's PNG image, if it holds one (caller frees).
pub fn getClipboardPng(allocator: std.mem.Allocator) ?[]u8 {
    if (!c.SDL_HasClipboardData("image/png")) return null;
    var n: usize = 0;
    const p = c.SDL_GetClipboardData("image/png", &n) orelse return null;
    defer c.SDL_free(p);
    if (n == 0) return null;
    const src: [*]const u8 = @ptrCast(p);
    return allocator.dupe(u8, src[0..n]) catch null;
}

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
            // On Linux this is usually a missing libayatana-appindicator3 / libappindicator3.
            std.log.warn("SDL_CreateTray failed: {s}", .{c.SDL_GetError()});
            c.SDL_DestroySurface(surf);
            return Error.TrayInit;
        };
        const root = c.SDL_CreateTrayMenu(handle) orelse {
            c.SDL_DestroyTray(handle);
            c.SDL_DestroySurface(surf);
            return Error.TrayInit;
        };
        if (builtin.os.tag == .macos) cocoa.templateStatusIcons();
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

    /// Remove every entry (and drop their callbacks), for a menu rebuilt from
    /// changed state. Call on the main thread, never from inside a callback.
    pub fn clear(self: *Tray) void {
        while (true) {
            var n: c_int = 0;
            const entries = c.SDL_GetTrayEntries(self.root, &n) orelse break;
            if (n == 0) break;
            c.SDL_RemoveTrayEntry(@constCast(entries[0]));
        }
        for (self.callbacks.items) |cb| self.gpa.destroy(cb);
        self.callbacks.clearRetainingCapacity();
    }

    /// Replace the icon (e.g. to reflect a status change). Copies `rgba`, so the
    /// caller may free it afterwards.
    pub fn setIcon(self: *Tray, rgba: []const u8, w: c_int, h: c_int) void {
        const surf = makeSurface(rgba, w, h) orelse return;
        c.SDL_SetTrayIcon(self.handle, surf);
        if (self.icon) |old| c.SDL_DestroySurface(old);
        self.icon = surf;
        if (builtin.os.tag == .macos) cocoa.templateStatusIcons();
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

/// macOS: a plain NSStatusItem whose click runs `on_click` (no menu attached),
/// so the app can open its own popover panel. Returns false on other platforms
/// and when AppKit can't be reached — callers fall back to `Tray`.
/// `rgba` is the HiDPI (2x) bitmap; the icon shows at half its pixel size in
/// points (36 px → 18 pt, the usual menu-bar glyph).
pub fn createStatusItem(rgba: []const u8, w: c_int, h: c_int, tooltip: [:0]const u8, on_click: zigui.Callback) bool {
    if (builtin.os.tag != .macos) return false;
    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    return cocoa.createStatusItem(rgba, w, h, tooltip, on_click);
}

pub fn destroyStatusItem() void {
    if (builtin.os.tag == .macos) cocoa.destroyStatusItem();
}

/// Run the app. `body` is invoked each frame to (re)build the view tree from the
/// current application state; state mutations triggered by events cause the next
/// frame to reflect the change. When `panel` is non-null, a hidden borderless
/// window hosting `panel.body` is created too; `showPanel()` opens it under the
/// pointer (a status-item click is the usual trigger).
pub fn run(
    gpa: std.mem.Allocator,
    comptime AppState: type,
    st: *AppState,
    cfg: Config,
    comptime body: fn (*AppState) zigui.View,
    comptime panel: ?PanelSpec(AppState),
) !void {
    // A hide-to-tray app must not quit when its last visible window is closed:
    // SDL would send SDL_EVENT_QUIT itself, before our close handler hides it.
    if (cfg.hide_on_close) _ = c.SDL_SetHint(c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
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
    if (cfg.unified_titlebar and builtin.os.tag == .macos) cocoa.unifyTitlebar(window);
    if (cfg.menus.len > 0 and builtin.os.tag == .macos) cocoa.setMenuBar(cfg.menus);
    if (cfg.drag_band > 0) {
        g_drag_band = cfg.drag_band;
        _ = c.SDL_SetWindowHitTest(window, bandHitTest, null);
    }

    // Window/taskbar icon (SDL copies the surface, so we free it immediately).
    if (cfg.icon) |ic| {
        if (makeSurface(ic.rgba, ic.w, ic.h)) |surf| {
            _ = c.SDL_SetWindowIcon(window, surf);
            c.SDL_DestroySurface(surf);
        }
    }

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

    // A second, hidden window for the custom tray popover (PanelSpec). It uses
    // its own SDL_Renderer + CPU raster path, so the main window's GPU backend
    // and swapchain stay untouched.
    var panel_win: ?*c.SDL_Window = null;
    var panel_renderer: ?*c.SDL_Renderer = null;
    var panel_texture: ?*c.SDL_Texture = null;
    var panel_tex_w: c_int = 0;
    var panel_tex_h: c_int = 0;
    var panel_fb: zigui.Framebuffer = .empty;
    var panel_rgba: []u8 = &.{};
    var panel_arena = std.heap.ArenaAllocator.init(gpa);
    // Panel teardown in dependency order: texture → renderer → window.
    defer {
        if (panel_texture) |t| c.SDL_DestroyTexture(t);
        if (panel_renderer) |r| c.SDL_DestroyRenderer(r);
        if (panel_win) |w| {
            g_panel_window = null;
            g_panel_id = 0;
            g_panel_shown = false;
            c.SDL_DestroyWindow(w);
        }
        if (panel_rgba.len > 0) gpa.free(panel_rgba);
        panel_fb.deinit();
        panel_arena.deinit();
    }
    if (panel) |ps| blk: {
        const w = c.SDL_CreateWindow(
            "MLX-Serve",
            @intCast(ps.width),
            @intCast(ps.height),
            c.SDL_WINDOW_BORDERLESS | c.SDL_WINDOW_UTILITY | c.SDL_WINDOW_ALWAYS_ON_TOP | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_TRANSPARENT,
        ) orelse {
            std.log.warn("zigui: panel window failed: {s}", .{c.SDL_GetError()});
            break :blk;
        };
        panel_win = w;
        g_panel_window = w;
        g_panel_id = c.SDL_GetWindowID(w);
        panel_renderer = c.SDL_CreateRenderer(w, null) orelse c.SDL_CreateRenderer(w, "software") orelse {
            std.log.warn("zigui: panel renderer failed: {s}", .{c.SDL_GetError()});
            c.SDL_DestroyWindow(w);
            panel_win = null;
            g_panel_window = null;
            g_panel_id = 0;
            break :blk;
        };
        // Debug: ZIGUI_NO_FROST=1 leaves the glass off (for bisecting compositing artifacts).
        if (builtin.os.tag == .macos and c.SDL_getenv("ZIGUI_NO_FROST") == null) cocoa.frostWindow(w, 12);
        _ = c.SDL_HideWindow(w);
    }

    _ = c.SDL_StartTextInput(window);

    var font = zigui.Font.default();
    // Bundled monochrome emoji font, wired as a fallback so codepoints Inter
    // lacks (emoji, etc.) still render. Lives for the whole loop, so the
    // `&emoji_font.face` pointer stays valid.
    var emoji_font = zigui.Font.emoji();
    emoji_font.face.fallback = cfg.fallback_font;
    font.face.fallback = &emoji_font.face;
    var cache = zigui.GlyphCache.init(gpa, &font.face);
    defer cache.deinit();

    var icon_font = zigui.Font.icons();
    var icon_cache = zigui.GlyphCache.init(gpa, &icon_font.face);
    defer icon_cache.deinit();

    const fonts = try zigui.FontSet.create(gpa);
    defer fonts.destroy();
    if (cfg.fallback_font) |f| fonts.setFallback(f);
    g_fonts = fonts;
    defer g_fonts = null;

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
        /// Non-null for a panel frame: that body replaces the main window's.
        view_fn: ?*const fn (*AppState) zigui.View = null,
        /// Where this frame's hover point lives (main window or panel).
        hover: ?*?zigui.geometry.Point = null,
        /// Resize the window to the view tree's content height each frame
        /// (the tray popover: no scrollbars, like Swift's auto-sizing panel).
        auto_height: bool = false,
        /// Transparent panel frame: clear to alpha 0 and paint a translucent
        /// rounded background, so corners reveal the desktop behind it.
        transparent: bool = false,
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
            const fpw: f32 = @floatFromInt(pw);
            const fph: f32 = @floatFromInt(ph);
            // `display_scale` is the OS-honored content scale: it folds the HiDPI
            // backing density AND the user's display-scale setting (Windows
            // 125/150/200%, fractional scaling on Linux). The earlier `pw/lw`
            // captured only the backing density, so non-100% OS scaling was
            // ignored everywhere except macOS (where the two coincide). We lay the
            // UI out in `device_pixels / display_scale` design points and scale
            // each ×display_scale, so a control keeps its physical size on any
            // display. A 0.0 return means SDL couldn't query it — fall back to 1.
            const display_scale = c.SDL_GetWindowDisplayScale(fr.window);
            const base_scale: f32 = if (display_scale > 0) display_scale else 1;
            // Supersampling (SSAA): render into a framebuffer `ss`× larger per
            // axis, then downscale on present. This is the lever that makes text
            // crisp on a low-DPI (100%) display. Capped so the *total* device
            // scale stays ≤ 2 — a Retina/HiDPI panel already has the pixels, so
            // we never render it at 4×.
            const ss: f32 = @max(1, @min(@max(1, fr.cfg.supersample), 2 / base_scale));
            // `scale` is device-pixels-per-design-point (backing × supersample);
            // layout still happens in design points (`base_scale` only), so hit
            // regions and event mapping are unaffected by `ss`.
            const scale: f32 = base_scale * ss;
            const point_w = fpw / base_scale;
            const point_h_in = fph / base_scale;
            var point_h = point_h_in;
            // SDL mouse events arrive in logical window points; hit regions live
            // in design points. Convert by pixel_density / display_scale (== 1 on
            // macOS); `ss` cancels out since it doesn't change the design space.
            const pixel_density = fpw / @as(f32, @floatFromInt(lw));
            g_event_scale = pixel_density / base_scale;
            // The framebuffer/scene is the oversampled device size; present
            // downscales it to the window's actual pixel size (pw×ph).
            var uw: u32 = @intFromFloat(@round(fpw * ss));
            var uh: u32 = @intFromFloat(@round(fph * ss));

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
            zigui.setViewport(point_w, point_h);
            g_caret_drawn = caretPhaseOn(c.SDL_GetTicks());
            zigui.setCaretVisible(g_caret_drawn);
            zigui.beginBuild(arena);
            const root = if (fr.view_fn) |vf| vf(fr.st) else body(fr.st);
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
            ctx.fonts = g_fonts;
            ctx.hover_point = if (fr.hover) |h| h.* else null;

            // Auto-height panel: measure the tree and resize the window to it,
            // clamped to the screen's usable height. Swift's MenuBarExtra panel
            // sizes itself to its content; matching that keeps the footer
            // visible instead of scrolling inside a fixed frame.
            if (fr.auto_height) autoHeight: {
                const m = zigui.measureView(&ctx, root, .{ .width = point_w, .height = null }) catch break :autoHeight;
                var want: f32 = @max(m.height, 60);
                var bounds: c.SDL_Rect = undefined;
                const disp = c.SDL_GetDisplayForWindow(fr.window);
                if (c.SDL_GetDisplayUsableBounds(disp, &bounds)) want = @min(want, @as(f32, @floatFromInt(bounds.h)));
                const want_i: c_int = @intFromFloat(@round(want));
                if (want_i == lh) break :autoHeight;
                _ = c.SDL_SetWindowSize(fr.window, lw, want_i);
                var pw2: c_int = 0;
                var ph2: c_int = 0;
                _ = c.SDL_GetWindowSizeInPixels(fr.window, &pw2, &ph2);
                if (pw2 <= 0 or ph2 <= 0) break :autoHeight;
                point_h = @as(f32, @floatFromInt(ph2)) / base_scale;
                uw = @intFromFloat(@round(@as(f32, @floatFromInt(pw2)) * ss));
                uh = @intFromFloat(@round(@as(f32, @floatFromInt(ph2)) * ss));
                // Keep the bottom edge on screen when the panel grew.
                if (c.SDL_GetDisplayUsableBounds(disp, &bounds)) {
                    var wx: c_int = 0;
                    var wy: c_int = 0;
                    if (c.SDL_GetWindowPosition(fr.window, &wx, &wy)) {
                        const max_y = bounds.y + bounds.h - want_i;
                        if (wy > max_y) _ = c.SDL_SetWindowPosition(fr.window, wx, if (max_y < bounds.y) bounds.y else max_y);
                    }
                }
            }

            // Coverage gamma for text: a straight sRGB alpha-blend renders the
            // anti-aliased edge of light glyphs on a dark background too thin
            // (the classic "soft" custom-UI text). Gamma-correcting the coverage
            // restores weight. Dark themes lighten the edge (~0.6 ≈ the
            // gamma-correct result); light themes are left untouched (1.0) since
            // dark-on-light doesn't suffer the same thinning. Both backends apply
            // the same exponent, so software/GPU output stays pixel-matched.
            const dark_ui = theme.colors.window_background.luminance() < 0.5;
            zigui.setTextGamma(if (dark_ui) 0.6 else 1.0);

            var canvas = zigui.Canvas.init(arena);
            if (fr.transparent) {
                // The frosted NSVisualEffectView behind the SDL content view is
                // the panel's own chrome (Swift's MenuBarExtra popover). Painting
                // an opaque-ish window-background fill here would cover that
                // frost with a flat gray rectangle, so only the hairline rim is
                // drawn: every other pixel stays transparent and lets the
                // material show through.
                // Appended before renderScaled, which scales only the view's commands, so scale it here.
                canvas.strokeRoundedRect(.{ .x = 0.5 * scale, .y = 0.5 * scale, .width = (point_w - 1) * scale, .height = (point_h - 1) * scale }, 12 * scale, scale, theme.colors.separator) catch {};
            } else {
                // No background fill command here: the framebuffer's `clear` below paints
                // the window background with a fast @memset, so emitting a full-window
                // fill_rrect would just re-rasterize every pixel through the SDF path.
            }
            zigui.renderScaled(&ctx, root, .{ .x = 0, .y = 0, .width = point_w, .height = point_h }, scale, &canvas) catch {};

            if (fr.gpu_backend) |g| {
                // GPU backend: translate + replay the command list on the GPU.
                // `ss` makes it render the scene oversampled and downscale on the
                // final blit (SSAA), mirroring the software texture path below.
                const clear = if (fr.transparent) zigui.Color.transparent else theme.colors.window_background;
                if (!g.frame(arena, canvas.commands.items, clear, ss)) return false;
            } else {
                // Software backend. Persistent framebuffer + RGBA buffer:
                // reallocated only when the pixel size changes, so a
                // steady-state frame does zero pixel-buffer allocation.
                const rend = fr.renderer.?;
                fr.fb.ensureSize(fr.gpa, uw, uh) catch return false;
                fr.fb.clear(if (fr.transparent) zigui.Color.transparent else theme.colors.window_background);
                zigui.raster.render(arena, fr.fb, canvas.commands.items) catch return false;
                const need: usize = @as(usize, uw) * @as(usize, uh) * 4;
                if (fr.rgba.*.len != need) {
                    if (fr.rgba.*.len > 0) fr.gpa.free(fr.rgba.*);
                    fr.rgba.* = fr.gpa.alloc(u8, need) catch return false;
                }
                fr.fb.toRgba8(fr.rgba.*);

                // Debug: ZIGUI_PANEL_DUMP=<path> writes the transparent (panel)
                // frame's RGBA buffer once per size: u32 w, u32 h, then w*h*4
                // bytes. For offline analysis of what the app actually drew.
                if (fr.transparent) {
                    if (c.SDL_getenv("ZIGUI_PANEL_DUMP")) |pathz| {
                        const key: u64 = @as(u64, @intCast(uw)) << 32 | @as(u64, @intCast(uh));
                        if (g_dump_written != key) {
                            g_dump_written = key;
                            const path = std.mem.span(@as([*:0]const u8, @ptrCast(pathz)));
                            var threaded = std.Io.Threaded.init(fr.gpa, .{});
                            defer threaded.deinit();
                            const io = threaded.io();
                            if (std.Io.Dir.createFileAbsolute(io, path, .{})) |f| {
                                var hdr: [8]u8 = undefined;
                                std.mem.writeInt(u32, hdr[0..4], @intCast(uw), .little);
                                std.mem.writeInt(u32, hdr[4..8], @intCast(uh), .little);
                                f.writeStreamingAll(io, hdr[0..]) catch {};
                                f.writeStreamingAll(io, fr.rgba.*) catch {};
                                f.close(io);
                            } else |_| {}
                        }
                    }
                }

                // The texture is the oversampled (uw×uh) size; `SDL_RenderTexture`
                // with a null dst stretches it to the window's pixel size, and the
                // LINEAR scale mode makes that a clean SSAA downsample.
                const iuw: c_int = @intCast(uw);
                const iuh: c_int = @intCast(uh);
                if (fr.texture.* == null or fr.tex_w.* != iuw or fr.tex_h.* != iuh) {
                    if (fr.texture.*) |t| c.SDL_DestroyTexture(t);
                    fr.texture.* = c.SDL_CreateTexture(rend, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, iuw, iuh);
                    if (fr.texture.*) |t| _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
                    fr.tex_w.* = iuw;
                    fr.tex_h.* = iuh;
                }
                if (fr.transparent) {
                    if (fr.texture.*) |t| _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
                    _ = c.SDL_SetRenderDrawColor(rend, 0, 0, 0, 0);
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
        .hover = &g_hover_point,
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

    var panel_frame: ?Frame = null;
    if (panel) |ps| {
        if (panel_win) |pw| panel_frame = Frame{
            .gpa = gpa,
            .window = pw,
            .renderer = panel_renderer,
            .gpu_backend = null,
            .cache = &cache,
            .icon_cache = &icon_cache,
            .cfg = cfg,
            .st = st,
            .view_fn = ps.body,
            .hover = &g_panel_hover,
            .auto_height = true,
            .transparent = true,
            .texture = &panel_texture,
            .tex_w = &panel_tex_w,
            .tex_h = &panel_tex_h,
            .fb = &panel_fb,
            .rgba = &panel_rgba,
            .perf_freq = perf_freq,
            .stats = &stats,
            .resize_arena = &resize_arena,
            .resize_hits = &resize_hits,
            .resize_scrolls = &resize_scrolls,
        };
    }
    var panel_hits: std.ArrayList(zigui.HitRegion) = .empty;
    var panel_scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;

    while (running) {
        // Per-frame hook (e.g. refresh the system-tray menu). Runs whether or not
        // the window is visible, so the tray tracks status even when hidden.
        if (g_frame_fn) |f| f();

        // Fresh per-frame region lists (arena-backed via drawFrame); discarded at
        // the next arena reset, exactly like the pre-refactor loop. The main
        // window is skipped while hidden-to-tray; the panel draws on its own
        // arena/renderer whenever it is shown.
        var hits: std.ArrayList(zigui.HitRegion) = .empty;
        var scrolls: std.ArrayList(zigui.ScrollRegion) = .empty;
        const main_hidden = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0;
        const drew_main = if (main_hidden) false else Render.drawFrame(&frame, &arena_state, &hits, &scrolls);
        g_band_hits = if (drew_main) hits.items else &.{};

        panel_hits = .empty;
        panel_scrolls = .empty;
        const drew_panel = if (panel_frame != null and g_panel_shown)
            Render.drawFrame(&panel_frame.?, &panel_arena, &panel_hits, &panel_scrolls)
        else
            false;
        g_panel_hits = if (drew_panel) panel_hits.items else &.{};
        g_panel_scrolls = if (drew_panel) panel_scrolls.items else &.{};

        if (!drew_main and !drew_panel) {
            // Nothing drew: pump events and block efficiently. While a busy
            // predicate is set (e.g. a generation in flight), wake on a ~60fps
            // timeout so the frame hook keeps the tray status live.
            const busy_ms = busyIntervalMs();
            var ev: c.SDL_Event = undefined;
            // Cap the idle wait (`idle_wake_ms`): a hidden-to-tray window can't
            // receive an event to observe a tray callback's `running = false`,
            // so a blocking wait here hangs Quit forever.
            if (c.SDL_WaitEventTimeout(&ev, if (busy_ms != 0) @intCast(busy_ms) else idle_wake_ms)) handleEvent(&ev, &running, hits.items, scrolls.items);
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
            continue;
        }

        // Event handling. Hit/scroll regions stay in design points (renderScaled
        // leaves them unscaled); SDL reports mouse coordinates in logical window
        // points, so `handleEvent` converts via `g_event_scale` before dispatch
        // (a no-op on macOS). While animating *or* while a
        // busy predicate is set (e.g. a streaming request in flight), wake on a
        // ~60fps timeout and rebuild each frame; otherwise block for input.
        var ev: c.SDL_Event = undefined;
        // UI animations keep their own ~60fps cadence; the app's requested
        // interval (e.g. a slow spinner repaint during a heavy GPU job) paces
        // the loop only when nothing is animating.
        const app_ms = busyIntervalMs();
        const anim_busy = anim.active() or zigui.scrollbarsAnimating(c.SDL_GetTicks());
        const busy_ms: u32 = if (anim_busy) (if (app_ms == 0) 16 else @min(app_ms, 16)) else app_ms;
        if (busy_ms != 0) {
            if (c.SDL_WaitEventTimeout(&ev, @intCast(busy_ms))) handleEvent(&ev, &running, hits.items, scrolls.items);
            while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
            const now = c.SDL_GetTicks();
            const dt: f32 = @as(f32, @floatFromInt(now - last_ms)) / 1000.0;
            last_ms = now;
            anim.tick(dt);
        } else {
            // Fully idle: wait for input. A blocking SDL_WaitEvent would only
            // return on an SDL event, but a tray/menu callback flips `running`
            // (tray Quit) or updates tray state while posting none — so a bare
            // block leaves the app parked until the user's next mouse-over, and
            // hangs forever when the window is hidden. Instead wait in
            // `idle_wake_ms` slices: on a timeout re-run the frame hook (keeps
            // the tray live) and re-check `running`, WITHOUT redrawing — nothing
            // changed, so idle stays ~free (no 4 Hz repaint). Only a real event
            // breaks out to the redraw at the top of the outer loop; it
            // dispatches against the last frame's hit regions, still valid since
            // no drawFrame has reset the arena.
            while (running) {
                if (c.SDL_WaitEventTimeout(&ev, idleWaitMs())) {
                    handleEvent(&ev, &running, hits.items, scrolls.items);
                    while (c.SDL_PollEvent(&ev)) handleEvent(&ev, &running, hits.items, scrolls.items);
                    break;
                }
                if (g_frame_fn) |f| f();
                // Background work (a generation, playback) may have flipped the
                // busy cadence on: leave idle so the outer loop redraws at it.
                if (busyIntervalMs() != 0) break;
                // The caret's blink phase flipped: redraw just for it.
                if (zigui.focusedField() != null and caretPhaseOn(c.SDL_GetTicks()) != g_caret_drawn) break;
            }
            last_ms = c.SDL_GetTicks();
        }
    }
}

var g_drag_band: f32 = 0;
/// The current frame's hit regions, for `bandHitTest` (SDL calls it from inside
/// the event pump, where the loop's lists are out of reach).
var g_band_hits: []const zigui.HitRegion = &.{};

/// Empty space in the top band drags the window; anything tappable there
/// (a toolbar button, a title menu) keeps its clicks.
fn bandHitTest(_: ?*c.SDL_Window, area: [*c]const c.SDL_Point, _: ?*anyopaque) callconv(.c) c.SDL_HitTestResult {
    const p = eventPoint(@floatFromInt(area.*.x), @floatFromInt(area.*.y));
    if (p.y >= g_drag_band or zigui.contextMenuOpen()) return c.SDL_HITTEST_NORMAL;
    for (g_band_hits) |h| {
        if (h.action == .secondary) continue;
        if (p.x >= h.rect.x and p.x < h.rect.x + h.rect.width and p.y >= h.rect.y and p.y < h.rect.y + h.rect.height) return c.SDL_HITTEST_NORMAL;
    }
    return c.SDL_HITTEST_DRAGGABLE;
}

/// The bits of AppKit SDL does not expose, reached through the Objective-C runtime.
const cocoa = struct {
    const Id = ?*anyopaque;
    extern "objc" fn objc_getClass(name: [*:0]const u8) Id;
    extern "objc" fn sel_registerName(name: [*:0]const u8) Id;
    extern "objc" fn objc_msgSend() void;

    extern "objc" fn objc_allocateClassPair(superclass: Id, name: [*:0]const u8, extra: usize) Id;
    extern "objc" fn objc_registerClassPair(cls: Id) void;
    extern "objc" fn class_addMethod(cls: Id, name: Id, imp: *const anyopaque, types: [*:0]const u8) u8;

    fn send(comptime R: type, target: Id, sel: [*:0]const u8, args: anytype) R {
        const Fn = switch (args.len) {
            0 => fn (Id, Id) callconv(.c) R,
            1 => fn (Id, Id, @TypeOf(args[0])) callconv(.c) R,
            3 => fn (Id, Id, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) R,
            else => @compileError("zero, one or three arguments"),
        };
        const f: *const Fn = @ptrCast(&objc_msgSend);
        return @call(.auto, f, .{ target, sel_registerName(sel) } ++ args);
    }

    /// Transparent titlebar + full-size content + hidden title, and an empty
    /// unified toolbar so the titlebar is toolbar-height (the traffic lights
    /// sit inset, centred in a 52pt band).
    fn unifyTitlebar(window: *c.SDL_Window) void {
        const win: Id = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
        if (win == null) return;
        const full_size_content: u64 = 1 << 15;
        send(void, win, "setStyleMask:", .{send(u64, win, "styleMask", .{}) | full_size_content});
        send(void, win, "setTitlebarAppearsTransparent:", .{@as(u8, 1)});
        send(void, win, "setTitleVisibility:", .{@as(i64, 1)}); // NSWindowTitleHidden
        const toolbar = send(Id, objc_getClass("NSToolbar"), "new", .{});
        send(void, toolbar, "setShowsBaselineSeparator:", .{@as(u8, 0)});
        send(void, win, "setToolbar:", .{toolbar});
        send(void, win, "setToolbarStyle:", .{@as(i64, 3)}); // NSWindowToolbarStyleUnified
    }

    /// Mark this app's menu-bar icons as template images, so macOS draws them
    /// in the menu bar's own colour (white on a dark bar, black on a light
    /// one) like every native status item. SDL hands AppKit a plain image.
    /// The items live in this process's NSStatusBarWindows; their button is a
    /// public NSStatusBarButton.
    fn templateStatusIcons() void {
        const ns_app = send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
        const windows = send(Id, ns_app, "windows", .{});
        const button_cls = objc_getClass("NSStatusBarButton");
        const n: u64 = send(u64, windows, "count", .{});
        for (0..n) |i| {
            const win = send(Id, windows, "objectAtIndex:", .{@as(u64, i)});
            const view = send(Id, win, "contentView", .{}) orelse continue;
            templateIn(view, button_cls);
        }
    }

    fn templateIn(view: Id, button_cls: Id) void {
        if (send(u8, view, "isKindOfClass:", .{button_cls}) != 0) {
            const img = send(Id, view, "image", .{}) orelse return;
            send(void, img, "setTemplate:", .{@as(u8, 1)});
            send(void, view, "setImage:", .{img});
            return;
        }
        const subs = send(Id, view, "subviews", .{});
        const n: u64 = send(u64, subs, "count", .{});
        for (0..n) |i| templateIn(send(Id, subs, "objectAtIndex:", .{@as(u64, i)}), button_cls);
    }

    fn nsString(s: [*:0]const u8) Id {
        return send(Id, objc_getClass("NSString"), "stringWithUTF8String:", .{s});
    }

    /// Menu actions, indexed by each item's tag (they live for the process).
    var actions: std.ArrayList(zigui.Callback) = .empty;

    /// `fire:` on the one target object: run the tagged action, then wake the
    /// loop (a menu click produces no SDL event of its own).
    fn fire(_: Id, _: Id, sender: Id) callconv(.c) void {
        const tag = send(i64, sender, "tag", .{});
        if (tag >= 0 and tag < actions.items.len) {
            const cb = actions.items[@intCast(tag)];
            cb.func(cb.ctx);
        }
        wake();
    }

    fn menuTarget() Id {
        const cls = objc_allocateClassPair(objc_getClass("NSObject"), "ZiguiMenuTarget", 0) orelse return null;
        _ = class_addMethod(cls, sel_registerName("fire:"), @ptrCast(&fire), "v@:@");
        objc_registerClassPair(cls);
        return send(Id, cls, "new", .{});
    }

    // ---- status item (a plain menu-bar icon whose click opens the app's own
    // popover panel, not a native menu) --------------------------------------

    const NSSize = extern struct { width: f64, height: f64 };
    const NSPoint = extern struct { x: f64, y: f64 };
    const NSRect = extern struct { origin: NSPoint, size: NSSize };
    var status_item: Id = null;
    var status_target: Id = null;
    var status_cb: ?zigui.Callback = null;

    fn statusClick(_: Id, _: Id, _: Id) callconv(.c) void {
        if (status_cb) |cb| cb.call();
        wake();
    }

    /// `initWithBitmapDataPlanes:...` takes ten arguments; the generic `send`
    /// helper only covers zero/one/three, so it gets its own signature.
    fn repInit(target: Id, planes: ?*anyopaque, w: i64, h: i64, bps: i64, spp: i64, alpha: u8, planar: u8, cs: Id, fmt: u64, bpr: i64, bpp: i64) Id {
        const Fn = fn (Id, Id, ?*anyopaque, i64, i64, i64, i64, u8, u8, Id, u64, i64, i64) callconv(.c) Id;
        const f: *const Fn = @ptrCast(&objc_msgSend);
        return @call(.auto, f, .{
            target,
            sel_registerName("initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:"),
            planes, w, h, bps, spp, alpha, planar, cs, fmt, bpr, bpp,
        });
    }

    fn createStatusItem(rgba: []const u8, w: c_int, h: c_int, tooltip: [:0]const u8, on_click: zigui.Callback) bool {
        const iw: i64 = w;
        const ih: i64 = h;
        // Alpha last, straight (non-premultiplied): our RGBA buffer's layout
        // (NSAlphaNonpremultipliedBitmapFormat).
        const rep = repInit(send(Id, objc_getClass("NSBitmapImageRep"), "alloc", .{}), null, iw, ih, 8, 4, 1, 0, nsString("NSCalibratedRGBColorSpace"), 2, iw * 4, 32) orelse return false;
        const raw = send([*c]u8, rep, "bitmapData", .{});
        if (raw == null) return false;
        const dst: [*]u8 = @ptrCast(raw);
        @memcpy(dst[0 .. @as(usize, @intCast(iw * ih)) * 4], rgba);
        // The bitmap is a 2x backing store, so the image's point size is half
        // its pixel size. Sized in pixels instead, a 36 px icon would sit in
        // the menu bar as a 36 pt image — twice the bar's height, dwarfing
        // every native status item.
        const size = NSSize{ .width = @as(f64, @floatFromInt(w)) / 2.0, .height = @as(f64, @floatFromInt(h)) / 2.0 };
        const img = send(Id, send(Id, objc_getClass("NSImage"), "alloc", .{}), "initWithSize:", .{size});
        if (img == null) return false;
        send(void, img, "addRepresentation:", .{rep});
        send(void, img, "setTemplate:", .{@as(u8, 1)});
        const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
        const item = send(Id, bar, "statusItemWithLength:", .{@as(f64, -1)}); // NSVariableStatusItemLength
        if (item == null) return false;
        const button = send(Id, item, "button", .{});
        if (button == null) return false;
        send(void, button, "setImage:", .{img});
        if (tooltip.len > 0) send(void, button, "setToolTip:", .{nsString(tooltip)});
        const cls = objc_allocateClassPair(objc_getClass("NSObject"), "ZiguiStatusItemTarget", 0) orelse return false;
        _ = class_addMethod(cls, sel_registerName("click:"), @ptrCast(&statusClick), "v@:@");
        objc_registerClassPair(cls);
        const tgt = send(Id, cls, "new", .{});
        send(void, button, "setTarget:", .{tgt});
        send(void, button, "setAction:", .{sel_registerName("click:")});
        status_item = item;
        status_target = tgt;
        status_cb = on_click;
        return true;
    }

    /// Put a frosted NSVisualEffectView behind SDL's content view, so the tray
    /// panel reads as translucent glass over the desktop (Swift's
    /// MenuBarExtra window) instead of a flat translucent rectangle. The
    /// container layer clips everything to the panel's rounded corners.
    fn frostWindow(window: *c.SDL_Window, radius: f64) void {
        const win: Id = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
        if (win == null) return;
        send(void, win, "setOpaque:", .{@as(u8, 0)});
        send(void, win, "setBackgroundColor:", .{send(Id, objc_getClass("NSColor"), "clearColor", .{})});
        const view = send(Id, win, "contentView", .{}) orelse return;
        const bounds = send(NSRect, view, "bounds", .{});

        const container = send(Id, send(Id, objc_getClass("NSView"), "alloc", .{}), "initWithFrame:", .{bounds});
        send(void, container, "setWantsLayer:", .{@as(u8, 1)});
        const layer = send(Id, container, "layer", .{});
        if (layer != null) {
            send(void, layer, "setCornerRadius:", .{radius});
            send(void, layer, "setMasksToBounds:", .{@as(u8, 1)});
        }
        const effect = send(Id, send(Id, objc_getClass("NSVisualEffectView"), "alloc", .{}), "initWithFrame:", .{bounds});
        send(void, effect, "setMaterial:", .{@as(i64, 6)}); // NSVisualEffectMaterialPopover
        send(void, effect, "setBlendingMode:", .{@as(i64, 0)}); // behindWindow
        send(void, effect, "setState:", .{@as(i64, 1)}); // active
        send(void, effect, "setAutoresizingMask:", .{@as(u64, 18)}); // width|height sizable
        send(void, container, "addSubview:", .{effect});
        send(void, view, "removeFromSuperview", .{});
        send(void, view, "setAutoresizingMask:", .{@as(u64, 18)});
        send(void, container, "addSubview:", .{view});
        send(void, win, "setContentView:", .{container});
    }

    fn destroyStatusItem() void {
        if (status_item) |it| {
            const bar = send(Id, objc_getClass("NSStatusBar"), "systemStatusBar", .{});
            send(void, bar, "removeStatusItem:", .{it});
        }
        status_item = null;
        status_target = null;
        status_cb = null;
    }

    /// Keep SDL's application menu (About / Hide / Quit) and replace the rest.
    fn setMenuBar(menus: []const Menu) void {
        const ns_app = send(Id, objc_getClass("NSApplication"), "sharedApplication", .{});
        const bar = send(Id, ns_app, "mainMenu", .{}) orelse return;
        while (send(i64, bar, "numberOfItems", .{}) > 1) send(void, bar, "removeItemAtIndex:", .{@as(i64, 1)});
        const tgt = menuTarget();
        for (menus) |m| {
            const holder = send(Id, objc_getClass("NSMenuItem"), "new", .{});
            const sub = send(Id, send(Id, objc_getClass("NSMenu"), "alloc", .{}), "initWithTitle:", .{nsString(m.title)});
            for (m.items) |it| {
                if (it.title.len == 0) {
                    send(void, sub, "addItem:", .{send(Id, objc_getClass("NSMenuItem"), "separatorItem", .{})});
                    continue;
                }
                const sel = sel_registerName(if (it.selector) |s| s else "fire:");
                const item = send(Id, send(Id, objc_getClass("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{ nsString(it.title), sel, nsString(it.key) });
                if (it.key.len > 0) {
                    var mask: u64 = 1 << 20; // Command
                    if (it.shift) mask |= 1 << 17;
                    if (it.ctrl) mask |= 1 << 18;
                    if (it.option) mask |= 1 << 19;
                    send(void, item, "setKeyEquivalentModifierMask:", .{mask});
                }
                if (it.action) |cb| {
                    send(void, item, "setTag:", .{@as(i64, @intCast(actions.items.len))});
                    actions.append(std.heap.page_allocator, cb) catch continue;
                    send(void, item, "setTarget:", .{tgt});
                }
                send(void, sub, "addItem:", .{item});
            }
            send(void, holder, "setSubmenu:", .{sub});
            send(void, bar, "addItem:", .{holder});
        }
    }
};

/// SDL reports mouse coordinates in logical window points; hit/scroll regions
/// live in design points. Bring an event coordinate into region space.
fn eventPoint(x: f32, y: f32) zigui.geometry.Point {
    return .{ .x = x * g_event_scale, .y = y * g_event_scale };
}

fn handleEvent(ev: *c.SDL_Event, running: *bool, hits: []const zigui.HitRegion, scrolls: []const zigui.ScrollRegion) void {
    // With frame logging on, also log which events wake the loop (each wake
    // costs a full rebuild+raster) so redraw storms can be attributed.
    if (g_frame_log) std.debug.print("[zigui] event 0x{x}\n", .{ev.type});
    const on_panel = g_panel_id != 0 and switch (ev.type) {
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_MOTION, c.SDL_EVENT_MOUSE_WHEEL, c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_TEXT_INPUT => switch (ev.type) {
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => ev.button.windowID == g_panel_id,
            c.SDL_EVENT_MOUSE_MOTION => ev.motion.windowID == g_panel_id,
            c.SDL_EVENT_MOUSE_WHEEL => ev.wheel.windowID == g_panel_id,
            c.SDL_EVENT_KEY_DOWN => ev.key.windowID == g_panel_id,
            else => ev.text.windowID == g_panel_id,
        },
        c.SDL_EVENT_WINDOW_FOCUS_LOST, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, c.SDL_EVENT_WINDOW_MOUSE_LEAVE => ev.window.windowID == g_panel_id,
        else => false,
    };
    const h: []const zigui.HitRegion = if (on_panel) g_panel_hits else hits;
    const sc: []const zigui.ScrollRegion = if (on_panel) g_panel_scrolls else scrolls;
    switch (ev.type) {
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_MOUSE_BUTTON_DOWN => g_blink_epoch = c.SDL_GetTicks(),
        else => {},
    }
    switch (ev.type) {
        c.SDL_EVENT_QUIT => running.* = false,
        // Clicking anywhere else dismisses the popover, like a native panel.
        c.SDL_EVENT_WINDOW_FOCUS_LOST => if (on_panel) hidePanel(),
        // The close button: hide-to-tray when configured, else quit. (⌘Q still
        // sends SDL_EVENT_QUIT.)
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => if (on_panel) hidePanel() else if (g_hide_on_close) hideWindow() else {
            running.* = false;
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
            const p = eventPoint(ev.button.x, ev.button.y);
            if (ev.button.button == c.SDL_BUTTON_RIGHT) {
                // Right-click pops the text context menu when over an editable
                // field; elsewhere it just dismisses any open menu.
                if (zigui.fieldAt(h, p)) |field| {
                    zigui.openContextMenu(field, p);
                } else if (!zigui.dispatchSecondaryTap(h, p)) {
                    zigui.closeContextMenu();
                }
            } else if (blk: {
                const m = c.SDL_GetModState();
                zigui.setClickMods((m & c.SDL_KMOD_SHIFT) != 0, (m & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0);
                break :blk zigui.contextMenuOpen();
            }) {
                // A left-click while the menu is open routes to the menu (an item
                // or the dismiss region) without disturbing focus.
                _ = zigui.dispatchTap(h, p);
            } else {
                zigui.clearFocus(); // a click defocuses; dispatch may refocus a field
                zigui.endDrag(); // reset any stale drag; dispatchTap re-arms over an editor
                // In a text field, double-click selects the word and triple-click
                // selects all; any other target falls back to a normal tap.
                if (ev.button.clicks >= 3 and zigui.dispatchTripleClick(h, p)) {} else if (ev.button.clicks == 2 and zigui.dispatchDoubleClick(h, p)) {} else {
                    zigui.setTapCount(ev.button.clicks);
                    defer zigui.setTapCount(1);
                    _ = zigui.dispatchTap(h, p);
                }
            }
        },
        // Drag the mouse with the left button held to extend a text selection.
        c.SDL_EVENT_MOUSE_MOTION => {
            const mp = eventPoint(ev.motion.x, ev.motion.y);
            if (on_panel) g_panel_hover = mp else g_hover_point = mp; // drives Modifiers.hover_fill highlights
            // Track the hovered context-menu item (the loop redraws after this
            // event, so the highlight follows the cursor).
            if (zigui.contextMenuOpen()) zigui.hoverContextMenu(h, mp);
            if ((ev.motion.state & c.SDL_BUTTON_LMASK) != 0) {
                zigui.dispatchDrag(h, mp);
            }
            setTextCursor(zigui.textCursorAt(h, mp));
        },
        c.SDL_EVENT_MOUSE_BUTTON_UP => zigui.endDrag(),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => if (on_panel) {
            g_panel_hover = null;
        } else {
            g_hover_point = null;
        },
        c.SDL_EVENT_DROP_FILE => {
            if (g_drop_fn) |f| if (ev.drop.data != null) f(std.mem.span(ev.drop.data));
        },
        c.SDL_EVENT_MOUSE_WHEEL => {
            _ = zigui.dispatchScroll(sc, eventPoint(ev.wheel.mouse_x, ev.wheel.mouse_y), ev.wheel.y);
        },
        c.SDL_EVENT_TEXT_INPUT => {
            if (zigui.focusedField()) |f| {
                const s = std.mem.span(ev.text.text);
                f.insert(s) catch {};
            }
        },
        c.SDL_EVENT_KEY_DOWN => {
            // Escape dismisses the popover before anything else sees the key.
            if (on_panel and ev.key.key == c.SDLK_ESCAPE) {
                hidePanel();
                return;
            }
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
            // ⌘C with no field focused copies selected text (chat, code).
            if (zigui.focusedField() == null and ev.key.key == c.SDLK_C and (ev.key.mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0) {
                if (zigui.selectedText()) |t| setClipboardText(std.heap.page_allocator, t);
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
