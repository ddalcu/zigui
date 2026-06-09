//! Lazy grids: `LazyVGrid`/`LazyHGrid` lay items into even tracks by
//! composition (a stack of stacks), so they need no new layout primitive. Short
//! final rows/columns are padded with invisible cells to keep tracks aligned.

const view = @import("../view/view.zig");

const View = view.View;

/// A grid that grows vertically: `items` are mapped to cells via `mapFn` and
/// laid out left-to-right, top-to-bottom into `columns` even columns. Built by
/// composition — a `VStack` of `HStack` rows. Each cell is `.frameMaxWidth()` so
/// columns share width evenly; the trailing slots of a short final row are
/// filled with invisible cells so every column stays aligned. `spacing` applies
/// between both rows and columns.
pub fn LazyVGrid(columns: usize, spc: f32, items: anytype, comptime mapFn: anytype) View {
    const cols = if (columns == 0) 1 else columns;
    const n = items.len;
    const rows = if (n == 0) 0 else (n + cols - 1) / cols; // ceil(n/cols)
    const row_views = view.buildAlloc().alloc(View, rows) catch @panic("oom");
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const cells = view.buildAlloc().alloc(View, cols) catch @panic("oom");
        var ci: usize = 0;
        while (ci < cols) : (ci += 1) {
            const idx = r * cols + ci;
            cells[ci] = if (idx < n) mapFn(items[idx]).frameMaxWidth() else view.Empty().frameMaxWidth();
        }
        row_views[r] = view.makeStackFromSlice(.horizontal, spc, .center, cells);
    }
    return view.makeStackFromSlice(.vertical, spc, .center, row_views);
}

/// A grid that grows horizontally: the transpose of `LazyVGrid`. `items` fill
/// `rows` even rows top-to-bottom, then wrap to the next column. Built as an
/// `HStack` of `VStack` columns; each cell is `.frameMaxHeight()`.
pub fn LazyHGrid(rows: usize, spc: f32, items: anytype, comptime mapFn: anytype) View {
    const rws = if (rows == 0) 1 else rows;
    const n = items.len;
    const cols = if (n == 0) 0 else (n + rws - 1) / rws; // ceil(n/rows)
    const col_views = view.buildAlloc().alloc(View, cols) catch @panic("oom");
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const cells = view.buildAlloc().alloc(View, rws) catch @panic("oom");
        var ri: usize = 0;
        while (ri < rws) : (ri += 1) {
            const idx = col * rws + ri;
            cells[ri] = if (idx < n) mapFn(items[idx]).frameMaxHeight() else view.Empty().frameMaxHeight();
        }
        col_views[col] = view.makeStackFromSlice(.vertical, spc, .center, cells);
    }
    return view.makeStackFromSlice(.horizontal, spc, .center, col_views);
}
