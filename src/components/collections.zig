//! macOS-style collection views: a source-list `Sidebar`, a `RadioGroup`, and a
//! multi-column `Table`. All pure composition over the view primitives;
//! selection reuses `selectAction`, and accent/hover tints come from the
//! build-time theme tokens (`view.buildTokens()`).

const view = @import("../view/view.zig");
const Color = @import("../render/color.zig").Color;
const icons = @import("../icons.zig");

const View = view.View;
const Binding = view.Binding;

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

/// One row of a `Sidebar`: a title, an optional leading icon, and an optional
/// second `detail` line (a chat-list style subtitle). Mirrors SwiftUI's
/// `Label(item, systemImage:)` rows in a `.sidebar`-styled `List`.
pub const SidebarItem = struct {
    label: []const u8,
    icon: ?icons.Icon = null,
    detail: ?[]const u8 = null,
};

/// How a `Sidebar` highlights its selection: `neutral` is the grey wash of
/// macOS settings-style source lists; `prominent` is the vivid accent row of
/// content lists (Mail, Notes, chat apps).
pub const SidebarStyle = enum { neutral, prominent };

/// A macOS 26 source-list sidebar: a vertical list of selectable rows with a
/// rounded "liquid glass" selection highlight, a leading icon, and a live hover
/// fill. Pure composition — each row is an `HStack` with an `onTap(selectAction)`
/// that drives `selection`. Drop it inside a `NavigationSplitView`'s sidebar pane
/// (ideally over a `Material`).
pub fn Sidebar(items: []const SidebarItem, selection: Binding(i64)) View {
    return SidebarStyled(items, selection, .neutral);
}

/// `Sidebar` with an explicit selection style (see `SidebarStyle`). Rows with a
/// `detail` subtitle render as two lines (chat-list style).
pub fn SidebarStyled(items: []const SidebarItem, selection: Binding(i64), style: SidebarStyle) View {
    const bt = view.buildTokens();
    const rows = view.buildAlloc().alloc(View, items.len) catch @panic("oom");
    for (items, 0..) |item, i| {
        const is_sel = selection.get() == @as(i64, @intCast(i));
        const prominent_sel = is_sel and style == .prominent;
        // Allocate the row's children in the build arena — `makeStackFromSlice`
        // keeps the slice, so a stack-local array would dangle after we return.
        const contents = view.buildAlloc().alloc(View, 3) catch @panic("oom");
        var k: usize = 0;
        if (item.icon) |ic| {
            contents[k] = view.Icon(ic, 16, if (prominent_sel) bt.on_accent else null);
            k += 1;
        }
        var title = view.Text(item.label);
        if (prominent_sel) title = title.foreground(bt.on_accent);
        if (item.detail) |d| {
            var sub = view.Text(d).font(.subheadline);
            sub = sub.foreground(if (prominent_sel) bt.on_accent.withAlpha(0.75) else bt.secondary_label);
            contents[k] = view.makeStack(.vertical, 2, .leading, .{ title, sub });
        } else {
            contents[k] = title;
        }
        k += 1;
        contents[k] = view.Spacer();
        k += 1;
        // Native sidebar rows are 32pt tall (16pt line + 8pt above/below).
        const vpad: f32 = if (item.detail != null) 7 else 8;
        var rowv = view.makeStackFromSlice(.horizontal, 8, .center, contents[0..k])
            .paddingInsets(.{ .top = vpad, .leading = 10, .bottom = vpad, .trailing = 8 })
            .frameMaxWidth()
            .cornerRadius(if (style == .prominent) 10 else 6)
            .onTap(view.selectAction(selection, @intCast(i)));
        if (is_sel) {
            // Neutral grey wash (settings source lists) or vivid accent
            // (content lists), per the style.
            rowv = rowv.background(if (style == .prominent) bt.selection else bt.quaternary_fill);
        } else {
            rowv = rowv.hoverFill(bt.hover);
        }
        rows[i] = rowv;
    }
    return view.makeStackFromSlice(.vertical, 2, .leading, rows).frameMaxWidth();
}

