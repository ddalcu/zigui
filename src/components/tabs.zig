//! Tabbed container: a segmented control on top, a hairline, then the selected
//! tab's content. Pure composition — the bar is a `Picker` over the tab labels,
//! so selecting a segment drives the same interaction (and styling) as `Picker`.

const std = @import("std");
const view = @import("../view/view.zig");

const View = view.View;
const Binding = view.Binding;

/// One page of a `TabView`: a title for its tab-bar segment plus the content
/// shown when that tab is selected.
pub const Tab = struct { label: []const u8, content: View };

/// A tabbed container: a centered segmented control at the top, a hairline, then
/// the selected tab's content filling the space below. The bar is a `Picker`
/// over the tab labels, so tapping a segment drives the same `.select`
/// interaction as `Picker` (and the `selection` binding is what the body
/// switches on). Rebuilt each frame, so "switching tabs" is just the binding
/// changing.
pub fn TabView(selection: Binding(i64), tabs: []const Tab) View {
    const n = tabs.len;
    if (n == 0) return view.Empty();
    const hi: i64 = @intCast(n - 1);
    const sel: usize = @intCast(std.math.clamp(selection.get(), 0, hi));
    const labels = view.buildAlloc().alloc([]const u8, n) catch @panic("oom");
    for (tabs, 0..) |tab, i| labels[i] = tab.label;
    // Center the segmented control like a macOS tab bar (it sizes to its content).
    const bar = view.HStack(.{ view.Spacer(), view.Picker(selection, labels), view.Spacer() })
        .paddingInsets(.{ .top = 6, .leading = 8, .bottom = 6, .trailing = 8 })
        .frameMaxWidth();
    return view.VStack(.{
        bar,
        view.Divider(),
        tabs[sel].content.frameMaxWidth().frameMaxHeight(),
    }).spacing(0);
}
