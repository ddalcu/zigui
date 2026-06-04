//! The v1 milestone demo: a macOS-like Settings screen exercising toggles,
//! sliders, a stepper, a text field, a progress bar, grouped "cards", and live
//! two-way state binding. Run with `zig build settings`.

const std = @import("std");
const zigui = @import("zigui");
const app = @import("zigui_app");

const t = zigui.default_theme;

const AppState = struct {
    wifi: zigui.State(bool),
    bluetooth: zigui.State(bool),
    notifications: zigui.State(bool),
    brightness: zigui.State(f32),
    volume: zigui.State(f32),
    copies: zigui.State(i64),
    appearance: zigui.State(i64),
    name: zigui.TextFieldState,
};

const appearance_options = [_][]const u8{ "Light", "Dark", "Auto" };

/// A label on the leading edge with a control pushed to the trailing edge.
fn settingRow(title: []const u8, control: zigui.View) zigui.View {
    return zigui.HStack(.{ zigui.Text(title), zigui.Spacer(), control }).frameMaxWidth();
}

/// A grouped, rounded "card" container like macOS settings sections.
fn card(content: zigui.View) zigui.View {
    return content
        .padding(14)
        .background(t.colors.control_background)
        .cornerRadius(10)
        .border(t.colors.separator, t.metrics.hairline)
        .frameMaxWidth();
}

fn body(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.Text("Settings").font(.large_title).frameMaxWidth(),

        card(zigui.VStack(.{
            settingRow("Wi‑Fi", zigui.Toggle("", st.wifi.binding())),
            zigui.Divider(),
            settingRow("Bluetooth", zigui.Toggle("", st.bluetooth.binding())),
            zigui.Divider(),
            settingRow("Notifications", zigui.Toggle("", st.notifications.binding())),
        }).spacing(10)),

        card(zigui.VStack(.{
            settingRow("Brightness", zigui.Slider(st.brightness.binding(), 0, 1).frameWidth(180)),
            zigui.Divider(),
            settingRow("Volume", zigui.Slider(st.volume.binding(), 0, 1).frameWidth(180)),
        }).spacing(10)),

        card(zigui.VStack(.{
            settingRow("Appearance", zigui.Picker(st.appearance.binding(), &appearance_options).frameWidth(220)),
            zigui.Divider(),
            settingRow("Name", zigui.TextField("Your name", &st.name).frameWidth(200)),
            zigui.Divider(),
            settingRow("Copies", zigui.Stepper("", st.copies.binding(), 0, 99, 1)),
        }).spacing(10)),

        card(zigui.VStack(.{
            zigui.Text("Storage — 62% used")
                .foreground(t.colors.secondary_label)
                .frameMaxWidth(),
            zigui.ProgressView(0.62).frameMaxWidth(),
        }).spacing(8)),

        zigui.Spacer(),
    }).spacing(16).padding(20).frameMaxWidth();
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var st = AppState{
        .wifi = zigui.State(bool).init(alloc, true),
        .bluetooth = zigui.State(bool).init(alloc, false),
        .notifications = zigui.State(bool).init(alloc, true),
        .brightness = zigui.State(f32).init(alloc, 0.7),
        .volume = zigui.State(f32).init(alloc, 0.4),
        .copies = zigui.State(i64).init(alloc, 1),
        .appearance = zigui.State(i64).init(alloc, 0),
        .name = zigui.TextFieldState.init(alloc),
    };
    defer {
        st.wifi.deinit();
        st.bluetooth.deinit();
        st.notifications.deinit();
        st.brightness.deinit();
        st.volume.deinit();
        st.copies.deinit();
        st.appearance.deinit();
        st.name.deinit();
    }
    try app.run(alloc, AppState, &st, .{ .title = "zigui — Settings", .width = 460, .height = 620 }, body);
}