// ---------------------------------------------------------------------------
// RadioGroup
// ---------------------------------------------------------------------------

/// A vertical radio-button group bound to a selected index (SwiftUI's
/// `.pickerStyle(.radioGroup)`). Pure composition: each option is a row with a
/// concentric-circle indicator (a filled accent dot when selected) and a tap that
/// sets `selection`.
pub fn RadioGroup(selection: Binding(i64), options: []const []const u8) View {
    const rows = view.buildAlloc().alloc(View, options.len) catch @panic("oom");
    for (options, 0..) |opt, i| {
        const is_sel = selection.get() == @as(i64, @intCast(i));
        rows[i] = view.HStack(.{
            radioIndicator(is_sel),
            view.Text(opt),
            view.Spacer(),
        }).spacing(8)
            .frameMaxWidth()
            .onTap(view.selectAction(selection, @intCast(i)));
    }
    return view.makeStackFromSlice(.vertical, 8, .leading, rows).frameMaxWidth();
}

/// The 16×16 radio dot: an accent-filled disc with a white center when selected,
/// or a hollow ring when not. Built from layered `Circle`s (which fill, centered,
/// inside a `ZStack`).
fn radioIndicator(selected: bool) View {
    const bt = view.buildTokens();
    if (selected) {
        return view.ZStack(.{
            view.Circle(bt.selection).frame(14, 14),
            view.Circle(bt.on_accent).frame(5, 5),
        }).frame(14, 14);
    }
    return view.ZStack(.{
        view.Circle(Color.black.withAlpha(0.22)).frame(14, 14),
        view.Circle(Color.white).frame(12, 12),
    }).frame(14, 14);
}

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

/// One column of a `Table`: a header title and the width the column occupies. A
/// `null` width makes the column flexible (it shares the leftover space evenly
/// with the other flexible columns).
pub const TableColumn = struct { title: []const u8, width: ?f32 = null };

/// A multi-column data table (SwiftUI `Table`): a header row over scrollable data
/// rows, with an optional single-selection binding that highlights the selected
/// row. `rows[r][c]` is the text for row `r`, column `c`. Pure composition over
/// stacks; selectable rows reuse `selectAction`. Wrap it in a fixed `.frameHeight`
/// to get the scrollable, bordered look.
pub fn Table(columns: []const TableColumn, rows: []const []const []const u8, selection: ?Binding(i64)) View {
    const bt = view.buildTokens();
    // Header
    const header_cells = view.buildAlloc().alloc(View, columns.len) catch @panic("oom");
    for (columns, 0..) |col, c| header_cells[c] = tableCell(view.Text(col.title).font(.subheadline), col.width, true);
    const header = view.makeStackFromSlice(.horizontal, 0, .center, header_cells)
        .paddingInsets(.{ .top = 5, .leading = 8, .bottom = 5, .trailing = 8 })
        .frameMaxWidth();

    // Body rows
    const row_views = view.buildAlloc().alloc(View, rows.len) catch @panic("oom");
    for (rows, 0..) |row, r| {
        const cells = view.buildAlloc().alloc(View, columns.len) catch @panic("oom");
        const is_sel = if (selection) |s| s.get() == @as(i64, @intCast(r)) else false;
        const fg: ?Color = if (is_sel) bt.on_accent else null;
        for (columns, 0..) |col, c| {
            const txt = if (c < row.len) row[c] else "";
            var cellv = view.Text(txt);
            if (fg) |fc| cellv = cellv.foreground(fc);
            cells[c] = tableCell(cellv, col.width, false);
        }
        var rv = view.makeStackFromSlice(.horizontal, 0, .center, cells)
            .paddingInsets(.{ .top = 5, .leading = 8, .bottom = 5, .trailing = 8 })
            .frameMaxWidth();
        if (selection) |s| {
            rv = rv.onTap(view.selectAction(s, @intCast(r)));
            if (is_sel) {
                rv = rv.background(bt.selection);
            } else if (r % 2 == 1) {
                // Subtle zebra striping like a macOS table.
                rv = rv.background(bt.row_stripe);
            }
        } else if (r % 2 == 1) {
            rv = rv.background(bt.row_stripe);
        }
        row_views[r] = rv;
    }
    const body = view.makeStackFromSlice(.vertical, 0, .leading, row_views).frameMaxWidth();

    return view.VStack(.{
        header,
        view.Divider(),
        view.ScrollView(body).frameMaxWidth().frameMaxHeight(),
    }).spacing(0).frameMaxWidth();
}

