//! The Linux status item: a StatusNotifierItem published over D-Bus, so a
//! click on the tray icon reaches the app as `Activate` (the macOS status-item
//! click) instead of opening a menu. SDL's tray goes through AppIndicator,
//! which answers `Activate` with an error and leaves hosts to show its menu.
//!
//! libdbus is loaded at run time (as SDL does), so the build needs no D-Bus
//! headers and a system without it falls back to SDL's tray. Setup runs on the
//! caller's thread; afterwards one detached thread owns the connection, and a
//! click crosses to the UI loop through `takeClick`.
const std = @import("std");

const Conn = opaque {};
const Msg = opaque {};
const Bool = u32;

const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    bits: c_uint = 0,
    padding: ?*anyopaque = null,
};

/// DBusMessageIter is a public struct of opaque fields: 72 bytes on 64-bit.
const Iter = extern struct { opaque_fields: [10]u64 = @splat(0) };

const HandlerResult = enum(c_int) { handled = 0, not_yet_handled = 1, need_memory = 2 };
const MessageFn = *const fn (*Conn, *Msg, ?*anyopaque) callconv(.c) HandlerResult;
const VTable = extern struct {
    unregister: ?*const anyopaque = null,
    message: MessageFn,
    pad: [4]?*const anyopaque = @splat(null),
};

const bus_session: c_int = 0;
const name_do_not_queue: c_uint = 4;
const t_int: c_int = 'i';
const t_string: c_int = 's';
const t_bool: c_int = 'b';
const t_byte: c_int = 'y';
const t_array: c_int = 'a';
const t_variant: c_int = 'v';
const t_struct: c_int = 'r';
const t_dict_entry: c_int = 'e';

/// The libdbus entry points we use, resolved from libdbus-1.so.3.
const Api = struct {
    error_init: *const fn (*Error) callconv(.c) void,
    error_free: *const fn (*Error) callconv(.c) void,
    bus_get_private: *const fn (c_int, *Error) callconv(.c) ?*Conn,
    set_exit_on_disconnect: *const fn (*Conn, Bool) callconv(.c) void,
    request_name: *const fn (*Conn, [*:0]const u8, c_uint, *Error) callconv(.c) c_int,
    add_match: *const fn (*Conn, [*:0]const u8, ?*Error) callconv(.c) void,
    add_filter: *const fn (*Conn, MessageFn, ?*anyopaque, ?*const anyopaque) callconv(.c) Bool,
    register_object_path: *const fn (*Conn, [*:0]const u8, *const VTable, ?*anyopaque, *Error) callconv(.c) Bool,
    read_write_dispatch: *const fn (*Conn, c_int) callconv(.c) Bool,
    send: *const fn (*Conn, *Msg, ?*u32) callconv(.c) Bool,
    send_with_reply_and_block: *const fn (*Conn, *Msg, c_int, *Error) callconv(.c) ?*Msg,
    new_method_call: *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Msg,
    new_method_return: *const fn (*Msg) callconv(.c) ?*Msg,
    unref: *const fn (*Msg) callconv(.c) void,
    is_method_call: *const fn (*Msg, [*:0]const u8, [*:0]const u8) callconv(.c) Bool,
    is_signal: *const fn (*Msg, [*:0]const u8, [*:0]const u8) callconv(.c) Bool,
    iter_init: *const fn (*Msg, *Iter) callconv(.c) Bool,
    iter_init_append: *const fn (*Msg, *Iter) callconv(.c) void,
    iter_get_arg_type: *const fn (*Iter) callconv(.c) c_int,
    iter_get_basic: *const fn (*Iter, *anyopaque) callconv(.c) void,
    iter_next: *const fn (*Iter) callconv(.c) Bool,
    iter_append_basic: *const fn (*Iter, c_int, *const anyopaque) callconv(.c) Bool,
    iter_append_fixed_array: *const fn (*Iter, c_int, *const anyopaque, c_int) callconv(.c) Bool,
    iter_open_container: *const fn (*Iter, c_int, ?[*:0]const u8, *Iter) callconv(.c) Bool,
    iter_close_container: *const fn (*Iter, *Iter) callconv(.c) Bool,
};

