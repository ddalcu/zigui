//! The editable-text model shared by `TextField` and `TextEditor`: a
//! `TextFieldState` (buffer + caret + selection + vertical-motion machinery) and
//! the pure UTF-8 line/column geometry it rides on. No view/render dependency
//! beyond the font metrics used for tab-aware pixel math, so it is unit-testable
//! in isolation and reused by both the single-line field and the multi-line
//! editor.

const std = @import("std");
const ttf = @import("../text/ttf.zig");
const shape = @import("../text/shape.zig");
const view = @import("../view/view.zig");

const Allocator = std.mem.Allocator;
const Callback = view.Callback;

/// Character class for word-wise selection (double-click). Runs of the same
/// class are selected together; UTF-8 multi-byte sequences count as `word` so
/// accented/CJK text groups naturally.
const CharClass = enum { word, space, other };
fn charClass(b: u8) CharClass {
    if (b >= 0x80) return .word;
    return switch (b) {
        ' ', '\t', '\n', '\r' => .space,
        'a'...'z', 'A'...'Z', '0'...'9', '_' => .word,
        else => .other,
    };
}

/// Editable text buffer + caret for a `TextField` or `TextEditor`. Owned by the
/// app (like a `State`), so editing survives across frames. Key events call its
/// methods. Beyond a caret it tracks an optional selection (`sel_anchor`) and,
/// for multi-line editors, the machinery for vertical motion and caret-follow
/// scrolling.
pub const TextFieldState = struct {
    buffer: std.ArrayList(u8) = .empty,
    caret: usize = 0, // byte index
    /// Selection anchor (byte index). When non-null and different from `caret`,
    /// the selection is the ordered range [min, max]. A plain (un-shifted) move
    /// or any edit collapses it (back to `null`).
    sel_anchor: ?usize = null,
    focused: bool = false,
    /// True for a `TextEditor` (multi-line). The event loop then inserts a
    /// newline on Enter (instead of submitting) and routes Up/Down/Home/End/Tab.
    /// Set by `paintTextEditor` each frame.
    multiline: bool = false,
    /// Preferred column (codepoints from the line start) for vertical motion, so
    /// a run of Up/Down keeps the original column across shorter lines. Reset by
    /// any horizontal move or edit.
    pref_col: ?usize = null,
    /// The caret seen at the previous paint. `TextEditor` auto-scrolls to follow
    /// the caret only when it actually moved, so the wheel can scroll freely
    /// otherwise.
    last_caret: usize = 0,
    /// Bumped on every mutation so an app can cheaply detect "modified since
    /// saved" without diffing the buffer (see `examples/edit`).
    revision: u64 = 0,
    /// The `.onSubmit` callback for this field, refreshed during paint while the
    /// field is focused so `submitFocused()` (called from the event loop on
    /// Enter) can fire it without the view tree. See `paintTextField`.
    on_submit: ?Callback = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TextFieldState {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *TextFieldState) void {
        self.buffer.deinit(self.allocator);
    }
    pub fn text(self: *const TextFieldState) []const u8 {
        return self.buffer.items;
    }
    pub fn setText(self: *TextFieldState, s: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, s);
        self.caret = self.buffer.items.len;
        self.sel_anchor = null;
        self.pref_col = null;
        self.last_caret = self.caret;
        self.revision +%= 1;
    }

    // --- selection ---------------------------------------------------------

    /// The current selection as an ordered byte range, or null when the caret is
    /// a plain insertion point (no anchor, or an empty selection).
    pub fn selectionRange(self: *const TextFieldState) ?struct { start: usize, end: usize } {
        const a = self.sel_anchor orelse return null;
        if (a == self.caret) return null;
        return .{ .start = @min(a, self.caret), .end = @max(a, self.caret) };
    }
    pub fn hasSelection(self: *const TextFieldState) bool {
        return self.selectionRange() != null;
    }
    /// The selected text as a slice into the buffer, or an empty slice when there
    /// is no selection. Borrowed — valid only until the next mutation.
    pub fn selectedText(self: *const TextFieldState) []const u8 {
        const r = self.selectionRange() orelse return self.buffer.items[0..0];
        return self.buffer.items[r.start..r.end];
    }
    pub fn selectAll(self: *TextFieldState) void {
        if (self.buffer.items.len == 0) {
            self.sel_anchor = null;
            return;
        }
        self.sel_anchor = 0;
        self.caret = self.buffer.items.len;
        self.pref_col = null;
    }
    /// Select the word (or run of whitespace/punctuation) containing the byte
    /// `index` — the double-click gesture. Leaves an ordered selection with the
    /// caret at its end.
    pub fn selectWordAt(self: *TextFieldState, index: usize) void {
        const items = self.buffer.items;
        if (items.len == 0) {
            self.sel_anchor = null;
            self.caret = 0;
            return;
        }
        var idx = @min(index, items.len);
        if (idx == items.len) idx = prevCpStart(items, idx); // classify the last char
        const cls = charClass(items[idx]);
        var start = idx;
        while (start > 0) {
            const prev = prevCpStart(items, start);
            if (charClass(items[prev]) != cls) break;
            start = prev;
        }
        var stop = idx;
        while (stop < items.len) {
            if (charClass(items[stop]) != cls) break;
            const len = std.unicode.utf8ByteSequenceLength(items[stop]) catch 1;
            stop = @min(stop + len, items.len);
        }
        self.sel_anchor = start;
        self.caret = stop;
        self.pref_col = null;
    }
    /// Delete the selected range, if any. Returns true if something was removed.
    pub fn deleteSelection(self: *TextFieldState) bool {
        const r = self.selectionRange() orelse {
            self.sel_anchor = null;
            return false;
        };
        const n = r.end - r.start;
        std.mem.copyForwards(u8, self.buffer.items[r.start..], self.buffer.items[r.end..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - n);
        self.caret = r.start;
        self.sel_anchor = null;
        self.pref_col = null;
        self.revision +%= 1;
        return true;
    }

    // --- editing -----------------------------------------------------------

    pub fn insert(self: *TextFieldState, s: []const u8) !void {
        _ = self.deleteSelection();
        try self.buffer.insertSlice(self.allocator, self.caret, s);
        self.caret += s.len;
        self.sel_anchor = null;
        self.pref_col = null;
        self.revision +%= 1;
    }
    pub fn backspace(self: *TextFieldState) void {
        if (self.deleteSelection()) return;
        if (self.caret == 0) return;
        const start = prevCpStart(self.buffer.items, self.caret);
        const n = self.caret - start;
        std.mem.copyForwards(u8, self.buffer.items[start..], self.buffer.items[self.caret..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - n);
        self.caret = start;
        self.pref_col = null;
        self.revision +%= 1;
    }
    /// Forward-delete (the Delete key): remove the codepoint after the caret.
    pub fn deleteForward(self: *TextFieldState) void {
        if (self.deleteSelection()) return;
        const items = self.buffer.items;
        if (self.caret >= items.len) return;
        const len = std.unicode.utf8ByteSequenceLength(items[self.caret]) catch 1;
        const stop = @min(self.caret + len, items.len);
        std.mem.copyForwards(u8, self.buffer.items[self.caret..], self.buffer.items[stop..]);
        self.buffer.shrinkRetainingCapacity(items.len - (stop - self.caret));
        self.pref_col = null;
        self.revision +%= 1;
    }

    // --- caret movement (extend = Shift held, growing the selection) -------

    fn beginExtend(self: *TextFieldState, extend: bool) void {
        if (extend) {
            if (self.sel_anchor == null) self.sel_anchor = self.caret;
        } else self.sel_anchor = null;
    }
    pub fn moveLeft(self: *TextFieldState, extend: bool) void {
        self.pref_col = null;
        if (!extend) {
            if (self.selectionRange()) |r| {
                self.caret = r.start;
                self.sel_anchor = null;
                return;
            }
        }
        self.beginExtend(extend);
        if (self.caret > 0) self.caret = prevCpStart(self.buffer.items, self.caret);
    }
    pub fn moveRight(self: *TextFieldState, extend: bool) void {
        self.pref_col = null;
        if (!extend) {
            if (self.selectionRange()) |r| {
                self.caret = r.end;
                self.sel_anchor = null;
                return;
            }
        }
        self.beginExtend(extend);
        const items = self.buffer.items;
        if (self.caret < items.len) {
            const len = std.unicode.utf8ByteSequenceLength(items[self.caret]) catch 1;
            self.caret = @min(self.caret + len, items.len);
        }
    }
    pub fn home(self: *TextFieldState, extend: bool) void {
        self.beginExtend(extend);
        self.caret = lineStartIndex(self.buffer.items, self.caret);
        self.pref_col = null;
    }
    pub fn end(self: *TextFieldState, extend: bool) void {
        self.beginExtend(extend);
        self.caret = lineEndIndex(self.buffer.items, self.caret);
        self.pref_col = null;
    }
    pub fn moveUp(self: *TextFieldState, extend: bool) void {
        self.beginExtend(extend);
        const b = self.buffer.items;
        const ls = lineStartIndex(b, self.caret);
        if (self.pref_col == null) self.pref_col = columnOf(b, self.caret);
        if (ls == 0) {
            self.caret = 0; // already on the first line
            return;
        }
        const prev_end = ls - 1; // the '\n' that ends the previous line
        const prev_start = lineStartIndex(b, prev_end);
        self.caret = indexForColumn(b, prev_start, prev_end, self.pref_col.?);
    }
    pub fn moveDown(self: *TextFieldState, extend: bool) void {
        self.beginExtend(extend);
        const b = self.buffer.items;
        const le = lineEndIndex(b, self.caret);
        if (self.pref_col == null) self.pref_col = columnOf(b, self.caret);
        if (le >= b.len) {
            self.caret = b.len; // already on the last line
            return;
        }
        const next_start = le + 1;
        const next_end = lineEndIndex(b, next_start);
        self.caret = indexForColumn(b, next_start, next_end, self.pref_col.?);
    }
    /// The caret's 1-based line and column (counting codepoints), for a status bar.
    pub fn lineCol(self: *const TextFieldState) struct { line: usize, col: usize } {
        return .{
            .line = lineIndexOf(self.buffer.items, self.caret) + 1,
            .col = columnOf(self.buffer.items, self.caret) + 1,
        };
    }
};

// ---------------------------------------------------------------------------
// Pure line/column geometry over a UTF-8 byte buffer
// ---------------------------------------------------------------------------
// Lines are separated by '\n'; a column counts codepoints from the line start.
// Shared by `TextFieldState` movement and the editor's painting.

pub fn prevCpStart(bytes: []const u8, i: usize) usize {
    var j = i;
    if (j == 0) return 0;
    j -= 1;
    while (j > 0 and (bytes[j] & 0xC0) == 0x80) j -= 1; // skip UTF-8 continuation bytes
    return j;
}
pub fn lineStartIndex(bytes: []const u8, i: usize) usize {
    var j = @min(i, bytes.len);
    while (j > 0 and bytes[j - 1] != '\n') j -= 1;
    return j;
}
pub fn lineEndIndex(bytes: []const u8, i: usize) usize {
    var j = @min(i, bytes.len);
    while (j < bytes.len and bytes[j] != '\n') j += 1;
    return j;
}
pub fn columnOf(bytes: []const u8, i: usize) usize {
    const lim = @min(i, bytes.len);
    var col: usize = 0;
    var j = lineStartIndex(bytes, lim);
    while (j < lim) : (j += 1) {
        if ((bytes[j] & 0xC0) != 0x80) col += 1; // count non-continuation bytes
    }
    return col;
}
pub fn lineIndexOf(bytes: []const u8, i: usize) usize {
    const lim = @min(i, bytes.len);
    var n: usize = 0;
    for (bytes[0..lim]) |b| {
        if (b == '\n') n += 1;
    }
    return n;
}
pub fn countLines(bytes: []const u8) usize {
    var n: usize = 1;
    for (bytes) |b| {
        if (b == '\n') n += 1;
    }
    return n;
}
/// The byte index `col` codepoints into the line spanning [line_start, line_end].
pub fn indexForColumn(bytes: []const u8, line_start: usize, line_end: usize, col: usize) usize {
    var j = line_start;
    var c: usize = 0;
    while (j < line_end and c < col) {
        j += std.unicode.utf8ByteSequenceLength(bytes[j]) catch 1;
        c += 1;
    }
    return @min(j, line_end);
}
/// The byte range [start, end) of the `n`-th line (0-based), clamped to the last.
pub fn nthLineRange(bytes: []const u8, n: usize) struct { start: usize, end: usize } {
    var start: usize = 0;
    var seen: usize = 0;
    var j: usize = 0;
    while (j < bytes.len) : (j += 1) {
        if (bytes[j] == '\n') {
            if (seen == n) return .{ .start = start, .end = j };
            seen += 1;
            start = j + 1;
        }
    }
    return .{ .start = start, .end = bytes.len };
}

// ---------------------------------------------------------------------------
// Tab-aware horizontal metrics (shared by caret, selection, and click math)
// ---------------------------------------------------------------------------

/// Editor tab width, in spaces (tabs snap to the next multiple of this).
pub const editor_tab_size: f32 = 4;

/// The advance of a single space and a tab stop at `px`, used to lay out the
/// editor's monospace-ish tab handling.
pub fn editorTabMetrics(face: *const ttf.Font, px: f32) struct { space: f32, tab: f32 } {
    const space = shape.measureLineWidth(face, " ", px);
    return .{ .space = space, .tab = space * editor_tab_size };
}

/// Pixel width of `slice`, honoring tab stops (so `\t` advances to the next
/// multiple of the tab width rather than drawing a `.notdef` box). Shared by the
/// caret, selection, and click math so they all agree.
pub fn editorPrefixWidth(face: *const ttf.Font, px: f32, slice: []const u8) f32 {
    const sc = face.scaleForPixelSize(px);
    const tab_w = editorTabMetrics(face, px).tab;
    var x: f32 = 0;
    var i: usize = 0;
    while (i < slice.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(slice[i]) catch 1;
        const e = @min(i + cp_len, slice.len);
        if (slice[i] == '\t') {
            x = (@floor(x / tab_w) + 1) * tab_w;
        } else {
            const cp = std.unicode.utf8Decode(slice[i..e]) catch slice[i];
            x += @as(f32, @floatFromInt(face.advanceWidth(face.glyphIndex(cp)))) * sc;
        }
        i = e;
    }
    return x;
}

/// The byte offset within `line` whose glyph boundary is nearest to pixel
/// `target_x` (measured from the line's left edge). Tab-aware; used for click-
/// to-position.
pub fn caretInLine(face: *const ttf.Font, px: f32, line: []const u8, target_x: f32) usize {
    if (target_x <= 0) return 0;
    const sc = face.scaleForPixelSize(px);
    const tab_w = editorTabMetrics(face, px).tab;
    var x: f32 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const e = @min(i + cp_len, line.len);
        const adv = if (line[i] == '\t')
            (@floor(x / tab_w) + 1) * tab_w - x
        else
            @as(f32, @floatFromInt(face.advanceWidth(face.glyphIndex(std.unicode.utf8Decode(line[i..e]) catch line[i])))) * sc;
        if (target_x < x + adv / 2) return i; // nearer this cell's left edge
        x += adv;
        i = e;
    }
    return line.len;
}