fn tableCell(content: View, width: ?f32, leading: bool) View {
    _ = leading;
    // Left-align the cell's content (macOS tables are leading-aligned); the frame
    // default centers, so a trailing Spacer pushes content to the leading edge.
    const v = view.HStack(.{ content, view.Spacer() });
    if (width) |w| return v.frameWidth(w);
    return v.frameMaxWidth();
}

// ---------------------------------------------------------------------------
// DataTable — a sortable table whose cells are arbitrary views
// ---------------------------------------------------------------------------

/// Sort direction for a `DataTable` column.
pub const SortDir = enum { ascending, descending };

/// Which column a `DataTable` is sorted by, and in which direction. `index` is
/// the column's position in the `columns` slice (-1 = unsorted). Keep this in app
/// `State` and pass `.binding()` to `DataTable`: the table flips it when a
/// sortable header is clicked, and the app re-sorts its rows to match. A fresh
/// column defaults to `.descending` (largest / most / newest first); clicking the
/// active column again toggles the direction.
pub const SortColumn = struct { index: i64 = -1, dir: SortDir = .descending };

/// One column of a `DataTable`. `width` of `null` makes the column flexible (it
/// shares the leftover width evenly with the other flexible columns). `sortable`
/// makes the header clickable — it toggles the table's `sort` binding and shows a
/// direction chevron when active. `trailing` right-aligns the header and cells
/// (use it for numeric columns).
pub const DataColumn = struct {
    title: []const u8,
    width: ?f32 = null,
    sortable: bool = false,
    trailing: bool = false,
};

const SortCtx = struct { binding: Binding(SortColumn), col: i64 };

fn sortThunk(p: ?*anyopaque) void {
    const c: *SortCtx = @ptrCast(@alignCast(p.?));
    const cur = c.binding.get();
    if (cur.index == c.col) {
        c.binding.set(.{ .index = c.col, .dir = if (cur.dir == .descending) .ascending else .descending });
    } else {
        c.binding.set(.{ .index = c.col, .dir = .descending });
    }
}

/// A `Callback` that, when a sortable header is tapped, sets `binding` to sort by
/// `col` (toggling the direction if it was already the sorted column).
fn sortAction(binding: Binding(SortColumn), col: i64) view.Callback {
    const c = view.buildAlloc().create(SortCtx) catch @panic("oom");
    c.* = .{ .binding = binding, .col = col };
    return .{ .ctx = c, .func = sortThunk };
}

/// Size a cell to its column (fixed width, or flexible) and pin its content to
/// the leading edge (or trailing, for numeric columns) via the frame's alignment
/// — NOT a Spacer, so a `.truncated()` child can shrink to fill the column rather
/// than being squeezed to half-width by a competing Spacer.
fn dataCell(content: View, col: DataColumn) View {
    const framed = if (col.width) |w| content.frameWidth(w) else content.frameMaxWidth();
    return if (col.trailing) framed.frameAlign(.trailing) else framed.frameAlign(.leading);
}