const symbols = .{
    .{ "error_init", "dbus_error_init" },
    .{ "error_free", "dbus_error_free" },
    .{ "bus_get_private", "dbus_bus_get_private" },
    .{ "set_exit_on_disconnect", "dbus_connection_set_exit_on_disconnect" },
    .{ "request_name", "dbus_bus_request_name" },
    .{ "add_match", "dbus_bus_add_match" },
    .{ "add_filter", "dbus_connection_add_filter" },
    .{ "register_object_path", "dbus_connection_try_register_object_path" },
    .{ "read_write_dispatch", "dbus_connection_read_write_dispatch" },
    .{ "send", "dbus_connection_send" },
    .{ "send_with_reply_and_block", "dbus_connection_send_with_reply_and_block" },
    .{ "new_method_call", "dbus_message_new_method_call" },
    .{ "new_method_return", "dbus_message_new_method_return" },
    .{ "unref", "dbus_message_unref" },
    .{ "is_method_call", "dbus_message_is_method_call" },
    .{ "is_signal", "dbus_message_is_signal" },
    .{ "iter_init", "dbus_message_iter_init" },
    .{ "iter_init_append", "dbus_message_iter_init_append" },
    .{ "iter_get_arg_type", "dbus_message_iter_get_arg_type" },
    .{ "iter_get_basic", "dbus_message_iter_get_basic" },
    .{ "iter_next", "dbus_message_iter_next" },
    .{ "iter_append_basic", "dbus_message_iter_append_basic" },
    .{ "iter_append_fixed_array", "dbus_message_iter_append_fixed_array" },
    .{ "iter_open_container", "dbus_message_iter_open_container" },
    .{ "iter_close_container", "dbus_message_iter_close_container" },
};

var api: Api = undefined;
var bus_name: [64:0]u8 = @splat(0);
var title: [128:0]u8 = @splat(0);
/// The icon as ARGB32 in network byte order, the StatusNotifierItem pixmap format.
var argb: []u8 = &.{};
var icon_w: i32 = 0;
var icon_h: i32 = 0;

/// The last click, handed from the D-Bus thread to the UI loop.
var click_pending = std.atomic.Value(bool).init(false);
var click_x = std.atomic.Value(i32).init(0);
var click_y = std.atomic.Value(i32).init(0);
var on_click_wake: *const fn () void = undefined;

const item_path = "/StatusNotifierItem";
const item_iface = "org.kde.StatusNotifierItem";
const props_iface = "org.freedesktop.DBus.Properties";
const watcher = "org.kde.StatusNotifierWatcher";

fn load() bool {
    const lib = std.c.dlopen("libdbus-1.so.3", .{ .LAZY = true }) orelse return false;
    inline for (symbols) |s| {
        const p = std.c.dlsym(lib, s[1]) orelse return false;
        @field(api, s[0]) = @ptrCast(@alignCast(p));
    }
    return true;
}

