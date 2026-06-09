//! `List`: a SwiftUI-style scrolling vertical container with hairline dividers
//! between rows and grouped-row padding.

const view = @import("../view/view.zig");

const View = view.View;

/// A SwiftUI-style List: a scrolling vertical container with hairline dividers
/// between rows and grouped-background styling.
pub fn List(rows: anytype) View {
    const views = view.toViews(rows);
    const flat = view.flattenGroups(views);
    // interleave dividers
    var with_dividers = view.buildAlloc().alloc(View, if (flat.len == 0) 0 else flat.len * 2 - 1) catch @panic("oom");
    var i: usize = 0;
    for (flat, 0..) |row, idx| {
        with_dividers[i] = row.paddingInsets(.{ .top = 6, .leading = 12, .bottom = 6, .trailing = 12 }).frameMaxWidth();
        i += 1;
        if (idx + 1 < flat.len) {
            with_dividers[i] = view.Divider();
            i += 1;
        }
    }
    const stack = view.makeStackFromSlice(.vertical, 0, .leading, with_dividers);
    return view.ScrollView(stack);
}