fn headerCell(col: DataColumn, index: usize, sort: ?Binding(SortColumn)) View {
    const bt = view.buildTokens();
    const sortable = col.sortable and sort != null;
    const active = sortable and sort.?.get().index == @as(i64, @intCast(index));
    const dir: SortDir = if (sort) |s| s.get().dir else .descending;

    const label = view.Text(col.title).font(.subheadline)
        .foreground(if (active) bt.accent else bt.secondary_label);
    const arrow = view.Icon(if (dir == .ascending) icons.Icon.chevron_up else icons.Icon.chevron_down, 10, bt.accent);

    // Title (+ active sort arrow). `makeStackFromSlice` keeps the slice, so it must
    // live in the build arena, not on the stack. `dataCell` pins it to the column
    // edge — no Spacer needed.
    var buf: [2]View = undefined;
    var n: usize = 0;
    buf[n] = label;
    n += 1;
    if (active) {
        buf[n] = arrow;
        n += 1;
    }
    const kids = view.buildAlloc().alloc(View, n) catch @panic("oom");
    @memcpy(kids, buf[0..n]);

    var cell = dataCell(view.makeStackFromSlice(.horizontal, 4, .center, kids), col);
    if (sortable) {
        cell = cell.paddingInsets(.{ .top = 2, .leading = 4, .bottom = 2, .trailing = 4 })
            .cornerRadius(5)
            .hoverFill(bt.hover)
            .onTap(sortAction(sort.?, @intCast(index)));
    }
    return cell;
}

/// A multi-column table whose cells are arbitrary views (badges, buttons, icons —
/// not just text), with clickable, sortable headers. `rows[r][c]` is the view for
/// row `r`, column `c`; rows shorter than `columns` pad with blanks. Pass a `sort`
/// binding to enable sorting: clicking a `sortable` header updates the binding and
/// shows a direction chevron, and the app re-sorts its data to match (the table
/// renders rows in the order given — it does not reorder them itself). Pass a
/// `scroll` state to make the body wheel-scrollable (the offset persists across
/// frames); pass null for a static viewport. The fixed header sits over
/// zebra-striped body rows; wrap the result in a fixed `.frameHeight`/
/// `.frameMaxHeight` for the bordered, scrollable look.
pub fn DataTable(columns: []const DataColumn, rows: []const []const View, sort: ?Binding(SortColumn), scroll: ?*view.ScrollState) View {
    const bt = view.buildTokens();

    const header_cells = view.buildAlloc().alloc(View, columns.len) catch @panic("oom");
    for (columns, 0..) |col, c| header_cells[c] = headerCell(col, c, sort);
    const header = view.makeStackFromSlice(.horizontal, 8, .center, header_cells)
        .paddingInsets(.{ .top = 6, .leading = 8, .bottom = 6, .trailing = 8 })
        .frameMaxWidth();

    const row_views = view.buildAlloc().alloc(View, rows.len) catch @panic("oom");
    for (rows, 0..) |row, r| {
        const cells = view.buildAlloc().alloc(View, columns.len) catch @panic("oom");
        for (columns, 0..) |col, c| {
            const content = if (c < row.len) row[c] else view.Spacer();
            cells[c] = dataCell(content, col);
        }
        var rv = view.makeStackFromSlice(.horizontal, 8, .center, cells)
            .paddingInsets(.{ .top = 6, .leading = 8, .bottom = 6, .trailing = 8 })
            .frameMaxWidth();
        // Subtle zebra striping like a macOS table.
        if (r % 2 == 1) rv = rv.background(bt.row_stripe);
        row_views[r] = rv;
    }
    const body = view.makeStackFromSlice(.vertical, 0, .leading, row_views).frameMaxWidth();
    const viewport = if (scroll) |s| view.ScrollViewState(s, body) else view.ScrollView(body);

    return view.VStack(.{
        header,
        view.Divider(),
        viewport.frameMaxWidth().frameMaxHeight(),
    }).spacing(0).frameMaxWidth();
}