/// Publish the item and register it with the desktop's StatusNotifierWatcher.
/// False when there is no D-Bus or no tray host listening; the caller then
/// falls back to SDL's tray. `wake` is called (from the D-Bus thread) after a
/// click, so a UI loop blocked on input picks it up via `takeClick`.
pub fn create(gpa: std.mem.Allocator, rgba: []const u8, w: c_int, h: c_int, tooltip: []const u8, wake: *const fn () void) bool {
    if (!load()) return false;
    var err: Error = .{};
    api.error_init(&err);
    defer api.error_free(&err);
    const cn = api.bus_get_private(bus_session, &err) orelse return false;
    api.set_exit_on_disconnect(cn, 0);

    _ = std.fmt.bufPrintSentinel(&bus_name, "org.kde.StatusNotifierItem-{d}-1", .{std.os.linux.getpid()}, 0) catch return false;
    if (api.request_name(cn, &bus_name, name_do_not_queue, &err) != 1) return false;
    const vtable = struct {
        const v: VTable = .{ .message = handle };
    };
    if (api.register_object_path(cn, item_path, &vtable.v, null, &err) == 0) return false;

    // Pixmap first: the watcher asks for properties as soon as we register.
    argb = gpa.alloc(u8, rgba.len) catch return false;
    var i: usize = 0;
    while (i + 3 < rgba.len) : (i += 4) {
        argb[i] = rgba[i + 3];
        argb[i + 1] = rgba[i];
        argb[i + 2] = rgba[i + 1];
        argb[i + 3] = rgba[i + 2];
    }
    icon_w = w;
    icon_h = h;
    const n = @min(tooltip.len, title.len);
    @memcpy(title[0..n], tooltip[0..n]);
    on_click_wake = wake;

    const reg = registerMessage() orelse return false;
    defer api.unref(reg);
    const reply = api.send_with_reply_and_block(cn, reg, 2000, &err) orelse return false;
    api.unref(reply);

    // A restarted tray host (the panel reloading) forgets the item: register
    // again when the watcher's name gets a new owner.
    api.add_match(cn, "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ watcher ++ "'", null);
    _ = api.add_filter(cn, watcherChanged, null, null);

    const t = std.Thread.spawn(.{}, serve, .{cn}) catch return false;
    t.detach();
    return true;
}

/// The click since the last call, if any: the screen position the host
/// reported, or (0, 0) when it sends none (COSMIC).
pub fn takeClick() ?[2]i32 {
    if (!click_pending.swap(false, .acquire)) return null;
    return .{ click_x.load(.monotonic), click_y.load(.monotonic) };
}

fn serve(cn: *Conn) void {
    while (api.read_write_dispatch(cn, -1) != 0) {}
}

fn registerMessage() ?*Msg {
    const msg = api.new_method_call(watcher, "/StatusNotifierWatcher", watcher, "RegisterStatusNotifierItem") orelse return null;
    var it: Iter = .{};
    api.iter_init_append(msg, &it);
    const name_ptr: [*:0]const u8 = &bus_name;
    _ = api.iter_append_basic(&it, t_string, @ptrCast(&name_ptr));
    return msg;
}

fn watcherChanged(cn: *Conn, msg: *Msg, _: ?*anyopaque) callconv(.c) HandlerResult {
    if (api.is_signal(msg, "org.freedesktop.DBus", "NameOwnerChanged") == 0) return .not_yet_handled;
    // Arguments: name, old owner, new owner; an empty new owner means it left.
    var it: Iter = .{};
    var new_owner: [*:0]const u8 = "";
    if (api.iter_init(msg, &it) != 0 and api.iter_next(&it) != 0 and api.iter_next(&it) != 0 and api.iter_get_arg_type(&it) == t_string)
        api.iter_get_basic(&it, @ptrCast(&new_owner));
    if (new_owner[0] != 0) if (registerMessage()) |reg| {
        _ = api.send(cn, reg, null);
        api.unref(reg);
    };
    return .not_yet_handled;
}

fn handle(cn: *Conn, msg: *Msg, _: ?*anyopaque) callconv(.c) HandlerResult {
    if (api.is_method_call(msg, item_iface, "Activate") != 0 or
        api.is_method_call(msg, item_iface, "SecondaryActivate") != 0 or
        api.is_method_call(msg, item_iface, "ContextMenu") != 0)
    {
        var it: Iter = .{};
        var x: i32 = 0;
        var y: i32 = 0;
        if (api.iter_init(msg, &it) != 0 and api.iter_get_arg_type(&it) == t_int) {
            api.iter_get_basic(&it, &x);
            if (api.iter_next(&it) != 0 and api.iter_get_arg_type(&it) == t_int) api.iter_get_basic(&it, &y);
        }
        click_x.store(x, .monotonic);
        click_y.store(y, .monotonic);
        click_pending.store(true, .release);
        on_click_wake();
        return replyEmpty(cn, msg);
    }
    if (api.is_method_call(msg, item_iface, "Scroll") != 0 or
        api.is_method_call(msg, item_iface, "ProvideXdgActivationToken") != 0)
        return replyEmpty(cn, msg);
    if (api.is_method_call(msg, props_iface, "GetAll") != 0) {
        const reply = api.new_method_return(msg) orelse return .need_memory;
        defer api.unref(reply);
        var it: Iter = .{};
        api.iter_init_append(reply, &it);
        var dict: Iter = .{};
        _ = api.iter_open_container(&it, t_array, "{sv}", &dict);
        for (prop_names) |name| {
            var entry: Iter = .{};
            _ = api.iter_open_container(&dict, t_dict_entry, null, &entry);
            appendString(&entry, name);
            appendProp(&entry, name);
            _ = api.iter_close_container(&dict, &entry);
        }
        _ = api.iter_close_container(&it, &dict);
        _ = api.send(cn, reply, null);
        return .handled;
    }
    if (api.is_method_call(msg, props_iface, "Get") != 0) {
        var it: Iter = .{};
        var name: [*:0]const u8 = "";
        if (api.iter_init(msg, &it) != 0 and api.iter_next(&it) != 0 and api.iter_get_arg_type(&it) == t_string)
            api.iter_get_basic(&it, @ptrCast(&name));
        const prop = std.mem.span(name);
        for (prop_names) |p| if (std.mem.eql(u8, p, prop)) {
            const reply = api.new_method_return(msg) orelse return .need_memory;
            defer api.unref(reply);
            var out: Iter = .{};
            api.iter_init_append(reply, &out);
            appendProp(&out, p);
            _ = api.send(cn, reply, null);
            return .handled;
        };
    }
    // libdbus answers anything else with UnknownMethod.
    return .not_yet_handled;
}

fn replyEmpty(cn: *Conn, msg: *Msg) HandlerResult {
    const reply = api.new_method_return(msg) orelse return .need_memory;
    _ = api.send(cn, reply, null);
    api.unref(reply);
    return .handled;
}

/// No `Menu`: hosts then send `Activate`/`ContextMenu` for both buttons.
const prop_names = [_][:0]const u8{ "Category", "Id", "Title", "Status", "ItemIsMenu", "IconPixmap", "ToolTip" };

/// Append property `name` as a variant.
fn appendProp(it: *Iter, name: []const u8) void {
    const sig: [:0]const u8 = if (std.mem.eql(u8, name, "ItemIsMenu"))
        "b"
    else if (std.mem.eql(u8, name, "IconPixmap"))
        "a(iiay)"
    else if (std.mem.eql(u8, name, "ToolTip"))
        "(sa(iiay)ss)"
    else
        "s";
    var v: Iter = .{};
    _ = api.iter_open_container(it, t_variant, sig, &v);
    if (std.mem.eql(u8, name, "Category")) {
        appendString(&v, "ApplicationStatus");
    } else if (std.mem.eql(u8, name, "Id")) {
        appendString(&v, "serve-app");
    } else if (std.mem.eql(u8, name, "Title")) {
        appendString(&v, std.mem.sliceTo(&title, 0));
    } else if (std.mem.eql(u8, name, "Status")) {
        appendString(&v, "Active");
    } else if (std.mem.eql(u8, name, "ItemIsMenu")) {
        const no: Bool = 0;
        _ = api.iter_append_basic(&v, t_bool, &no);
    } else if (std.mem.eql(u8, name, "IconPixmap")) {
        appendPixmaps(&v, true);
    } else if (std.mem.eql(u8, name, "ToolTip")) {
        var tip: Iter = .{};
        _ = api.iter_open_container(&v, t_struct, null, &tip);
        appendString(&tip, "");
        appendPixmaps(&tip, false);
        appendString(&tip, std.mem.sliceTo(&title, 0));
        appendString(&tip, "");
        _ = api.iter_close_container(&v, &tip);
    }
    _ = api.iter_close_container(it, &v);
}

/// An `a(iiay)` holding the icon, or empty.
fn appendPixmaps(it: *Iter, with_icon: bool) void {
    var arr: Iter = .{};
    _ = api.iter_open_container(it, t_array, "(iiay)", &arr);
    if (with_icon) {
        var px: Iter = .{};
        _ = api.iter_open_container(&arr, t_struct, null, &px);
        _ = api.iter_append_basic(&px, t_int, &icon_w);
        _ = api.iter_append_basic(&px, t_int, &icon_h);
        var bytes: Iter = .{};
        _ = api.iter_open_container(&px, t_array, "y", &bytes);
        const ptr: [*]const u8 = argb.ptr;
        _ = api.iter_append_fixed_array(&bytes, t_byte, @ptrCast(&ptr), @intCast(argb.len));
        _ = api.iter_close_container(&px, &bytes);
        _ = api.iter_close_container(&arr, &px);
    }
    _ = api.iter_close_container(it, &arr);
}

fn appendString(it: *Iter, s: []const u8) void {
    var buf: [256:0]u8 = @splat(0);
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    const p: [*:0]const u8 = &buf;
    _ = api.iter_append_basic(it, t_string, @ptrCast(&p));
}
