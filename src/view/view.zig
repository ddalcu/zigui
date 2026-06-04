//! The declarative View layer — zigui's SwiftUI-like surface.
//!
//! A `View` is a plain value: a `Kind` (its content) plus a `Modifiers` bundle
//! (padding, frame, background, foreground, on-tap, …) applied around it via a
//! fluent, chainable API. View trees are built with free functions that read
//! like SwiftUI:
//!
//!     VStack(.{
//!         Text("Hello").font(.title).foreground(theme.accent),
//!         Button("Tap", onTap).padding(8),
//!     })
//!
//! Rendering reuses the tested pure layout engine: the View tree is lowered to a
//! `layout.Node` tree, `arrange`d into frames, then painted by co-walking the
//! View tree with the resulting `LayoutResult`. Because layout is shared with
//! the engine, only painting and interaction live here.

const std = @import("std");
const geom = @import("../layout/geometry.zig");
const engine = @import("../layout/engine.zig");
const Color = @import("../render/color.zig").Color;
const canvas_mod = @import("../render/canvas.zig");
const Canvas = canvas_mod.Canvas;
const theme_mod = @import("../theme/theme.zig");
const atlas = @import("../text/atlas.zig");
const shape = @import("../text/shape.zig");
const font_mod = @import("../text/font.zig");
const state = @import("../state/state.zig");

pub const Binding = state.Binding;

const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Point = geom.Point;
const Size = geom.Size;
const EdgeInsets = geom.EdgeInsets;
const Alignment = geom.Alignment;
const Theme = theme_mod.Theme;
const inf = std.math.inf(f32);

// ---------------------------------------------------------------------------
// Callbacks
// ---------------------------------------------------------------------------

/// A type-erased UI callback (button tap, toggle, etc.).
pub const Callback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (?*anyopaque) void,

    pub fn call(self: Callback) void {
        self.func(self.ctx);
    }
};

/// Wrap a plain zero-arg function as a Callback.
pub fn action(comptime f: fn () void) Callback {
    return .{ .func = struct {
        fn g(_: ?*anyopaque) void {
            f();
        }
    }.g };
}

/// Wrap a function taking a typed context pointer as a Callback.
pub fn actionCtx(comptime T: type, ctx: *T, comptime f: fn (*T) void) Callback {
    return .{ .ctx = ctx, .func = struct {
        fn g(p: ?*anyopaque) void {
            f(@ptrCast(@alignCast(p.?)));
        }
    }.g };
}

// ---------------------------------------------------------------------------
// Fills, fonts, modifiers
// ---------------------------------------------------------------------------

/// A translucent, blurred "material" (vibrancy) like macOS sidebars and HUDs.
/// Each level pairs a frost `tint` with a blur `sigma`. Painted via `blur_rect`,
/// so it frosts whatever was drawn beneath it.
pub const Material = enum {
    ultra_thin,
    thin,
    regular,
    thick,

    pub const Spec = struct { tint: Color, sigma: f32 };

    pub fn spec(self: Material) Spec {
        return switch (self) {
            .ultra_thin => .{ .tint = Color.white.withAlpha(0.20), .sigma = 8 },
            .thin => .{ .tint = Color.white.withAlpha(0.35), .sigma = 10 },
            .regular => .{ .tint = Color.white.withAlpha(0.55), .sigma = 12 },
            .thick => .{ .tint = Color.white.withAlpha(0.75), .sigma = 14 },
        };
    }
};

pub const Fill = union(enum) {
    color: Color,
    linear_gradient: struct { c0: Color, c1: Color, start: Point, end: Point },
    material: Material,
};

/// How a presented overlay is positioned and styled when drawn on top of
/// everything (see the overlay drain pass in `render`).
pub const OverlayStyle = enum {
    /// A panel pinned to the bottom edge, full width.
    sheet,
    /// A centered dialog box.
    alert,
    /// A small panel near its anchor view (also used for menus).
    popover,
};

/// A `.sheet`/`.alert`/`.popover` modifier: present `content` over everything
/// while `presented` is true. `content` is heap-stored in the build arena.
pub const OverlayMod = struct {
    presented: Binding(bool),
    content: *const View,
    style: OverlayStyle,
};

/// Named typographic styles, resolved against the active theme at paint time
/// (so `.font(.title)` honors theming and dark mode).
pub const FontToken = enum {
    large_title,
    title,
    title2,
    title3,
    headline,
    body,
    callout,
    subheadline,
    footnote,
    caption,
    caption2,
};

pub const FrameSpec = struct {
    width: ?f32 = null,
    height: ?f32 = null,
    min_width: ?f32 = null,
    max_width: ?f32 = null,
    min_height: ?f32 = null,
    max_height: ?f32 = null,
    alignment: Alignment = .center,
};

pub const Modifiers = struct {
    padding: ?EdgeInsets = null,
    frame: ?FrameSpec = null,
    background: ?Fill = null,
    corner_radius: f32 = 0,
    foreground: ?Color = null,
    font: ?FontToken = null,
    border_color: ?Color = null,
    border_width: f32 = 1,
    opacity: f32 = 1,
    on_tap: ?Callback = null,
    /// Fired when a focused `TextField` is submitted (Enter). Stashed on the
    /// field's `TextFieldState` during paint; see `submitFocused`.
    on_submit: ?Callback = null,
    disabled: bool = false,
    overlay: ?OverlayMod = null,
    /// Overrides the auto-derived accessibility label for this view.
    a11y_label: ?[]const u8 = null,
    /// Hides this view (and its subtree) from the accessibility tree.
    a11y_hidden: bool = false,
};

// ---------------------------------------------------------------------------
// View kinds
// ---------------------------------------------------------------------------

pub const ShapeKind = enum { rect, rounded_rect, circle, capsule, ellipse };

pub const TextData = struct { string: []const u8 };
pub const WrappedTextData = struct { string: []const u8 };
pub const SpacerData = struct { min_length: f32 = 0 };
pub const ShapeData = struct { shape: ShapeKind, corner_radius: f32 = 0, fill: Fill };
pub const StackData = struct {
    direction: engine.Direction,
    spacing: f32,
    alignment: Alignment,
    children: []const View,
};
pub const ButtonRole = enum { normal, destructive, plain };
pub const ButtonData = struct { label: []const u8, action: Callback, role: ButtonRole = .normal };

pub const ToggleData = struct { value: Binding(bool), label: []const u8 = "" };
pub const SliderData = struct { value: Binding(f32), min: f32 = 0, max: f32 = 1 };
pub const StepperData = struct { value: Binding(i64), label: []const u8 = "", min: i64 = std.math.minInt(i64), max: i64 = std.math.maxInt(i64), step: i64 = 1 };
pub const ProgressData = struct { value: f32 = 0, label: []const u8 = "" };
pub const ImageData = struct { image: canvas_mod.Image };
pub const LabelData = struct { title: []const u8, symbol_color: Color };
pub const ScrollData = struct { axis: engine.Direction, offset: f32, content: *const View };

/// Editable text buffer + caret for a `TextField`. Owned by the app (like a
/// `State`), so editing survives across frames. Key events call its methods.
pub const TextFieldState = struct {
    buffer: std.ArrayList(u8) = .empty,
    caret: usize = 0, // byte index
    focused: bool = false,
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
    }
    pub fn insert(self: *TextFieldState, s: []const u8) !void {
        try self.buffer.insertSlice(self.allocator, self.caret, s);
        self.caret += s.len;
    }
    pub fn backspace(self: *TextFieldState) void {
        if (self.caret == 0) return;
        const start = prevCpStart(self.buffer.items, self.caret);
        const n = self.caret - start;
        std.mem.copyForwards(u8, self.buffer.items[start..], self.buffer.items[self.caret..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - n);
        self.caret = start;
    }
    pub fn moveLeft(self: *TextFieldState) void {
        if (self.caret == 0) return;
        self.caret = prevCpStart(self.buffer.items, self.caret);
    }
    pub fn moveRight(self: *TextFieldState) void {
        if (self.caret >= self.buffer.items.len) return;
        const len = std.unicode.utf8ByteSequenceLength(self.buffer.items[self.caret]) catch 1;
        self.caret = @min(self.caret + len, self.buffer.items.len);
    }
};

fn prevCpStart(bytes: []const u8, i: usize) usize {
    var j = i;
    if (j == 0) return 0;
    j -= 1;
    while (j > 0 and (bytes[j] & 0xC0) == 0x80) j -= 1; // skip UTF-8 continuation bytes
    return j;
}

/// A navigation route stack for `NavigationStack`-style flows. Owned by the app
/// (like `TextFieldState`), so it survives across frames; the per-frame body
/// switches on `top()` to choose the screen. Routes are opaque integer tokens
/// the app interprets. Because the tree is rebuilt every frame, "navigation" is
/// just mutating this stack.
pub const NavState = struct {
    stack: std.ArrayList(i64) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) NavState {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *NavState) void {
        self.stack.deinit(self.allocator);
    }
    pub fn push(self: *NavState, route: i64) void {
        self.stack.append(self.allocator, route) catch {};
    }
    pub fn pop(self: *NavState) void {
        if (self.stack.items.len > 0) _ = self.stack.pop();
    }
    /// The current (top-most) route, or null when at the root.
    pub fn top(self: *const NavState) ?i64 {
        const n = self.stack.items.len;
        return if (n == 0) null else self.stack.items[n - 1];
    }
    pub fn depth(self: *const NavState) usize {
        return self.stack.items.len;
    }
};

/// Scroll position for a `ScrollViewState`, owned by the app (like
/// `TextFieldState`) so it survives across frames and can be driven by the event
/// loop (mouse wheel) and by code (auto-follow). `content_h`/`viewport_h` are
/// written back by `paintScrollState` each frame so `maxOffset`/`atBottom` are
/// accurate; `offset` is what the view is scrolled by (vertical, in points).
pub const ScrollState = struct {
    offset: f32 = 0,
    content_h: f32 = 0,
    viewport_h: f32 = 0,

    /// The furthest the content can be scrolled (0 when it fits the viewport).
    pub fn maxOffset(self: *const ScrollState) f32 {
        return @max(0, self.content_h - self.viewport_h);
    }
    /// Scroll by `d` points, clamped to `[0, maxOffset]`.
    pub fn scrollBy(self: *ScrollState, d: f32) void {
        self.offset = std.math.clamp(self.offset + d, 0, self.maxOffset());
    }
    pub fn scrollToBottom(self: *ScrollState) void {
        self.offset = self.maxOffset();
    }
    /// True when scrolled to (or past) the bottom — used to decide whether to
    /// keep a streaming transcript pinned.
    pub fn atBottom(self: *const ScrollState) bool {
        return self.offset >= self.maxOffset() - 0.5;
    }
};

/// A scrollable viewport's frame paired with its `ScrollState`, collected during
/// painting (when `Context.scroll_regions` is set) so the app can route mouse
/// wheel events to the right region via `dispatchScroll`.
pub const ScrollRegion = struct { rect: Rect, state: *ScrollState };

pub const TextFieldData = struct { state: *TextFieldState, placeholder: []const u8 = "" };
pub const ScrollStateData = struct { state: *ScrollState, content: *const View };
pub const PickerData = struct { selection: Binding(i64), options: []const []const u8 };

pub const Kind = union(enum) {
    empty,
    text: TextData,
    /// Multi-line text that word-wraps to the proposed width (height grows with
    /// the number of wrapped lines). Lowered to an `engine.measured` node.
    wrapped_text: WrappedTextData,
    spacer: SpacerData,
    divider,
    /// A vertical hairline (rigid narrow width, fills the cross-axis height) —
    /// the HStack counterpart to `divider`, used to separate side-by-side panes.
    vdivider,
    shape: ShapeData,
    stack: StackData,
    button: ButtonData,
    toggle: ToggleData,
    slider: SliderData,
    stepper: StepperData,
    progress: ProgressData,
    image: ImageData,
    label: LabelData,
    scroll: ScrollData,
    /// A vertical scroll view whose offset lives in an app-owned `ScrollState`
    /// (so it can be wheel-driven and auto-followed), unlike `scroll`'s static
    /// offset.
    scroll_state: ScrollStateData,
    textfield: TextFieldData,
    picker: PickerData,
    /// A transparent container whose children are spliced into the enclosing
    /// stack (used by `ForEach`).
    group: []const View,
};

// ---------------------------------------------------------------------------
// View + fluent modifiers
// ---------------------------------------------------------------------------

pub const View = struct {
    kind: Kind,
    mods: Modifiers = .{},

    pub fn padding(self: View, amount: f32) View {
        var v = self;
        v.mods.padding = EdgeInsets.all(amount);
        return v;
    }
    pub fn paddingInsets(self: View, insets: EdgeInsets) View {
        var v = self;
        v.mods.padding = insets;
        return v;
    }
    pub fn frame(self: View, w: f32, h: f32) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.width = w;
        f.height = h;
        v.mods.frame = f;
        return v;
    }
    pub fn frameWidth(self: View, w: f32) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.width = w;
        v.mods.frame = f;
        return v;
    }
    pub fn frameHeight(self: View, h: f32) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.height = h;
        v.mods.frame = f;
        return v;
    }
    /// Expand to fill the available width (SwiftUI `.frame(maxWidth: .infinity)`).
    pub fn frameMaxWidth(self: View) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.max_width = inf;
        v.mods.frame = f;
        return v;
    }
    pub fn frameMaxHeight(self: View) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.max_height = inf;
        v.mods.frame = f;
        return v;
    }
    pub fn background(self: View, c: Color) View {
        var v = self;
        v.mods.background = .{ .color = c };
        return v;
    }
    pub fn backgroundFill(self: View, fill: Fill) View {
        var v = self;
        v.mods.background = fill;
        return v;
    }
    /// Use a frosted `Material` (vibrancy) as the background — it blurs and tints
    /// whatever is drawn beneath this view.
    pub fn backgroundMaterial(self: View, m: Material) View {
        var v = self;
        v.mods.background = .{ .material = m };
        return v;
    }
    pub fn foreground(self: View, c: Color) View {
        var v = self;
        v.mods.foreground = c;
        return v;
    }
    pub fn font(self: View, tok: FontToken) View {
        var v = self;
        v.mods.font = tok;
        return v;
    }
    pub fn cornerRadius(self: View, r: f32) View {
        var v = self;
        v.mods.corner_radius = r;
        return v;
    }
    pub fn border(self: View, c: Color, width: f32) View {
        var v = self;
        v.mods.border_color = c;
        v.mods.border_width = width;
        return v;
    }
    pub fn opacity(self: View, o: f32) View {
        var v = self;
        v.mods.opacity = o;
        return v;
    }
    pub fn onTap(self: View, cb: Callback) View {
        var v = self;
        v.mods.on_tap = cb;
        return v;
    }
    /// Fire `cb` when this (focused) `TextField` is submitted with Enter.
    pub fn onSubmit(self: View, cb: Callback) View {
        var v = self;
        v.mods.on_submit = cb;
        return v;
    }
    pub fn disabled(self: View, d: bool) View {
        var v = self;
        v.mods.disabled = d;
        return v;
    }
    /// Present `content` as a bottom sheet while `presented` is true.
    pub fn sheet(self: View, presented: Binding(bool), content: View) View {
        return self.withOverlay(presented, content, .sheet);
    }
    /// Present `content` as a centered alert dialog while `presented` is true.
    pub fn alert(self: View, presented: Binding(bool), content: View) View {
        return self.withOverlay(presented, content, .alert);
    }
    /// Present `content` as a popover anchored to this view while `presented`.
    pub fn popover(self: View, presented: Binding(bool), content: View) View {
        return self.withOverlay(presented, content, .popover);
    }
    fn withOverlay(self: View, presented: Binding(bool), content: View, style: OverlayStyle) View {
        const boxed = buildAlloc().create(View) catch @panic("oom");
        boxed.* = content;
        var v = self;
        v.mods.overlay = .{ .presented = presented, .content = boxed, .style = style };
        return v;
    }
    /// Override the accessibility label exposed for this view.
    pub fn accessibilityLabel(self: View, label: []const u8) View {
        var v = self;
        v.mods.a11y_label = label;
        return v;
    }
    /// Hide this view and its subtree from the accessibility tree.
    pub fn accessibilityHidden(self: View, hidden: bool) View {
        var v = self;
        v.mods.a11y_hidden = hidden;
        return v;
    }
    /// Stack spacing setter (no-op on non-stacks).
    pub fn spacing(self: View, s: f32) View {
        var v = self;
        if (v.kind == .stack) v.kind.stack.spacing = s;
        return v;
    }
};

// ---------------------------------------------------------------------------
// Build arena (per-frame) and constructors
// ---------------------------------------------------------------------------

threadlocal var current_arena: ?Allocator = null;

/// Set the arena used by view constructors for the duration of building a view
/// tree. The framework calls this each frame; tests call it directly.
pub fn beginBuild(arena: Allocator) void {
    current_arena = arena;
}
pub fn endBuild() void {
    current_arena = null;
}
fn buildAlloc() Allocator {
    return current_arena orelse @panic("zigui: view constructed outside beginBuild()/endBuild()");
}

pub fn Text(s: []const u8) View {
    return .{ .kind = .{ .text = .{ .string = s } } };
}
/// Multi-line text: word-wraps to the width it is proposed, growing taller as it
/// wraps. Use this (rather than `Text`) for paragraphs and chat bubbles.
pub fn WrappedText(s: []const u8) View {
    return .{ .kind = .{ .wrapped_text = .{ .string = s } } };
}
pub fn Spacer() View {
    return .{ .kind = .{ .spacer = .{} } };
}
pub fn MinSpacer(min_length: f32) View {
    return .{ .kind = .{ .spacer = .{ .min_length = min_length } } };
}
pub fn Divider() View {
    return .{ .kind = .divider };
}
pub fn VDivider() View {
    return .{ .kind = .vdivider };
}
pub fn Empty() View {
    return .{ .kind = .empty };
}
pub fn Rectangle(c: Color) View {
    return .{ .kind = .{ .shape = .{ .shape = .rect, .fill = .{ .color = c } } } };
}
pub fn RoundedRectangle(c: Color, radius: f32) View {
    return .{ .kind = .{ .shape = .{ .shape = .rounded_rect, .corner_radius = radius, .fill = .{ .color = c } } } };
}
pub fn Circle(c: Color) View {
    return .{ .kind = .{ .shape = .{ .shape = .circle, .fill = .{ .color = c } } } };
}
pub fn Capsule(c: Color) View {
    return .{ .kind = .{ .shape = .{ .shape = .capsule, .fill = .{ .color = c } } } };
}
pub fn Ellipse(c: Color) View {
    return .{ .kind = .{ .shape = .{ .shape = .ellipse, .fill = .{ .color = c } } } };
}
pub fn Button(label: []const u8, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap } } };
}
pub fn ButtonRoled(label: []const u8, role: ButtonRole, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap, .role = role } } };
}

pub fn Toggle(label: []const u8, value: Binding(bool)) View {
    return .{ .kind = .{ .toggle = .{ .value = value, .label = label } } };
}
pub fn Slider(value: Binding(f32), min: f32, max: f32) View {
    return .{ .kind = .{ .slider = .{ .value = value, .min = min, .max = max } } };
}
pub fn Stepper(label: []const u8, value: Binding(i64), min: i64, max: i64, step: i64) View {
    return .{ .kind = .{ .stepper = .{ .value = value, .label = label, .min = min, .max = max, .step = step } } };
}
pub fn ProgressView(value: f32) View {
    return .{ .kind = .{ .progress = .{ .value = std.math.clamp(value, 0, 1) } } };
}
pub fn Image(image: canvas_mod.Image) View {
    return .{ .kind = .{ .image = .{ .image = image } } };
}
/// A title with a small leading symbol swatch (placeholder for an icon set).
pub fn Label(title: []const u8, symbol_color: Color) View {
    return .{ .kind = .{ .label = .{ .title = title, .symbol_color = symbol_color } } };
}
pub fn TextField(placeholder: []const u8, fieldState: *TextFieldState) View {
    return .{ .kind = .{ .textfield = .{ .state = fieldState, .placeholder = placeholder } } };
}
/// A segmented picker bound to a selected index.
pub fn Picker(selection: Binding(i64), options: []const []const u8) View {
    return .{ .kind = .{ .picker = .{ .selection = selection, .options = options } } };
}

/// A gradient that fills its frame, interpolating between two colors along the
/// vector from `start` to `end` (unit points in 0..1, like SwiftUI UnitPoint).
pub fn LinearGradient(c0: Color, c1: Color, start: Point, end: Point) View {
    return .{ .kind = .{ .shape = .{
        .shape = .rect,
        .fill = .{ .linear_gradient = .{ .c0 = c0, .c1 = c1, .start = start, .end = end } },
    } } };
}

pub fn ScrollView(content: View) View {
    return scrollImpl(.vertical, 0, content);
}
pub fn ScrollViewOffset(axis: engine.Direction, offset: f32, content: View) View {
    return scrollImpl(axis, offset, content);
}
fn scrollImpl(axis: engine.Direction, offset: f32, content: View) View {
    const child = buildAlloc().create(View) catch @panic("oom");
    child.* = content;
    return .{ .kind = .{ .scroll = .{ .axis = axis, .offset = offset, .content = child } } };
}

/// A vertical scroll view driven by an app-owned `ScrollState`. Like
/// `ScrollView`, but the offset persists across frames in `scroll_state`, so it
/// can be moved by the mouse wheel (`dispatchScroll`) or pinned to the bottom
/// (`scroll_state.scrollToBottom()` for a streaming transcript).
pub fn ScrollViewState(scroll_state: *ScrollState, content: View) View {
    const child = buildAlloc().create(View) catch @panic("oom");
    child.* = content;
    return .{ .kind = .{ .scroll_state = .{ .state = scroll_state, .content = child } } };
}

/// A SwiftUI-style List: a scrolling vertical container with hairline dividers
/// between rows and grouped-background styling.
pub fn List(rows: anytype) View {
    const views = toViews(rows);
    const flat = flattenGroups(views);
    // interleave dividers
    var with_dividers = buildAlloc().alloc(View, if (flat.len == 0) 0 else flat.len * 2 - 1) catch @panic("oom");
    var i: usize = 0;
    for (flat, 0..) |row, idx| {
        with_dividers[i] = row.paddingInsets(.{ .top = 6, .leading = 12, .bottom = 6, .trailing = 12 }).frameMaxWidth();
        i += 1;
        if (idx + 1 < flat.len) {
            with_dividers[i] = Divider();
            i += 1;
        }
    }
    const stack = makeStackFromSlice(.vertical, 0, .leading, with_dividers);
    return ScrollView(stack);
}

/// A grid that grows vertically: `items` are mapped to cells via `mapFn` and
/// laid out left-to-right, top-to-bottom into `columns` even columns. Built by
/// composition — a `VStack` of `HStack` rows — so it needs no new layout
/// primitive. Each cell is `.frameMaxWidth()` so columns share width evenly;
/// the trailing slots of a short final row are filled with invisible cells so
/// every column stays aligned. `spacing` applies between both rows and columns.
pub fn LazyVGrid(columns: usize, spc: f32, items: anytype, comptime mapFn: anytype) View {
    const cols = if (columns == 0) 1 else columns;
    const n = items.len;
    const rows = if (n == 0) 0 else (n + cols - 1) / cols; // ceil(n/cols)
    const row_views = buildAlloc().alloc(View, rows) catch @panic("oom");
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const cells = buildAlloc().alloc(View, cols) catch @panic("oom");
        var ci: usize = 0;
        while (ci < cols) : (ci += 1) {
            const idx = r * cols + ci;
            cells[ci] = if (idx < n) mapFn(items[idx]).frameMaxWidth() else Empty().frameMaxWidth();
        }
        row_views[r] = makeStackFromSlice(.horizontal, spc, .center, cells);
    }
    return makeStackFromSlice(.vertical, spc, .center, row_views);
}

/// A grid that grows horizontally: the transpose of `LazyVGrid`. `items` fill
/// `rows` even rows top-to-bottom, then wrap to the next column. Built as an
/// `HStack` of `VStack` columns; each cell is `.frameMaxHeight()`.
pub fn LazyHGrid(rows: usize, spc: f32, items: anytype, comptime mapFn: anytype) View {
    const rws = if (rows == 0) 1 else rows;
    const n = items.len;
    const cols = if (n == 0) 0 else (n + rws - 1) / rws; // ceil(n/rows)
    const col_views = buildAlloc().alloc(View, cols) catch @panic("oom");
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const cells = buildAlloc().alloc(View, rws) catch @panic("oom");
        var ri: usize = 0;
        while (ri < rws) : (ri += 1) {
            const idx = col * rws + ri;
            cells[ri] = if (idx < n) mapFn(items[idx]).frameMaxHeight() else Empty().frameMaxHeight();
        }
        col_views[col] = makeStackFromSlice(.vertical, spc, .center, cells);
    }
    return makeStackFromSlice(.horizontal, spc, .center, col_views);
}

/// One page of a `TabView`: a title for its tab-bar segment plus the content
/// shown when that tab is selected.
pub const Tab = struct { label: []const u8, content: View };

/// A tabbed container: shows the content of the selected tab above a segmented
/// tab bar. Built by composition — the bar is a `Picker` over the tab labels, so
/// tapping a segment drives the same `.select` interaction as `Picker` (and the
/// `selection` binding is what the body switches on). Rebuilt each frame, so
/// "switching tabs" is just the binding changing.
pub fn TabView(selection: Binding(i64), tabs: []const Tab) View {
    const n = tabs.len;
    if (n == 0) return Empty();
    const hi: i64 = @intCast(n - 1);
    const sel: usize = @intCast(std.math.clamp(selection.get(), 0, hi));
    const labels = buildAlloc().alloc([]const u8, n) catch @panic("oom");
    for (tabs, 0..) |tab, i| labels[i] = tab.label;
    const bar = Picker(selection, labels).frameMaxWidth();
    return VStack(.{ tabs[sel].content.frameMaxWidth(), Divider(), bar });
}

/// A two-column master/detail layout: a fixed-width `sidebar` pane (filled with
/// `sidebar_fill` so it stays themable), a vertical hairline, and a `detail`
/// pane that fills the remaining width. Pure composition over `HStack`.
pub fn NavigationSplitView(sidebar: View, detail: View, sidebar_fill: Color) View {
    return makeStack(.horizontal, 0, .center, .{
        sidebar.frameWidth(220).frameMaxHeight().background(sidebar_fill),
        VDivider(),
        detail.frameMaxWidth().frameMaxHeight(),
    });
}

/// Closure context for a `NavigationLink` tap: a (NavState, route) pair bound at
/// build time. Allocated in the per-frame build arena, which outlives the frame
/// until the next rebuild, so the hit region's callback can safely read it.
const NavPushCtx = struct { nav: *NavState, route: i64 };

fn navPushThunk(p: ?*anyopaque) void {
    const ctx: *NavPushCtx = @ptrCast(@alignCast(p.?));
    ctx.nav.push(ctx.route);
}

/// A button that, when tapped, pushes `route` onto `nav`'s route stack. Reuses
/// the plain `.callback` hit action (no new interaction kind needed).
pub fn NavigationLink(label: []const u8, route: i64, nav: *NavState) View {
    const ctx = buildAlloc().create(NavPushCtx) catch @panic("oom");
    ctx.* = .{ .nav = nav, .route = route };
    return Button(label, .{ .ctx = ctx, .func = navPushThunk });
}

/// A button that pops the top route off `nav` (the navigation "back" button).
/// Render it in the screen's top bar when `nav.depth() > 0`.
pub fn NavBackButton(label: []const u8, nav: *NavState) View {
    return ButtonRoled(label, .plain, actionCtx(NavState, nav, NavState.pop));
}

fn toggleBoolState(s: *state.State(bool)) void {
    s.set(!s.get());
}

/// A button that toggles a popover menu of `items` (a tuple or `[]const View`).
/// `open` is app-owned `State(bool)` tracking whether the menu is shown; tapping
/// the button toggles it, tapping the scrim dismisses it.
pub fn Menu(label: []const u8, open: *state.State(bool), items: anytype) View {
    const content = VStack(items).padding(6);
    return Button(label, actionCtx(state.State(bool), open, toggleBoolState))
        .popover(open.binding(), content);
}

/// Attach a popover menu of `items` to an arbitrary `trigger` view: tapping the
/// trigger toggles the menu. The right-click/long-press analogue of `Menu`.
pub fn ContextMenu(trigger: View, open: *state.State(bool), items: anytype) View {
    const content = VStack(items).padding(6);
    return trigger
        .onTap(actionCtx(state.State(bool), open, toggleBoolState))
        .popover(open.binding(), content);
}

pub fn VStack(children: anytype) View {
    return makeStack(.vertical, 8, .center, children);
}
pub fn HStack(children: anytype) View {
    return makeStack(.horizontal, 8, .center, children);
}
pub fn ZStack(children: anytype) View {
    return makeStack(.depth, 0, .center, children);
}

fn makeStack(direction: engine.Direction, spc: f32, alignment: Alignment, children: anytype) View {
    return makeStackFromSlice(direction, spc, alignment, toViews(children));
}

fn makeStackFromSlice(direction: engine.Direction, spc: f32, alignment: Alignment, views: []const View) View {
    return .{ .kind = .{ .stack = .{
        .direction = direction,
        .spacing = spc,
        .alignment = alignment,
        .children = flattenGroups(views),
    } } };
}

/// `ForEach(items, map)` maps a slice to views; the result is spliced into the
/// enclosing stack.
pub fn ForEach(items: anytype, comptime mapFn: anytype) View {
    var arr = buildAlloc().alloc(View, items.len) catch @panic("oom");
    for (items, 0..) |it, i| arr[i] = mapFn(it);
    return .{ .kind = .{ .group = arr } };
}

/// Allocate a formatted string in the build arena (for state-derived text).
pub fn fmt(comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(buildAlloc(), f, args) catch @panic("oom");
}

fn toViews(children: anytype) []View {
    const T = @TypeOf(children);
    // Accept either a tuple literal `.{a, b}` or a slice `[]const View`.
    if (T == []const View or T == []View) {
        const out = buildAlloc().alloc(View, children.len) catch @panic("oom");
        @memcpy(out, children);
        return out;
    }
    const fields = std.meta.fields(T);
    var out = buildAlloc().alloc(View, fields.len) catch @panic("oom");
    inline for (fields, 0..) |fld, i| out[i] = @field(children, fld.name);
    return out;
}

fn flattenGroups(views: []const View) []const View {
    var total: usize = 0;
    for (views) |v| total += if (v.kind == .group) v.kind.group.len else 1;
    if (total == views.len) return views; // nothing to flatten
    var out = buildAlloc().alloc(View, total) catch @panic("oom");
    var i: usize = 0;
    for (views) |v| {
        if (v.kind == .group) {
            for (v.kind.group) |g| {
                out[i] = g;
                i += 1;
            }
        } else {
            out[i] = v;
            i += 1;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Render context
// ---------------------------------------------------------------------------

/// What a hit region does when tapped. Controls bind directly to state so the
/// per-frame view value need not be captured by a closure.
pub const HitAction = union(enum) {
    callback: Callback,
    toggle: Binding(bool),
    /// Set a slider's value from a tap/drag x within its track rect.
    slider: struct { binding: Binding(f32), min: f32, max: f32, track: Rect },
    /// Add `delta` to a clamped integer stepper.
    step: struct { binding: Binding(i64), delta: i64, min: i64, max: i64 },
    /// Focus a text field (the app is responsible for unfocusing others).
    focus: *TextFieldState,
    /// Select a specific value (e.g. a picker segment).
    select: struct { binding: Binding(i64), value: i64 },
};

pub const HitRegion = struct { rect: Rect, action: HitAction, disabled: bool };

/// An accessibility role, mirroring the platform a11y roles a control maps to.
/// (`switch_`/`text_field` are spelled with a trailing underscore to avoid the
/// `switch` keyword and to read consistently.)
pub const A11yRole = enum {
    static_text,
    button,
    switch_,
    slider,
    text_field,
    image,
    header,
};

/// One node of the accessibility tree zigui emits in parallel with drawing
/// (there is no native view hierarchy to introspect). A platform bridge consumes
/// this tree; it is also directly assertable in headless tests.
pub const A11yNode = struct {
    rect: Rect,
    role: A11yRole,
    label: []const u8 = "",
    value: []const u8 = "",
};

/// A request, collected during painting, to draw an overlay on top of the whole
/// frame. The `render` drain pass turns each into a scrim + positioned content.
pub const OverlayReq = struct {
    content: View,
    style: OverlayStyle,
    /// The presenting view's frame, used to position popovers/menus.
    anchor: Rect,
    /// Binding flipped to false when the scrim is tapped (tap-to-dismiss).
    dismiss: ?Binding(bool) = null,
};

/// Map a tap x-coordinate within a horizontal slider track to a value.
pub fn sliderValueForX(track: Rect, min: f32, max: f32, x: f32) f32 {
    if (track.width <= 0) return min;
    const t = std.math.clamp((x - track.x) / track.width, 0, 1);
    return min + (max - min) * t;
}

pub const Context = struct {
    theme: Theme,
    cache: *atlas.GlyphCache,
    arena: Allocator,
    hit_regions: *std.ArrayList(HitRegion),
    foreground: Color,
    font_size: f32,
    opacity: f32 = 1,
    disabled: bool = false,
    /// Optional sink for overlay requests (sheets/alerts/popovers). When null,
    /// overlay modifiers are silently ignored — the 0-overlay fast path.
    overlays: ?*std.ArrayList(OverlayReq) = null,
    /// Optional sink for the accessibility tree (see `paintContent`).
    a11y: ?*std.ArrayList(A11yNode) = null,
    /// Optional sink for scrollable regions (see `paintScrollState`). When set,
    /// `ScrollViewState` registers its viewport so the app can route wheel
    /// events with `dispatchScroll`.
    scroll_regions: ?*std.ArrayList(ScrollRegion) = null,
    /// Device-pixel scale used by `renderScaled` (1 = logical points == pixels).
    scale: f32 = 1,

    pub fn init(theme: Theme, cache: *atlas.GlyphCache, arena_alloc: Allocator, hits: *std.ArrayList(HitRegion)) Context {
        return .{
            .theme = theme,
            .cache = cache,
            .arena = arena_alloc,
            .hit_regions = hits,
            .foreground = theme.colors.label,
            .font_size = theme.typography.body.size,
        };
    }

    /// Like `init`, but also wires the overlay and accessibility sinks. Used by
    /// the app runtime; tests typically set the fields directly.
    pub fn initFull(
        theme: Theme,
        cache: *atlas.GlyphCache,
        arena_alloc: Allocator,
        hits: *std.ArrayList(HitRegion),
        overlays: ?*std.ArrayList(OverlayReq),
        a11y: ?*std.ArrayList(A11yNode),
    ) Context {
        var ctx = init(theme, cache, arena_alloc, hits);
        ctx.overlays = overlays;
        ctx.a11y = a11y;
        return ctx;
    }
};

fn resolvedFontSize(ctx: *const Context, v: View) f32 {
    if (v.mods.font) |tok| return fontStyle(ctx.theme, tok).size;
    return ctx.font_size;
}
fn fontStyle(t: Theme, tok: FontToken) theme_mod.TextStyle {
    return switch (tok) {
        .large_title => t.typography.large_title,
        .title => t.typography.title,
        .title2 => t.typography.title2,
        .title3 => t.typography.title3,
        .headline => t.typography.headline,
        .body => t.typography.body,
        .callout => t.typography.callout,
        .subheadline => t.typography.subheadline,
        .footnote => t.typography.footnote,
        .caption => t.typography.caption,
        .caption2 => t.typography.caption2,
    };
}

const control_h_padding: f32 = 14;
const switch_w: f32 = 38;
const switch_h: f32 = 22;
const slider_h: f32 = 20;
const slider_knob_r: f32 = 9;
const slider_track_h: f32 = 4;
const progress_h: f32 = 6;
const stepper_w: f32 = 68;
const label_icon: f32 = 14;
const label_gap: f32 = 6;

fn buttonSize(ctx: *const Context, b: ButtonData) Size {
    const px = ctx.theme.typography.body.size;
    const lw = shape.measureLineWidth(ctx.cache.face, b.label, px);
    const lh = shape.lineHeight(ctx.cache.face, px);
    return .{
        .width = lw + 2 * control_h_padding,
        .height = @max(lh, ctx.theme.metrics.control_height),
    };
}

/// Measurement state captured for a `WrappedText` when it is lowered to an
/// `engine.measured` node. Allocated in the per-frame build arena (which outlives
/// the frame until the next rebuild), so the engine can call `measure` during
/// both the measure and arrange passes. The wrap uses the live proposed width.
const WrappedTextMeasure = struct {
    face: *const @import("../text/ttf.zig").Font,
    arena: Allocator,
    string: []const u8,
    px: f32,

    fn measure(p: *const anyopaque, prop: engine.Proposal) Size {
        const self: *const WrappedTextMeasure = @ptrCast(@alignCast(p));
        const lh = shape.lineHeight(self.face, self.px);
        const max_w = prop.width orelse big;
        const lines = shape.wrapText(self.arena, self.face, self.string, self.px, max_w) catch {
            // On OOM fall back to a single line so layout still progresses.
            return .{ .width = shape.measureLineWidth(self.face, self.string, self.px), .height = lh };
        };
        var width: f32 = 0;
        for (lines) |ln| width = @max(width, ln.width);
        return .{
            .width = @min(width, max_w),
            .height = @as(f32, @floatFromInt(lines.len)) * lh,
        };
    }
};

const big: f32 = 1_000_000;

// ---------------------------------------------------------------------------
// Lowering: View -> layout.Node
// ---------------------------------------------------------------------------

fn buildNode(ctx: *const Context, v: View) Allocator.Error!engine.Node {
    var node = try buildContentNode(ctx, v);
    if (v.mods.padding) |p| {
        const child = try ctx.arena.create(engine.Node);
        child.* = node;
        node = .{ .padding = .{ .insets = p, .child = child } };
    }
    if (v.mods.frame) |f| {
        const child = try ctx.arena.create(engine.Node);
        child.* = node;
        node = .{ .frame = .{
            .width = f.width,
            .height = f.height,
            .min_width = f.min_width,
            .max_width = f.max_width,
            .min_height = f.min_height,
            .max_height = f.max_height,
            .alignment = f.alignment,
            .child = child,
        } };
    }
    return node;
}

fn buildContentNode(ctx: *const Context, v: View) Allocator.Error!engine.Node {
    switch (v.kind) {
        .empty => return .{ .leaf = engine.SizingHints.fixedSize(.{}) },
        .spacer => |s| return .{ .spacer = .{ .min_length = s.min_length } },
        .divider => {
            const hair = ctx.theme.metrics.hairline;
            return .{ .leaf = .{
                .min = .{ .width = 0, .height = hair },
                .ideal = .{ .width = 10, .height = hair },
                .max = .{ .width = inf, .height = hair },
            } };
        },
        .vdivider => {
            const hair = ctx.theme.metrics.hairline;
            return .{ .leaf = .{
                .min = .{ .width = hair, .height = 0 },
                .ideal = .{ .width = hair, .height = 10 },
                .max = .{ .width = hair, .height = inf },
            } };
        },
        .text => |t| {
            const px = resolvedFontSize(ctx, v);
            const sz = Size{
                .width = shape.measureLineWidth(ctx.cache.face, t.string, px),
                .height = shape.lineHeight(ctx.cache.face, px),
            };
            return .{ .leaf = engine.SizingHints.fixedSize(sz) };
        },
        .wrapped_text => |wt| {
            const px = resolvedFontSize(ctx, v);
            const m = try ctx.arena.create(WrappedTextMeasure);
            m.* = .{ .face = ctx.cache.face, .arena = ctx.arena, .string = wt.string, .px = px };
            return .{ .measured = .{ .ctx = m, .measureFn = WrappedTextMeasure.measure } };
        },
        .shape => return .{ .leaf = .{
            .min = .{},
            .ideal = .{ .width = 10, .height = 10 },
            .max = .{ .width = inf, .height = inf },
        } },
        .button => |b| return .{ .leaf = engine.SizingHints.fixedSize(buttonSize(ctx, b)) },
        .toggle => |t| {
            const px = ctx.theme.typography.body.size;
            const lw: f32 = if (t.label.len > 0) shape.measureLineWidth(ctx.cache.face, t.label, px) else 0;
            const lh = shape.lineHeight(ctx.cache.face, px);
            const gap: f32 = if (t.label.len > 0) 8 else 0;
            const h = @max(lh, switch_h);
            return .{ .leaf = .{
                .min = .{ .width = lw + gap + switch_w, .height = h },
                .ideal = .{ .width = lw + gap + switch_w, .height = h },
                .max = .{ .width = inf, .height = h },
            } };
        },
        .slider => return .{ .leaf = .{
            .min = .{ .width = 60, .height = slider_h },
            .ideal = .{ .width = 140, .height = slider_h },
            .max = .{ .width = inf, .height = slider_h },
        } },
        .stepper => |s| {
            const px = ctx.theme.typography.body.size;
            const lw: f32 = if (s.label.len > 0) shape.measureLineWidth(ctx.cache.face, s.label, px) else 0;
            const lh = shape.lineHeight(ctx.cache.face, px);
            const gap: f32 = if (s.label.len > 0) 8 else 0;
            const h = @max(lh, ctx.theme.metrics.control_height);
            return .{ .leaf = .{
                .min = .{ .width = lw + gap + stepper_w, .height = h },
                .ideal = .{ .width = lw + gap + stepper_w, .height = h },
                .max = .{ .width = inf, .height = h },
            } };
        },
        .progress => return .{ .leaf = .{
            .min = .{ .width = 60, .height = progress_h },
            .ideal = .{ .width = 140, .height = progress_h },
            .max = .{ .width = inf, .height = progress_h },
        } },
        .image => |im| return .{ .leaf = engine.SizingHints.fixedSize(.{
            .width = @floatFromInt(im.image.width),
            .height = @floatFromInt(im.image.height),
        }) },
        .label => |l| {
            const px = resolvedFontSize(ctx, v);
            const tw = shape.measureLineWidth(ctx.cache.face, l.title, px);
            const lh = shape.lineHeight(ctx.cache.face, px);
            return .{ .leaf = engine.SizingHints.fixedSize(.{
                .width = label_icon + label_gap + tw,
                .height = @max(lh, label_icon),
            }) };
        },
        .scroll, .scroll_state => return .{ .leaf = .{
            .min = .{},
            .ideal = .{ .width = 200, .height = 200 },
            .max = .{ .width = inf, .height = inf },
        } },
        .textfield => return .{ .leaf = .{
            .min = .{ .width = 80, .height = ctx.theme.metrics.control_height },
            .ideal = .{ .width = 180, .height = ctx.theme.metrics.control_height },
            .max = .{ .width = inf, .height = ctx.theme.metrics.control_height },
        } },
        .picker => |pk| {
            const px = ctx.theme.typography.body.size;
            var w: f32 = 0;
            for (pk.options) |opt| w += shape.measureLineWidth(ctx.cache.face, opt, px) + 24;
            const h = ctx.theme.metrics.control_height;
            return .{ .leaf = .{
                .min = .{ .width = w, .height = h },
                .ideal = .{ .width = w, .height = h },
                .max = .{ .width = inf, .height = h },
            } };
        },
        .stack => |s| {
            const nodes = try ctx.arena.alloc(engine.Node, s.children.len);
            for (s.children, 0..) |child, i| nodes[i] = try buildNode(ctx, child);
            return .{ .stack = .{
                .direction = s.direction,
                .spacing = s.spacing,
                .alignment = s.alignment,
                .children = nodes,
            } };
        },
        .group => |g| {
            // A bare group (not inside a stack) behaves like a VStack.
            const nodes = try ctx.arena.alloc(engine.Node, g.len);
            for (g, 0..) |child, i| nodes[i] = try buildNode(ctx, child);
            return .{ .stack = .{ .direction = .vertical, .spacing = 8, .alignment = .center, .children = nodes } };
        },
    }
}

// ---------------------------------------------------------------------------
// Measure / render entry points
// ---------------------------------------------------------------------------

/// Measure the intrinsic size of a view given a proposal.
pub fn measure(ctx: *const Context, v: View, proposal: engine.Proposal) !Size {
    const node = try buildNode(ctx, v);
    return engine.measure(node, proposal);
}

/// Lay out `v` into `rect` and paint it into `canvas`, *collecting* overlay
/// requests and accessibility nodes into `ctx`'s sinks but NOT drawing overlays.
/// This is the recursion-safe entry point: `ScrollView` content and overlay
/// content call `renderInto` (never `render`) so overlays are drained exactly
/// once, by the top-level `render`.
pub fn renderInto(ctx: *const Context, v: View, rect: Rect, canvas: *Canvas) Allocator.Error!void {
    const node = try buildNode(ctx, v);
    const lr = try engine.arrange(ctx.arena, node, rect);
    try paint(ctx, v, lr, canvas);
}

/// The top-level render orchestrator: paint `v` into `rect`, then drain any
/// overlay requests it produced — each as a full-screen scrim plus its content
/// positioned by style. Overlay regions are appended last, so the back-to-front
/// `dispatchTap` gives them priority automatically. Hit regions for tappable
/// elements are appended to `ctx.hit_regions`.
pub fn render(ctx: *const Context, v: View, rect: Rect, canvas: *Canvas) !void {
    try renderInto(ctx, v, rect, canvas);
    if (ctx.overlays) |overlays| {
        // Index-based loop: overlay content rendered below may enqueue *more*
        // overlays (nesting); appending keeps the list growing and we process
        // each exactly once — no double-drain, no recursion.
        var i: usize = 0;
        while (i < overlays.items.len) : (i += 1) {
            const req = overlays.items[i]; // copy: drawing may reallocate the list
            try drawOverlay(ctx, req, rect, canvas);
        }
    }
}

/// Render `v` for a HiDPI display: lay out and paint in logical *points* (so all
/// layout math, theme metrics, and hit regions stay in points), then uniformly
/// scale the produced command list to device pixels. Glyphs are rasterized at
/// `point_size * scale` so text is crisp rather than an upscaled blur.
///
/// Note: `ctx.hit_regions` are left in point space — `dispatchTap` therefore
/// operates in points, and the app must convert device mouse coordinates back to
/// points (divide by `scale`) before dispatching.
pub fn renderScaled(ctx: *const Context, v: View, point_rect: Rect, scale: f32, canvas: *Canvas) !void {
    var sctx = ctx.*;
    sctx.scale = scale;
    const start = canvas.commands.items.len;
    try render(&sctx, v, point_rect, canvas);
    if (scale != 1) scaleCommands(canvas.commands.items[start..], scale);
}

fn scaleRect(r: Rect, s: f32) Rect {
    return .{ .x = r.x * s, .y = r.y * s, .width = r.width * s, .height = r.height * s };
}
fn scalePoint(p: Point, s: f32) Point {
    return .{ .x = p.x * s, .y = p.y * s };
}

/// Multiply every command's geometry (rects/points/radii/widths/blur sigma) by
/// `s`. Glyph/image coverage bitmaps are untouched — glyphs were already
/// rasterized at device resolution, so the scaled quad maps to them 1:1.
fn scaleCommands(cmds: []canvas_mod.DrawCommand, s: f32) void {
    for (cmds) |*cmd| {
        switch (cmd.*) {
            .fill_rrect => |*c| {
                c.rect = scaleRect(c.rect, s);
                c.radius *= s;
            },
            .stroke_rrect => |*c| {
                c.rect = scaleRect(c.rect, s);
                c.radius *= s;
                c.width *= s;
            },
            .linear_gradient => |*c| {
                c.rect = scaleRect(c.rect, s);
                c.radius *= s;
                c.start = scalePoint(c.start, s);
                c.end = scalePoint(c.end, s);
            },
            .line => |*c| {
                c.a = scalePoint(c.a, s);
                c.b = scalePoint(c.b, s);
                c.width *= s;
            },
            .glyph => |*c| c.rect = scaleRect(c.rect, s),
            .image => |*c| c.rect = scaleRect(c.rect, s),
            .blur_rect => |*c| {
                c.rect = scaleRect(c.rect, s);
                c.radius *= s;
                c.sigma *= s;
            },
            .push_clip => |*c| {
                c.rect = scaleRect(c.rect, s);
                c.radius *= s;
            },
            .pop_clip => {},
        }
    }
}

/// Draw one overlay request: a dimming scrim across `root`, a tap-to-dismiss
/// region, a panel background, then the content positioned by style.
fn drawOverlay(ctx: *const Context, req: OverlayReq, root: Rect, canvas: *Canvas) Allocator.Error!void {
    // 1. Dimming scrim over the whole frame.
    try canvas.fillRect(root, Color.black.withAlpha(0.2));
    // 2. Tap-to-dismiss region beneath the content (appended before content's
    //    own regions, so a tap on the content hits the content first).
    if (req.dismiss) |d| {
        try ctx.hit_regions.append(ctx.arena, .{ .rect = root, .action = .{ .toggle = d }, .disabled = false });
    }

    // 3. Measure & position the content.
    const prop: engine.Proposal = switch (req.style) {
        .sheet => .{ .width = root.width, .height = null },
        .alert => .{ .width = @min(root.width - 80, 320), .height = null },
        .popover => .unspecified,
    };
    const size = measure(ctx, req.content, prop) catch Size{};
    const target = switch (req.style) {
        .sheet => Rect{ .x = root.x, .y = root.maxY() - size.height, .width = root.width, .height = size.height },
        .alert => centerRect(root, size),
        .popover => anchoredRect(root, req.anchor, size),
    };

    // 4. Panel background + hairline border, then the content on top.
    const radius = ctx.theme.metrics.corner_radius;
    try canvas.fillRoundedRect(target, radius, ctx.theme.colors.control_background);
    try canvas.strokeRoundedRect(target, radius, ctx.theme.metrics.hairline, ctx.theme.colors.separator);
    try renderInto(ctx, req.content, target, canvas);
}

fn centerRect(root: Rect, size: Size) Rect {
    return .{
        .x = root.x + (root.width - size.width) / 2,
        .y = root.y + (root.height - size.height) / 2,
        .width = size.width,
        .height = size.height,
    };
}

/// Position an overlay just below its `anchor`, flipping above and clamping
/// horizontally so it stays inside `root`.
fn anchoredRect(root: Rect, anchor: Rect, size: Size) Rect {
    var x = anchor.x;
    if (x + size.width > root.maxX()) x = root.maxX() - size.width;
    if (x < root.x) x = root.x;
    var y = anchor.maxY() + 4;
    if (y + size.height > root.maxY()) y = anchor.y - size.height - 4; // flip above
    if (y < root.y) y = root.y;
    return .{ .x = x, .y = y, .width = size.width, .height = size.height };
}

// ---------------------------------------------------------------------------
// Painting (co-walk View + LayoutResult)
// ---------------------------------------------------------------------------

fn paint(ctx: *const Context, v: View, lr: engine.LayoutResult, canvas: *Canvas) Allocator.Error!void {
    const outer = lr.frame;

    // Resolve inherited environment for this subtree.
    var child_ctx = ctx.*;
    child_ctx.opacity = ctx.opacity * v.mods.opacity;
    if (v.mods.disabled) child_ctx.disabled = true;
    if (v.mods.foreground) |fg| child_ctx.foreground = fg;
    if (v.mods.font) |tok| child_ctx.font_size = fontStyle(ctx.theme, tok).size;
    // An accessibility-hidden view drops itself and its whole subtree from the
    // a11y tree by clearing the sink for this branch.
    if (v.mods.a11y_hidden) child_ctx.a11y = null;

    const op = child_ctx.opacity;

    // Background fill (behind content, spanning the padded frame).
    if (v.mods.background) |fill| try paintFill(canvas, outer, v.mods.corner_radius, fill, op);

    // Descend through the layout wrappers introduced by padding/frame.
    var clr = lr;
    if (v.mods.frame != null) clr = clr.children[0];
    if (v.mods.padding != null) clr = clr.children[0];

    try paintContent(&child_ctx, v, clr, canvas);

    // Border (in front of content), and tap region.
    if (v.mods.border_color) |bc| {
        try canvas.strokeRoundedRect(outer, v.mods.corner_radius, v.mods.border_width, bc.multiplyAlpha(op));
    }
    if (v.mods.on_tap) |cb| {
        try ctx.hit_regions.append(ctx.arena, .{ .rect = outer, .action = .{ .callback = cb }, .disabled = child_ctx.disabled });
    }

    // A presented overlay is not drawn inline — it is enqueued for the drain
    // pass in `render`, anchored to this view's frame.
    if (v.mods.overlay) |ov| {
        if (ov.presented.get()) {
            if (ctx.overlays) |overlays| {
                try overlays.append(ctx.arena, .{
                    .content = ov.content.*,
                    .style = ov.style,
                    .anchor = outer,
                    .dismiss = ov.presented,
                });
            }
        }
    }
}

/// Append an accessibility node for `v` (no-op when the a11y sink is off). The
/// label defaults to `default_label` unless the view carries an explicit
/// `.accessibilityLabel(...)` override.
fn emitA11y(ctx: *const Context, v: View, rect: Rect, role: A11yRole, default_label: []const u8, value: []const u8) Allocator.Error!void {
    const list = ctx.a11y orelse return;
    try list.append(ctx.arena, .{
        .rect = rect,
        .role = role,
        .label = v.mods.a11y_label orelse default_label,
        .value = value,
    });
}

fn paintContent(ctx: *const Context, v: View, clr: engine.LayoutResult, canvas: *Canvas) Allocator.Error!void {
    const op = ctx.opacity;
    const rect = clr.frame;
    switch (v.kind) {
        .empty, .spacer => {},
        .divider, .vdivider => try canvas.fillRect(rect, ctx.theme.colors.separator.multiplyAlpha(op)),
        .text => |t| {
            const px = resolvedFontSize(ctx, v);
            drawTextC(ctx, canvas, t.string, px, ctx.foreground.multiplyAlpha(op), rect.origin()) catch {};
            try emitA11y(ctx, v, rect, .static_text, t.string, "");
        },
        .wrapped_text => |wt| {
            paintWrappedText(ctx, v, wt, rect, canvas) catch {};
            try emitA11y(ctx, v, rect, .static_text, wt.string, "");
        },
        .shape => |sh| try paintShape(canvas, sh, rect, op),
        .button => |b| {
            try paintButton(ctx, b, rect, canvas);
            try emitA11y(ctx, v, rect, .button, b.label, "");
        },
        .toggle => |t| {
            try paintToggle(ctx, t, rect, canvas);
            try emitA11y(ctx, v, rect, .switch_, t.label, if (t.value.get()) "on" else "off");
        },
        .slider => |s| {
            try paintSlider(ctx, s, rect, canvas);
            const val = std.fmt.allocPrint(ctx.arena, "{d:.2}", .{s.value.get()}) catch "";
            try emitA11y(ctx, v, rect, .slider, "", val);
        },
        .stepper => |s| try paintStepper(ctx, s, rect, canvas),
        .progress => |pr| try paintProgress(ctx, pr, rect, canvas),
        .image => |im| {
            try canvas.drawImage(rect, im.image);
            try emitA11y(ctx, v, rect, .image, "", "");
        },
        .label => |l| {
            try paintLabel(ctx, l, v, rect, canvas);
            try emitA11y(ctx, v, rect, .static_text, l.title, "");
        },
        .scroll => |sd| try paintScroll(ctx, sd, rect, canvas),
        .scroll_state => |sd| try paintScrollState(ctx, sd, rect, canvas),
        .textfield => |tf| {
            try paintTextField(ctx, v, tf, rect, canvas);
            const val = ctx.arena.dupe(u8, tf.state.text()) catch "";
            try emitA11y(ctx, v, rect, .text_field, tf.placeholder, val);
        },
        .picker => |pk| try paintPicker(ctx, pk, rect, canvas),
        .stack => |s| {
            for (s.children, 0..) |child, i| {
                try paint(ctx, child, clr.children[i], canvas);
            }
        },
        .group => |g| {
            for (g, 0..) |child, i| {
                try paint(ctx, child, clr.children[i], canvas);
            }
        },
    }
}

fn paintFill(canvas: *Canvas, rect: Rect, radius: f32, fill: Fill, op: f32) !void {
    switch (fill) {
        .color => |c| try canvas.fillRoundedRect(rect, radius, c.multiplyAlpha(op)),
        .linear_gradient => |g| {
            // g.start/g.end are unit points (0..1); resolve to the rect.
            const start = Point{ .x = rect.x + g.start.x * rect.width, .y = rect.y + g.start.y * rect.height };
            const end = Point{ .x = rect.x + g.end.x * rect.width, .y = rect.y + g.end.y * rect.height };
            try canvas.push(.{ .linear_gradient = .{
                .rect = rect,
                .radius = radius,
                .start = start,
                .end = end,
                .c0 = g.c0.multiplyAlpha(op),
                .c1 = g.c1.multiplyAlpha(op),
            } });
        },
        .material => |m| {
            const s = m.spec();
            try canvas.blurRect(rect, radius, s.sigma, s.tint.multiplyAlpha(op));
        },
    }
}

fn paintShape(canvas: *Canvas, sh: ShapeData, rect: Rect, op: f32) !void {
    switch (sh.shape) {
        .rect => try paintFill(canvas, rect, 0, sh.fill, op),
        .rounded_rect => try paintFill(canvas, rect, sh.corner_radius, sh.fill, op),
        .capsule => try paintFill(canvas, rect, @min(rect.width, rect.height) / 2, sh.fill, op),
        .ellipse => try paintFill(canvas, rect, @min(rect.width, rect.height) / 2, sh.fill, op),
        .circle => {
            const r = @min(rect.width, rect.height) / 2;
            const sq = Rect{ .x = rect.midX() - r, .y = rect.midY() - r, .width = 2 * r, .height = 2 * r };
            try paintFill(canvas, sq, r, sh.fill, op);
        },
    }
}

fn paintButton(ctx: *const Context, b: ButtonData, rect: Rect, canvas: *Canvas) !void {
    const m = ctx.theme.metrics;
    const dim: f32 = if (ctx.disabled) 0.4 else 1.0;
    if (b.role != .plain) {
        const bg = if (b.role == .destructive) ctx.theme.colors.destructive else ctx.theme.colors.accent;
        try canvas.fillRoundedRect(rect, m.control_corner_radius, bg.multiplyAlpha(ctx.opacity * dim));
    }
    const label_color = if (b.role == .plain) ctx.theme.colors.accent else ctx.theme.colors.on_accent;
    const px = ctx.theme.typography.body.size;
    const lw = shape.measureLineWidth(ctx.cache.face, b.label, px);
    const lh = shape.lineHeight(ctx.cache.face, px);
    const origin = Point{
        .x = rect.x + (rect.width - lw) / 2,
        .y = rect.y + (rect.height - lh) / 2,
    };
    drawTextC(ctx, canvas, b.label, px, label_color.multiplyAlpha(ctx.opacity * dim), origin) catch {};
    try ctx.hit_regions.append(ctx.arena, .{ .rect = rect, .action = .{ .callback = b.action }, .disabled = ctx.disabled });
}

/// Draw text honoring the context scale: at scale 1 the normal path; otherwise
/// the HiDPI path that rasterizes glyphs at device resolution (the command list
/// is uniformly scaled afterward by `renderScaled`).
fn drawTextC(ctx: *const Context, canvas: *Canvas, text: []const u8, px: f32, color: Color, origin: Point) !void {
    if (ctx.scale == 1) {
        try font_mod.drawText(canvas, ctx.cache, text, px, color, origin);
    } else {
        try font_mod.drawTextScaled(canvas, ctx.cache, text, px, ctx.scale, color, origin);
    }
}

fn vcenter(rect: Rect, h: f32) f32 {
    return rect.y + (rect.height - h) / 2;
}

fn paintToggle(ctx: *const Context, t: ToggleData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const px = ctx.theme.typography.body.size;
    // label on the leading edge
    if (t.label.len > 0) {
        const lh = shape.lineHeight(ctx.cache.face, px);
        drawTextC(ctx, canvas, t.label, px, ctx.foreground.multiplyAlpha(op), .{ .x = rect.x, .y = vcenter(rect, lh) }) catch {};
    }
    // switch on the trailing edge
    const sw = Rect{ .x = rect.maxX() - switch_w, .y = vcenter(rect, switch_h), .width = switch_w, .height = switch_h };
    const on = t.value.get();
    const track = if (on) ctx.theme.colors.accent else ctx.theme.colors.separator.over(ctx.theme.colors.control_background);
    try canvas.fillRoundedRect(sw, switch_h / 2, track.multiplyAlpha(op));
    const knob_r = switch_h / 2 - 2;
    const knob_cx = if (on) sw.maxX() - knob_r - 2 else sw.x + knob_r + 2;
    try canvas.fillCircle(.{ .x = knob_cx, .y = sw.midY() }, knob_r, Color.white.multiplyAlpha(op));
    try ctx.hit_regions.append(ctx.arena, .{ .rect = rect, .action = .{ .toggle = t.value }, .disabled = ctx.disabled });
}

fn paintSlider(ctx: *const Context, s: SliderData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const r = slider_knob_r;
    const track = Rect{ .x = rect.x + r, .y = rect.midY() - slider_track_h / 2, .width = rect.width - 2 * r, .height = slider_track_h };
    const denom = if (s.max - s.min == 0) 1 else s.max - s.min;
    const frac = std.math.clamp((s.value.get() - s.min) / denom, 0, 1);
    // unfilled track
    try canvas.fillRoundedRect(track, slider_track_h / 2, ctx.theme.colors.separator.over(ctx.theme.colors.control_background).multiplyAlpha(op));
    // filled portion
    const filled = Rect{ .x = track.x, .y = track.y, .width = track.width * frac, .height = track.height };
    try canvas.fillRoundedRect(filled, slider_track_h / 2, ctx.theme.colors.accent.multiplyAlpha(op));
    // knob
    const knob_cx = track.x + track.width * frac;
    try canvas.fillCircle(.{ .x = knob_cx, .y = rect.midY() }, r, Color.white.multiplyAlpha(op));
    try canvas.strokeRoundedRect(.{ .x = knob_cx - r, .y = rect.midY() - r, .width = 2 * r, .height = 2 * r }, r, 1, ctx.theme.colors.separator.multiplyAlpha(op));
    try ctx.hit_regions.append(ctx.arena, .{
        .rect = rect,
        .action = .{ .slider = .{ .binding = s.value, .min = s.min, .max = s.max, .track = track } },
        .disabled = ctx.disabled,
    });
}

fn paintStepper(ctx: *const Context, s: StepperData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const m = ctx.theme.metrics;
    const px = ctx.theme.typography.body.size;
    if (s.label.len > 0) {
        const lh = shape.lineHeight(ctx.cache.face, px);
        drawTextC(ctx, canvas, s.label, px, ctx.foreground.multiplyAlpha(op), .{ .x = rect.x, .y = vcenter(rect, lh) }) catch {};
    }
    const ctrl = Rect{ .x = rect.maxX() - stepper_w, .y = rect.y, .width = stepper_w, .height = rect.height };
    try canvas.fillRoundedRect(ctrl, m.control_corner_radius, ctx.theme.colors.control_background.multiplyAlpha(op));
    try canvas.strokeRoundedRect(ctrl, m.control_corner_radius, m.hairline, ctx.theme.colors.separator.multiplyAlpha(op));
    const half = ctrl.width / 2;
    const minus = Rect{ .x = ctrl.x, .y = ctrl.y, .width = half, .height = ctrl.height };
    const plus = Rect{ .x = ctrl.x + half, .y = ctrl.y, .width = half, .height = ctrl.height };
    try canvas.line(.{ .x = ctrl.midX(), .y = ctrl.y + 4 }, .{ .x = ctrl.midX(), .y = ctrl.maxY() - 4 }, m.hairline, ctx.theme.colors.separator.multiplyAlpha(op));
    // glyph-ish: minus and plus drawn as small lines
    const mc = ctx.foreground.multiplyAlpha(op);
    try canvas.line(.{ .x = minus.midX() - 4, .y = minus.midY() }, .{ .x = minus.midX() + 4, .y = minus.midY() }, 1.5, mc);
    try canvas.line(.{ .x = plus.midX() - 4, .y = plus.midY() }, .{ .x = plus.midX() + 4, .y = plus.midY() }, 1.5, mc);
    try canvas.line(.{ .x = plus.midX(), .y = plus.midY() - 4 }, .{ .x = plus.midX(), .y = plus.midY() + 4 }, 1.5, mc);
    try ctx.hit_regions.append(ctx.arena, .{ .rect = minus, .action = .{ .step = .{ .binding = s.value, .delta = -s.step, .min = s.min, .max = s.max } }, .disabled = ctx.disabled });
    try ctx.hit_regions.append(ctx.arena, .{ .rect = plus, .action = .{ .step = .{ .binding = s.value, .delta = s.step, .min = s.min, .max = s.max } }, .disabled = ctx.disabled });
}

fn paintProgress(ctx: *const Context, pr: ProgressData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const bar = Rect{ .x = rect.x, .y = rect.midY() - progress_h / 2, .width = rect.width, .height = progress_h };
    try canvas.fillRoundedRect(bar, progress_h / 2, ctx.theme.colors.separator.over(ctx.theme.colors.control_background).multiplyAlpha(op));
    const filled = Rect{ .x = bar.x, .y = bar.y, .width = bar.width * std.math.clamp(pr.value, 0, 1), .height = bar.height };
    try canvas.fillRoundedRect(filled, progress_h / 2, ctx.theme.colors.accent.multiplyAlpha(op));
}

fn paintLabel(ctx: *const Context, l: LabelData, v: View, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const px = resolvedFontSize(ctx, v);
    const icon = Rect{ .x = rect.x, .y = vcenter(rect, label_icon), .width = label_icon, .height = label_icon };
    try canvas.fillRoundedRect(icon, 3, l.symbol_color.multiplyAlpha(op));
    const lh = shape.lineHeight(ctx.cache.face, px);
    drawTextC(ctx, canvas, l.title, px, ctx.foreground.multiplyAlpha(op), .{ .x = rect.x + label_icon + label_gap, .y = vcenter(rect, lh) }) catch {};
}

/// Paint wrapped text: re-wrap to the laid-out rect width and draw each line,
/// stacked by line height, top-aligned within `rect`.
fn paintWrappedText(ctx: *const Context, v: View, wt: WrappedTextData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const px = resolvedFontSize(ctx, v);
    const lh = shape.lineHeight(ctx.cache.face, px);
    const color = ctx.foreground.multiplyAlpha(op);
    const lines = try shape.wrapText(ctx.arena, ctx.cache.face, wt.string, px, rect.width);
    for (lines, 0..) |ln, i| {
        const slice = wt.string[ln.start..ln.end];
        const y = rect.y + @as(f32, @floatFromInt(i)) * lh;
        drawTextC(ctx, canvas, slice, px, color, .{ .x = rect.x, .y = y }) catch {};
    }
}

fn paintTextField(ctx: *const Context, v: View, tf: TextFieldData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const m = ctx.theme.metrics;
    // Honor an explicit `.cornerRadius(...)` so fields can be pill-shaped; fall
    // back to the theme's control radius.
    const radius = if (v.mods.corner_radius > 0) v.mods.corner_radius else m.control_corner_radius;
    try canvas.fillRoundedRect(rect, radius, ctx.theme.colors.control_background.multiplyAlpha(op));
    const focused = tf.state.focused;
    // Keep the focused field's submit callback current so `submitFocused` (fired
    // from the event loop on Enter) can reach it without the view tree.
    if (focused) tf.state.on_submit = v.mods.on_submit;
    const border = if (focused) ctx.theme.colors.accent else ctx.theme.colors.separator;
    try canvas.strokeRoundedRect(rect, radius, if (focused) 2 else m.hairline, border.multiplyAlpha(op));

    const px = ctx.theme.typography.body.size;
    const lh = shape.lineHeight(ctx.cache.face, px);
    // Inset text past the corner curve (more for pills).
    const pad: f32 = @max(8, @min(radius, 14));
    const ty = vcenter(rect, lh);
    const content = tf.state.text();
    if (content.len == 0 and tf.placeholder.len > 0) {
        drawTextC(ctx, canvas, tf.placeholder, px, ctx.theme.colors.tertiary_label.multiplyAlpha(op), .{ .x = rect.x + pad, .y = ty }) catch {};
    } else {
        drawTextC(ctx, canvas, content, px, ctx.foreground.multiplyAlpha(op), .{ .x = rect.x + pad, .y = ty }) catch {};
    }
    // caret
    if (focused) {
        const caret_x = rect.x + pad + shape.measureLineWidth(ctx.cache.face, content[0..tf.state.caret], px);
        try canvas.line(.{ .x = caret_x, .y = ty + 2 }, .{ .x = caret_x, .y = ty + lh - 2 }, 1, ctx.theme.colors.accent.multiplyAlpha(op));
    }
    try ctx.hit_regions.append(ctx.arena, .{ .rect = rect, .action = .{ .focus = tf.state }, .disabled = ctx.disabled });
}

fn paintPicker(ctx: *const Context, pk: PickerData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const m = ctx.theme.metrics;
    const n = pk.options.len;
    if (n == 0) return;
    // segmented-control background
    try canvas.fillRoundedRect(rect, m.control_corner_radius, ctx.theme.colors.separator.over(ctx.theme.colors.window_background).multiplyAlpha(op));
    const seg_w = rect.width / @as(f32, @floatFromInt(n));
    const px = ctx.theme.typography.body.size;
    const lh = shape.lineHeight(ctx.cache.face, px);
    const selected = pk.selection.get();
    for (pk.options, 0..) |opt, i| {
        const seg = Rect{ .x = rect.x + @as(f32, @floatFromInt(i)) * seg_w, .y = rect.y, .width = seg_w, .height = rect.height };
        if (@as(i64, @intCast(i)) == selected) {
            const inner = seg.insetBy(2, 2);
            try canvas.fillRoundedRect(inner, m.control_corner_radius - 1, ctx.theme.colors.control_background.multiplyAlpha(op));
        }
        const tw = shape.measureLineWidth(ctx.cache.face, opt, px);
        drawTextC(ctx, canvas, opt, px, ctx.foreground.multiplyAlpha(op), .{
            .x = seg.x + (seg.width - tw) / 2,
            .y = vcenter(seg, lh),
        }) catch {};
        try ctx.hit_regions.append(ctx.arena, .{
            .rect = seg,
            .action = .{ .select = .{ .binding = pk.selection, .value = @intCast(i) } },
            .disabled = ctx.disabled,
        });
    }
}

fn paintScroll(ctx: *const Context, sd: ScrollData, rect: Rect, canvas: *Canvas) Allocator.Error!void {
    try canvas.pushClip(rect, 0);
    defer canvas.popClip() catch {};
    const content_prop: engine.Proposal = if (sd.axis == .vertical)
        .{ .width = rect.width, .height = null }
    else
        .{ .width = null, .height = rect.height };
    const csize = try measure(ctx, sd.content.*, content_prop);
    const content_rect = if (sd.axis == .vertical)
        Rect{ .x = rect.x, .y = rect.y - sd.offset, .width = rect.width, .height = csize.height }
    else
        Rect{ .x = rect.x - sd.offset, .y = rect.y, .width = csize.width, .height = rect.height };
    // renderInto (not render): overlays are drained once, by the top-level render.
    try renderInto(ctx, sd.content.*, content_rect, canvas);
}

/// Paint a `ScrollViewState`: a vertical viewport scrolled by the app-owned
/// `state.offset`. Writes back the measured content/viewport heights, clamps the
/// offset, draws the clipped content, and (when the sink is set) registers a
/// `ScrollRegion` for wheel routing.
fn paintScrollState(ctx: *const Context, sd: ScrollStateData, rect: Rect, canvas: *Canvas) Allocator.Error!void {
    try canvas.pushClip(rect, 0);
    defer canvas.popClip() catch {};
    const csize = try measure(ctx, sd.content.*, .{ .width = rect.width, .height = null });
    // Record geometry so maxOffset()/atBottom() are accurate, then clamp.
    sd.state.content_h = csize.height;
    sd.state.viewport_h = rect.height;
    sd.state.offset = std.math.clamp(sd.state.offset, 0, sd.state.maxOffset());
    const content_rect = Rect{ .x = rect.x, .y = rect.y - sd.state.offset, .width = rect.width, .height = csize.height };
    // renderInto (not render): overlays are drained once, by the top-level render.
    try renderInto(ctx, sd.content.*, content_rect, canvas);
    if (ctx.scroll_regions) |regions| {
        try regions.append(ctx.arena, .{ .rect = rect, .state = sd.state });
    }
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

/// Dispatch a tap at `p` to the top-most enabled hit region containing it.
/// Returns true if a callback fired.
pub fn dispatchTap(regions: []const HitRegion, p: Point) bool {
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (!r.disabled and r.rect.contains(p)) {
            performAction(r.action, p);
            return true;
        }
    }
    return false;
}

/// Points scrolled per unit of wheel delta. Negative so a wheel-up (positive
/// `dy` in SDL) moves the content toward the top (decreasing offset), matching
/// platform convention.
const scroll_speed: f32 = -28;

/// Route a wheel delta `dy` to the top-most scroll region containing `p`
/// (back-to-front, like `dispatchTap`). Returns true if a region consumed it.
pub fn dispatchScroll(regions: []const ScrollRegion, p: Point, dy: f32) bool {
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.rect.contains(p)) {
            r.state.scrollBy(dy * scroll_speed);
            return true;
        }
    }
    return false;
}

fn performAction(a: HitAction, p: Point) void {
    switch (a) {
        .callback => |cb| cb.call(),
        .toggle => |b| b.set(!b.get()),
        .slider => |s| s.binding.set(sliderValueForX(s.track, s.min, s.max, p.x)),
        .step => |s| {
            const next = std.math.clamp(s.binding.get() + s.delta, s.min, s.max);
            s.binding.set(next);
        },
        .focus => |fs| setFocus(fs),
        .select => |s| s.binding.set(s.value),
    }
}

/// The currently focused text field, for routing keyboard events. Managed by
/// the app/event loop via `setFocus`/`clearFocus`.
threadlocal var g_focused: ?*TextFieldState = null;

pub fn focusedField() ?*TextFieldState {
    return g_focused;
}
pub fn setFocus(fs: *TextFieldState) void {
    if (g_focused) |prev| {
        if (prev != fs) prev.focused = false;
    }
    fs.focused = true;
    g_focused = fs;
}
pub fn clearFocus() void {
    if (g_focused) |prev| prev.focused = false;
    g_focused = null;
}

/// Submit the focused text field: fire its `.onSubmit` callback if it has one.
/// A no-op when nothing is focused or no callback was set. The app calls this on
/// Enter.
pub fn submitFocused() void {
    if (g_focused) |fs| {
        if (fs.on_submit) |cb| cb.call();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const raster = @import("../render/raster.zig");

const TestEnv = struct {
    font: font_mod.Font,
    cache: atlas.GlyphCache,
    hits: std.ArrayList(HitRegion),
    arena_state: std.heap.ArenaAllocator,

    fn init() TestEnv {
        return .{
            .font = font_mod.Font.default(),
            .cache = undefined,
            .hits = .empty,
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }
    fn setup(self: *TestEnv) void {
        self.cache = atlas.GlyphCache.init(testing.allocator, &self.font.face);
        beginBuild(self.arena_state.allocator());
    }
    fn ctx(self: *TestEnv) Context {
        return Context.init(@import("../theme/macos.zig").light, &self.cache, self.arena_state.allocator(), &self.hits);
    }
    fn deinit(self: *TestEnv) void {
        endBuild();
        self.cache.deinit();
        // hit regions are appended via the arena, freed by arena_state.deinit()
        self.arena_state.deinit();
    }
};

test "view: modifiers chain and set fields" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const v = Text("Hi").padding(8).foreground(Color.red).font(.title).opacity(0.5);
    try testing.expectEqual(EdgeInsets.all(8), v.mods.padding.?);
    try testing.expectEqual(Color.red, v.mods.foreground.?);
    try testing.expectEqual(FontToken.title, v.mods.font.?);
    try testing.expectEqual(@as(f32, 0.5), v.mods.opacity);
}

test "view: VStack measures to sum of child heights plus spacing" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const tree = VStack(.{ Text("AAAA"), Text("B") }).spacing(10);
    const size = try measure(&c, tree, .unspecified);
    const lh = shape.lineHeight(&env.font.face, env.ctx().theme.typography.body.size);
    try testing.expectApproxEqAbs(2 * lh + 10, size.height, 0.5);
    // width = wider of the two lines (the 4-char line)
    const w4 = shape.measureLineWidth(&env.font.face, "AAAA", c.theme.typography.body.size);
    try testing.expectApproxEqAbs(w4, size.width, 0.5);
}

test "view: Rectangle fills its frame with color" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const tree = Rectangle(Color.red);
    try render(&c, tree, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, &canvas);

    var fb = try raster.Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    try testing.expect(fb.at(10, 10).approxEql(Color.red, 0.02));
}

test "view: padding insets the content" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // A red rectangle padded 5 inside a 20x20 frame -> red only in the inner 10x10.
    const tree = Rectangle(Color.red).padding(5);
    try render(&c, tree, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, &canvas);

    var fb = try raster.Framebuffer.init(testing.allocator, 20, 20);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    try testing.expect(fb.at(10, 10).approxEql(Color.red, 0.02)); // inside
    try testing.expect(fb.at(1, 1).approxEql(Color.white, 0.05)); // padding margin
}

test "view: background paints behind text" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const tree = Text("A").padding(4).background(Color.blue);
    const size = try measure(&c, tree, .unspecified);
    try render(&c, tree, Rect.fromOriginSize(.{}, size), &canvas);
    // first command should be the background fill
    try testing.expect(canvas.commands.items[0] == .fill_rrect);
    try testing.expect(canvas.commands.items[0].fill_rrect.color.approxEql(Color.blue, 0.02));
}

test "view: Button registers a hit region and tap fires the action" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();

    Counter.value = 0;
    const tree = Button("Click", action(Counter.inc));
    const size = try measure(&c, tree, .unspecified);
    try render(&c, tree, Rect.fromOriginSize(.{}, size), &canvas);

    try testing.expectEqual(@as(usize, 1), env.hits.items.len);
    // tap inside -> fires
    try testing.expect(dispatchTap(env.hits.items, .{ .x = size.width / 2, .y = size.height / 2 }));
    try testing.expectEqual(@as(u32, 1), Counter.value);
    // tap outside -> nothing
    try testing.expect(!dispatchTap(env.hits.items, .{ .x = 9999, .y = 9999 }));
    try testing.expectEqual(@as(u32, 1), Counter.value);
}

const Counter = struct {
    var value: u32 = 0;
    fn inc() void {
        value += 1;
    }
};

test "view: disabled view's tap region does not fire" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    Counter.value = 0;
    const tree = Rectangle(Color.red).frame(20, 20).onTap(action(Counter.inc)).disabled(true);
    try render(&c, tree, .{ .x = 0, .y = 0, .width = 20, .height = 20 }, &canvas);
    try testing.expect(!dispatchTap(env.hits.items, .{ .x = 10, .y = 10 }));
    try testing.expectEqual(@as(u32, 0), Counter.value);
}

test "view: ForEach expands into stack children" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const items = [_][]const u8{ "a", "b", "c" };
    const tree = VStack(.{ForEach(&items, makeRow)});
    try testing.expectEqual(@as(usize, 3), tree.kind.stack.children.len);
    const size = try measure(&c, tree, .unspecified);
    try testing.expect(size.height > 0);
}

fn makeRow(s: []const u8) View {
    return Text(s);
}

test "view: HStack lays children left to right" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const tree = HStack(.{ Rectangle(Color.red).frame(10, 10), Rectangle(Color.blue).frame(10, 10) }).spacing(5);
    const size = try measure(&c, tree, .unspecified);
    try testing.expectApproxEqAbs(@as(f32, 25), size.width, 0.01); // 10 + 5 + 10
    try testing.expectApproxEqAbs(@as(f32, 10), size.height, 0.01);
}

test "view: fmt allocates state-derived text in the build arena" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const s = fmt("Count: {d}", .{42});
    try testing.expectEqualStrings("Count: 42", s);
}

fn renderToFb(env: *TestEnv, c: *Context, tree: View, rect: Rect, w: u32, h: u32) !raster.Framebuffer {
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(c, tree, rect, &canvas);
    var fb = try raster.Framebuffer.init(testing.allocator, w, h);
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    _ = env;
    return fb;
}

fn countBlue(fb: *const raster.Framebuffer) u32 {
    var n: u32 = 0;
    for (fb.pixels) |p| {
        if (p.b > p.r + 0.2 and p.b > 0.4) n += 1;
    }
    return n;
}

fn countRed(fb: *const raster.Framebuffer) u32 {
    var n: u32 = 0;
    for (fb.pixels) |p| {
        if (p.r > p.b + 0.2 and p.r > 0.4) n += 1;
    }
    return n;
}

test "view: Toggle reflects and mutates its binding" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var s = state.State(bool).init(testing.allocator, false);
    defer s.deinit();

    // off: little/no accent in the switch
    var off_fb = try renderToFb(&env, &c, Toggle("", s.binding()).frame(60, 30), .{ .x = 0, .y = 0, .width = 60, .height = 30 }, 60, 30);
    defer off_fb.deinit();
    const off_blue = countBlue(&off_fb);

    // tapping flips the binding
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 45, .y = 15 }));
    try testing.expect(s.get());

    // on: accent track now visible
    env.hits.clearRetainingCapacity();
    var on_fb = try renderToFb(&env, &c, Toggle("", s.binding()).frame(60, 30), .{ .x = 0, .y = 0, .width = 60, .height = 30 }, 60, 30);
    defer on_fb.deinit();
    try testing.expect(countBlue(&on_fb) > off_blue + 20);
}

test "view: Slider sets value from tap position" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var s = state.State(f32).init(testing.allocator, 0);
    defer s.deinit();
    var fb = try renderToFb(&env, &c, Slider(s.binding(), 0, 1), .{ .x = 0, .y = 0, .width = 100, .height = 20 }, 100, 20);
    defer fb.deinit();
    // tap near the right end -> value near max
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 95, .y = 10 }));
    try testing.expect(s.get() > 0.8);
    // tap near the left -> value near min
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 5, .y = 10 }));
    try testing.expect(s.get() < 0.2);
}

test "view: Stepper increments and clamps" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var s = state.State(i64).init(testing.allocator, 5);
    defer s.deinit();
    var fb = try renderToFb(&env, &c, Stepper("Count", s.binding(), 0, 6, 1), .{ .x = 0, .y = 0, .width = 120, .height = 28 }, 120, 28);
    defer fb.deinit();
    // plus button is the right quarter of the trailing control
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 103, .y = 14 }));
    try testing.expectEqual(@as(i64, 6), s.get());
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 103, .y = 14 })); // clamp at max
    try testing.expectEqual(@as(i64, 6), s.get());
    // minus button (left half of control)
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 69, .y = 14 }));
    try testing.expectEqual(@as(i64, 5), s.get());
}

test "view: ProgressView fills proportionally" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var fb = try renderToFb(&env, &c, ProgressView(0.5), .{ .x = 0, .y = 0, .width = 100, .height = 20 }, 100, 20);
    defer fb.deinit();
    try testing.expect(fb.at(10, 10).b > fb.at(10, 10).r); // left half accent
    try testing.expect(!(fb.at(90, 10).b > fb.at(90, 10).r + 0.2)); // right half unfilled
}

test "view: LinearGradient interpolates across its frame" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var fb = try renderToFb(&env, &c, LinearGradient(Color.red, Color.blue, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }), .{ .x = 0, .y = 0, .width = 100, .height = 10 }, 100, 10);
    defer fb.deinit();
    try testing.expect(fb.at(2, 5).r > 0.8);
    try testing.expect(fb.at(97, 5).b > 0.8);
}

test "view: Image blits pixels" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    // 4x4 opaque green image; an Image keeps its intrinsic size by default.
    const px = [_]u8{ 0, 255, 0, 255 } ** 16;
    const img = canvas_mod.Image{ .width = 4, .height = 4, .pixels = &px };
    var fb = try renderToFb(&env, &c, Image(img), .{ .x = 0, .y = 0, .width = 4, .height = 4 }, 4, 4);
    defer fb.deinit();
    try testing.expect(fb.at(2, 2).approxEql(Color.green, 0.02));
}

test "view: Label draws an icon swatch then the title" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const tree = Label("Wi-Fi", Color.blue);
    const size = try measure(&c, tree, .unspecified);
    try render(&c, tree, Rect.fromOriginSize(.{}, size), &canvas);
    try testing.expect(canvas.commands.items[0] == .fill_rrect); // the icon swatch
    try testing.expect(canvas.commands.items[0].fill_rrect.color.approxEql(Color.blue, 0.02));
    try testing.expect(canvas.count() > 1); // plus glyphs
}

test "view: WrappedText measures taller at a narrow width than a wide one" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const s = "the quick brown fox jumps over the lazy dog";
    const px = c.theme.typography.body.size;
    const full = shape.measureLineWidth(&env.font.face, s, px);
    const lh = shape.lineHeight(&env.font.face, px);

    const tree = WrappedText(s);
    // proposed half the single-line width -> wraps to at least two lines
    const narrow = try measure(&c, tree, .{ .width = full / 2, .height = null });
    try testing.expect(narrow.height >= 2 * lh - 0.5);
    try testing.expect(narrow.width <= full / 2 + 0.5);
    // proposed the full width -> a single line
    const wide = try measure(&c, tree, .{ .width = full + 10, .height = null });
    try testing.expectApproxEqAbs(lh, wide.height, 0.5);
}

test "view: WrappedText breaks on an explicit newline" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const px = c.theme.typography.body.size;
    const lh = shape.lineHeight(&env.font.face, px);
    const size = try measure(&c, WrappedText("a\nb"), .{ .width = 1000, .height = null });
    try testing.expectApproxEqAbs(2 * lh, size.height, 0.5);
}

test "view: WrappedText renders ink spanning more than one line vertically" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const s = "hello wonderful wrapping world";
    const px = c.theme.typography.body.size;
    const full = shape.measureLineWidth(&env.font.face, s, px);
    const lh = shape.lineHeight(&env.font.face, px);
    const w: u32 = @intFromFloat(@ceil(full / 2));
    const tree = WrappedText(s).foreground(Color.black);
    var fb = try renderToFb(&env, &c, tree, .{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = 120 }, w, 120);
    defer fb.deinit();
    // top-most and bottom-most inked rows should differ by more than a line —
    // proof the text occupies at least two stacked lines.
    var top: ?u32 = null;
    var bottom: u32 = 0;
    var yy: u32 = 0;
    while (yy < fb.height) : (yy += 1) {
        var inked = false;
        var xx: u32 = 0;
        while (xx < fb.width) : (xx += 1) {
            if (fb.at(xx, yy).luminance() < 0.5) {
                inked = true;
                break;
            }
        }
        if (inked) {
            if (top == null) top = yy;
            bottom = yy;
        }
    }
    try testing.expect(top != null);
    try testing.expect(@as(f32, @floatFromInt(bottom - top.?)) > lh);
}

test "view: ScrollState scrollBy clamps and scrollToBottom reaches the bottom" {
    var s = ScrollState{ .content_h = 250, .viewport_h = 100 };
    try testing.expectEqual(@as(f32, 150), s.maxOffset());
    s.scrollBy(1000); // clamps to maxOffset
    try testing.expectEqual(@as(f32, 150), s.offset);
    s.scrollBy(-1000); // clamps to 0
    try testing.expectEqual(@as(f32, 0), s.offset);
    s.scrollToBottom();
    try testing.expectEqual(@as(f32, 150), s.offset);
    try testing.expect(s.atBottom());
    // content fits the viewport -> no scrolling possible
    var fits = ScrollState{ .content_h = 50, .viewport_h = 100 };
    try testing.expectEqual(@as(f32, 0), fits.maxOffset());
    try testing.expect(fits.atBottom());
}

test "view: dispatchScroll routes a wheel delta to the region under the point" {
    var a = ScrollState{ .content_h = 200, .viewport_h = 100, .offset = 50 };
    var b = ScrollState{ .content_h = 200, .viewport_h = 100, .offset = 50 };
    const regions = [_]ScrollRegion{
        .{ .rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .state = &a },
        .{ .rect = .{ .x = 0, .y = 100, .width = 100, .height = 100 }, .state = &b },
    };
    // a point in region b's rect moves b, not a
    try testing.expect(dispatchScroll(&regions, .{ .x = 50, .y = 150 }, 1));
    try testing.expectEqual(@as(f32, 50), a.offset);
    try testing.expect(b.offset != 50);
    // a point outside every region consumes nothing
    try testing.expect(!dispatchScroll(&regions, .{ .x = 500, .y = 500 }, 1));
}

test "view: ScrollViewState registers one region and offset moves the content" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var regions: std.ArrayList(ScrollRegion) = .empty;
    c.scroll_regions = &regions;
    var ss = ScrollState{};
    const content = VStack(.{
        Rectangle(Color.red).frame(50, 30),
        Rectangle(Color.blue).frame(50, 30),
    }).spacing(0);

    // offset 0: content top (red) is visible, geometry recorded, one region.
    var fb0 = try renderToFb(&env, &c, ScrollViewState(&ss, content), .{ .x = 0, .y = 0, .width = 50, .height = 40 }, 50, 40);
    defer fb0.deinit();
    try testing.expectEqual(@as(usize, 1), regions.items.len);
    try testing.expectApproxEqAbs(@as(f32, 60), ss.content_h, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 40), ss.viewport_h, 0.5);
    try testing.expect(fb0.at(25, 8).approxEql(Color.red, 0.05));

    // scroll to the bottom: the second (blue) rectangle is now at the bottom.
    ss.scrollToBottom();
    regions.clearRetainingCapacity();
    env.hits.clearRetainingCapacity();
    var fb1 = try renderToFb(&env, &c, ScrollViewState(&ss, content), .{ .x = 0, .y = 0, .width = 50, .height = 40 }, 50, 40);
    defer fb1.deinit();
    try testing.expect(fb1.at(25, 35).approxEql(Color.blue, 0.05));
}

test "view: ScrollView clips content to its frame" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    // content is taller (60) than the scroll frame (40)
    const content = VStack(.{
        Rectangle(Color.red).frame(50, 30),
        Rectangle(Color.blue).frame(50, 30),
    }).spacing(0);
    const tree = ScrollView(content);
    var fb = try renderToFb(&env, &c, tree, .{ .x = 0, .y = 0, .width = 50, .height = 40 }, 50, 80);
    defer fb.deinit();
    try testing.expect(fb.at(25, 10).approxEql(Color.red, 0.05)); // visible top
    try testing.expect(fb.at(25, 60).approxEql(Color.white, 0.05)); // below frame -> clipped
}

test "TextFieldState: editing operations" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.insert("hello");
    try testing.expectEqualStrings("hello", tf.text());
    try testing.expectEqual(@as(usize, 5), tf.caret);
    tf.backspace();
    try testing.expectEqualStrings("hell", tf.text());
    tf.moveLeft();
    tf.moveLeft();
    try tf.insert("X");
    try testing.expectEqualStrings("heXll", tf.text());
    try tf.setText("done");
    try testing.expectEqualStrings("done", tf.text());
    try testing.expectEqual(@as(usize, 4), tf.caret);
}

test "TextFieldState: backspace handles a multi-byte codepoint" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.insert("é"); // 2 bytes
    try testing.expectEqual(@as(usize, 2), tf.caret);
    tf.backspace();
    try testing.expectEqual(@as(usize, 0), tf.text().len);
}

test "view: TextField paints, focuses on tap, and shows a caret" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.setText("hi");

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, TextField("type…", &tf), .{ .x = 0, .y = 0, .width = 180, .height = 28 }, &canvas);
    const before = canvas.count();
    // tap focuses
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 20, .y = 14 }));
    try testing.expect(tf.focused);

    // focused render draws an extra caret line
    canvas.clearCommands();
    try render(&c, TextField("type…", &tf), .{ .x = 0, .y = 0, .width = 180, .height = 28 }, &canvas);
    var has_line = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .line) has_line = true;
    }
    try testing.expect(has_line);
    _ = before;
}

test "view: onSubmit fires only for a focused field with a callback" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    Counter.value = 0;
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();

    // Focus this field directly (avoids touching any stale global focus pointer
    // a prior test may have left behind).
    tf.focused = true;
    g_focused = &tf;

    // Focused but no onSubmit -> submitFocused is a no-op.
    try render(&c, TextField("msg", &tf), .{ .x = 0, .y = 0, .width = 180, .height = 28 }, &canvas);
    submitFocused();
    try testing.expectEqual(@as(u32, 0), Counter.value);

    // With onSubmit, render (stashing it on the focused field) then submit fires.
    canvas.clearCommands();
    try render(&c, TextField("msg", &tf).onSubmit(action(Counter.inc)), .{ .x = 0, .y = 0, .width = 180, .height = 28 }, &canvas);
    submitFocused();
    try testing.expectEqual(@as(u32, 1), Counter.value);

    clearFocus();
}

test "view: Picker selects a segment on tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, 0);
    defer sel.deinit();
    const opts = [_][]const u8{ "Low", "Medium", "High" };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, Picker(sel.binding(), &opts), .{ .x = 0, .y = 0, .width = 300, .height = 28 }, &canvas);
    try testing.expectEqual(@as(usize, 3), env.hits.items.len); // one region per segment
    // tap the third segment (x ~ 250)
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 250, .y = 14 }));
    try testing.expectEqual(@as(i64, 2), sel.get());
}

fn gridCell(cell_color: Color) View {
    return Rectangle(cell_color).frameHeight(20);
}

test "view: LazyVGrid lays items into ceil(n/cols) rows of horizontal stacks" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const items = [_]Color{ Color.red, Color.green, Color.blue, Color.red, Color.green };
    const tree = LazyVGrid(2, 4, &items, gridCell);
    // a vertical stack of 3 rows (ceil(5/2))
    try testing.expect(tree.kind == .stack);
    try testing.expectEqual(engine.Direction.vertical, tree.kind.stack.direction);
    try testing.expectEqual(@as(usize, 3), tree.kind.stack.children.len);
    // each row is a horizontal stack of `cols` cells
    const row0 = tree.kind.stack.children[0];
    try testing.expect(row0.kind == .stack);
    try testing.expectEqual(engine.Direction.horizontal, row0.kind.stack.direction);
    try testing.expectEqual(@as(usize, 2), row0.kind.stack.children.len);
    // measured height ≈ 3 rows·20 + 2 gaps·4
    const size = try measure(&c, tree, .{ .width = 200, .height = null });
    try testing.expectApproxEqAbs(@as(f32, 3 * 20 + 2 * 4), size.height, 0.5);
}

test "view: LazyVGrid renders cells across rows and columns" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const items = [_]Color{ Color.red, Color.red, Color.red, Color.red };
    const tree = LazyVGrid(2, 0, &items, gridCell);
    var fb = try renderToFb(&env, &c, tree, .{ .x = 0, .y = 0, .width = 40, .height = 40 }, 40, 40);
    defer fb.deinit();
    // 2×2 grid of 20×20 cells -> all four cell centers are red
    try testing.expect(fb.at(10, 5).approxEql(Color.red, 0.05)); // row0 col0
    try testing.expect(fb.at(30, 5).approxEql(Color.red, 0.05)); // row0 col1
    try testing.expect(fb.at(10, 25).approxEql(Color.red, 0.05)); // row1 col0
    try testing.expect(fb.at(30, 25).approxEql(Color.red, 0.05)); // row1 col1
}

test "view: LazyHGrid lays items into ceil(n/rows) columns of vertical stacks" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const items = [_]Color{ Color.red, Color.green, Color.blue };
    const tree = LazyHGrid(2, 4, &items, gridCell);
    // a horizontal stack of 2 columns (ceil(3/2))
    try testing.expect(tree.kind == .stack);
    try testing.expectEqual(engine.Direction.horizontal, tree.kind.stack.direction);
    try testing.expectEqual(@as(usize, 2), tree.kind.stack.children.len);
    try testing.expectEqual(engine.Direction.vertical, tree.kind.stack.children[0].kind.stack.direction);
}

test "NavState: push/pop/top/depth" {
    var nav = NavState.init(testing.allocator);
    defer nav.deinit();
    try testing.expectEqual(@as(usize, 0), nav.depth());
    try testing.expect(nav.top() == null);
    nav.push(7);
    nav.push(3);
    try testing.expectEqual(@as(usize, 2), nav.depth());
    try testing.expectEqual(@as(i64, 3), nav.top().?);
    nav.pop();
    try testing.expectEqual(@as(i64, 7), nav.top().?);
    nav.pop();
    nav.pop(); // underflow is a no-op
    try testing.expectEqual(@as(usize, 0), nav.depth());
    try testing.expect(nav.top() == null);
}

test "view: NavigationLink pushes its route, NavBackButton pops" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var nav = NavState.init(testing.allocator);
    defer nav.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, NavigationLink("Details", 42, &nav), .{ .x = 0, .y = 0, .width = 120, .height = 28 }, &canvas);
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 60, .y = 14 }));
    try testing.expectEqual(@as(usize, 1), nav.depth());
    try testing.expectEqual(@as(i64, 42), nav.top().?);

    // a back button pops it
    env.hits.clearRetainingCapacity();
    canvas.clearCommands();
    try render(&c, NavBackButton("Back", &nav), .{ .x = 0, .y = 0, .width = 80, .height = 28 }, &canvas);
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 40, .y = 14 }));
    try testing.expectEqual(@as(usize, 0), nav.depth());
}

test "view: NavigationSplitView is a 220 sidebar, divider, filling detail" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const c = env.ctx();
    const tree = NavigationSplitView(Text("Sidebar"), Text("Detail"), c.theme.colors.secondary_background);
    try testing.expect(tree.kind == .stack);
    try testing.expectEqual(engine.Direction.horizontal, tree.kind.stack.direction);
    try testing.expectEqual(@as(usize, 3), tree.kind.stack.children.len);
    // sidebar fixed 220 wide with a themed background
    try testing.expectEqual(@as(f32, 220), tree.kind.stack.children[0].mods.frame.?.width.?);
    try testing.expect(tree.kind.stack.children[0].mods.background != null);
    // vertical hairline in the middle
    try testing.expect(tree.kind.stack.children[1].kind == .vdivider);
    // detail fills remaining width
    try testing.expectEqual(inf, tree.kind.stack.children[2].mods.frame.?.max_width.?);
}

fn firstGlyphCoverageWidth(canvas: *const Canvas) ?u32 {
    for (canvas.commands.items) |cmd| {
        if (cmd == .glyph) return cmd.glyph.coverage.width;
    }
    return null;
}

test "view: renderScaled rasterizes glyphs at device resolution (crisp, not upscaled)" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const root = Rect{ .x = 0, .y = 0, .width = 60, .height = 30 };
    const tree = Text("A").font(.title);

    var canvas1 = Canvas.init(testing.allocator);
    defer canvas1.deinit();
    try renderScaled(&c, tree, root, 1, &canvas1);

    var canvas2 = Canvas.init(testing.allocator);
    defer canvas2.deinit();
    try renderScaled(&c, tree, root, 2, &canvas2);

    const w1 = firstGlyphCoverageWidth(&canvas1).?;
    const w2 = firstGlyphCoverageWidth(&canvas2).?;
    // the 2× coverage bitmap is genuinely ~2× wider — rasterized at device px,
    // not a stretched 1× glyph (which would keep the same coverage width)
    try testing.expect(w2 >= w1 * 2 - 2 and w2 <= w1 * 2 + 2);
}

test "view: renderScaled doubles shape coordinates and ~4×s glyph ink at scale 2" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();

    // (a) a shape's device coordinates scale by the factor
    const shape_tree = Rectangle(Color.red).frame(10, 10);
    const root = Rect{ .x = 0, .y = 0, .width = 40, .height = 40 };
    var s1 = Canvas.init(testing.allocator);
    defer s1.deinit();
    try renderScaled(&c, shape_tree, root, 1, &s1);
    var fb1 = try raster.Framebuffer.init(testing.allocator, 40, 40);
    defer fb1.deinit();
    fb1.clear(Color.white);
    try raster.render(testing.allocator, &fb1, s1.commands.items);

    var s2 = Canvas.init(testing.allocator);
    defer s2.deinit();
    try renderScaled(&c, shape_tree, root, 2, &s2);
    var fb2 = try raster.Framebuffer.init(testing.allocator, 80, 80);
    defer fb2.deinit();
    fb2.clear(Color.white);
    try raster.render(testing.allocator, &fb2, s2.commands.items);

    // the 10×10 shape is centered at point (20,20); at scale 2 its center lands
    // at device (40,40) and it is absent where the scale-1 block sat (20,20)
    try testing.expect(fb1.at(20, 20).approxEql(Color.red, 0.1));
    try testing.expect(fb2.at(40, 40).approxEql(Color.red, 0.1));
    try testing.expect(fb2.at(20, 20).approxEql(Color.white, 0.1));

    // (b) glyph ink area roughly quadruples (2× linear) between scales
    const text_tree = Text("Ag").font(.title);
    var t1 = Canvas.init(testing.allocator);
    defer t1.deinit();
    try renderScaled(&c, text_tree, .{ .x = 0, .y = 0, .width = 80, .height = 40 }, 1, &t1);
    var tf1 = try raster.Framebuffer.init(testing.allocator, 80, 40);
    defer tf1.deinit();
    tf1.clear(Color.white);
    try raster.render(testing.allocator, &tf1, t1.commands.items);

    var t2 = Canvas.init(testing.allocator);
    defer t2.deinit();
    try renderScaled(&c, text_tree, .{ .x = 0, .y = 0, .width = 80, .height = 40 }, 2, &t2);
    var tf2 = try raster.Framebuffer.init(testing.allocator, 160, 80);
    defer tf2.deinit();
    tf2.clear(Color.white);
    try raster.render(testing.allocator, &tf2, t2.commands.items);

    const ink1 = countDark(&tf1);
    const ink2 = countDark(&tf2);
    try testing.expect(ink1 > 10);
    try testing.expect(ink2 > ink1 * 3); // ~4× the inked area
}

fn countDark(fb: *const raster.Framebuffer) u32 {
    var n: u32 = 0;
    for (fb.pixels) |p| {
        if (p.luminance() < 0.5) n += 1;
    }
    return n;
}

test "view: backgroundMaterial frosts the backdrop drawn beneath it" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // a sharp red→blue gradient backdrop, then a centered 40×40 material panel
    const tree = ZStack(.{
        LinearGradient(Color.red, Color.blue, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }).frameMaxWidth().frameMaxHeight(),
        Empty().frame(40, 40).backgroundMaterial(.regular),
    });
    const root = Rect{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try render(&c, tree, root, &canvas);

    // the material emits a blur command
    var has_blur = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .blur_rect) has_blur = true;
    }
    try testing.expect(has_blur);

    var fb = try raster.Framebuffer.init(testing.allocator, 100, 100);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    // inside the panel the frost lightens the gradient vs. the raw backdrop above it
    try testing.expect(fb.at(50, 50).luminance() > fb.at(50, 5).luminance() + 0.2);
}

test "a11y: emits a node per meaningful component with roles, labels, values" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var a11y: std.ArrayList(A11yNode) = .empty;
    c.a11y = &a11y;
    var on = state.State(bool).init(testing.allocator, true);
    defer on.deinit();
    var amount = state.State(f32).init(testing.allocator, 0.5);
    defer amount.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const tree = VStack(.{
        Text("Title"),
        Button("Increment", action(Counter.inc)),
        Toggle("Wi-Fi", on.binding()),
        Slider(amount.binding(), 0, 1),
    });
    try render(&c, tree, .{ .x = 0, .y = 0, .width = 200, .height = 200 }, &canvas);

    var has_text = false;
    var has_button = false;
    var switch_on = false;
    var has_slider = false;
    for (a11y.items) |n| {
        switch (n.role) {
            .static_text => if (std.mem.eql(u8, n.label, "Title")) {
                has_text = true;
            },
            .button => if (std.mem.eql(u8, n.label, "Increment")) {
                has_button = true;
            },
            .switch_ => if (std.mem.eql(u8, n.value, "on")) {
                switch_on = true;
            },
            .slider => has_slider = true,
            else => {},
        }
    }
    try testing.expect(has_text);
    try testing.expect(has_button);
    try testing.expect(switch_on);
    try testing.expect(has_slider);
}

test "a11y: accessibilityHidden drops a node; accessibilityLabel overrides it" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var a11y: std.ArrayList(A11yNode) = .empty;
    c.a11y = &a11y;

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const tree = VStack(.{
        Text("secret").accessibilityHidden(true),
        Text("raw").accessibilityLabel("Friendly"),
    });
    try render(&c, tree, .{ .x = 0, .y = 0, .width = 200, .height = 100 }, &canvas);

    var saw_secret = false;
    var saw_friendly = false;
    var saw_raw = false;
    for (a11y.items) |n| {
        if (std.mem.eql(u8, n.label, "secret")) saw_secret = true;
        if (std.mem.eql(u8, n.label, "Friendly")) saw_friendly = true;
        if (std.mem.eql(u8, n.label, "raw")) saw_raw = true;
    }
    try testing.expect(!saw_secret); // hidden from the tree
    try testing.expect(saw_friendly); // label overridden
    try testing.expect(!saw_raw); // original label replaced, not duplicated
}

test "view: sheet enqueues an overlay, draws a scrim over content, dismisses on scrim tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ovs: std.ArrayList(OverlayReq) = .empty;
    c.overlays = &ovs;
    var presented = state.State(bool).init(testing.allocator, true);
    defer presented.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const root = Rect{ .x = 0, .y = 0, .width = 200, .height = 200 };
    const sheet_content = Rectangle(Color.red).frame(120, 60);
    try render(&c, Text("Base").sheet(presented.binding(), sheet_content), root, &canvas);

    // one overlay collected with the right style
    try testing.expectEqual(@as(usize, 1), ovs.items.len);
    try testing.expectEqual(OverlayStyle.sheet, ovs.items[0].style);

    // a full-root, semi-transparent scrim fill is appended AFTER the base content
    var scrim_idx: ?usize = null;
    for (canvas.commands.items, 0..) |cmd, i| {
        if (cmd == .fill_rrect) {
            const f = cmd.fill_rrect;
            if (f.rect.width == 200 and f.rect.height == 200 and f.color.a > 0 and f.color.a < 0.5) scrim_idx = i;
        }
    }
    try testing.expect(scrim_idx != null);
    try testing.expect(scrim_idx.? > 0); // base glyphs were drawn first

    // dismiss region is last; tapping the scrim flips presented to false
    const last = env.hits.items[env.hits.items.len - 1];
    try testing.expect(last.action == .toggle);
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 5, .y = 5 }));
    try testing.expect(!presented.get());

    // sheet content inks over the root, and the top is dimmed by the scrim
    var fb = try raster.Framebuffer.init(testing.allocator, 200, 200);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    try testing.expect(countRed(&fb) > 100);
    try testing.expect(fb.at(100, 20).luminance() < 0.95);
}

test "view: popover content is positioned near its (top) anchor" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ovs: std.ArrayList(OverlayReq) = .empty;
    c.overlays = &ovs;
    var presented = state.State(bool).init(testing.allocator, true);
    defer presented.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const root = Rect{ .x = 0, .y = 0, .width = 300, .height = 300 };
    const pop = Rectangle(Color.blue).frame(80, 40);
    const tree = VStack(.{ Text("anchor").popover(presented.binding(), pop), Spacer() });
    try render(&c, tree, root, &canvas);
    try testing.expectEqual(@as(usize, 1), ovs.items.len);
    try testing.expectEqual(OverlayStyle.popover, ovs.items[0].style);

    var fb = try raster.Framebuffer.init(testing.allocator, 300, 300);
    defer fb.deinit();
    fb.clear(Color.white);
    try raster.render(testing.allocator, &fb, canvas.commands.items);
    // the anchor sits at the top, so the popover renders in the top half only
    var top_blue: u32 = 0;
    var bottom_blue: u32 = 0;
    var yy: u32 = 0;
    while (yy < 300) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < 300) : (xx += 1) {
            const p = fb.at(xx, yy);
            if (p.b > p.r + 0.2 and p.b > 0.4) {
                if (yy < 150) top_blue += 1 else bottom_blue += 1;
            }
        }
    }
    try testing.expect(top_blue > 100);
    try testing.expectEqual(@as(u32, 0), bottom_blue);
}

test "view: nested overlays drain once each without recursion" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ovs: std.ArrayList(OverlayReq) = .empty;
    c.overlays = &ovs;
    var outer = state.State(bool).init(testing.allocator, true);
    defer outer.deinit();
    var inner = state.State(bool).init(testing.allocator, true);
    defer inner.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // the sheet's content itself presents an alert
    const inner_content = Rectangle(Color.green).frame(60, 40);
    const sheet_content = Text("sheet").alert(inner.binding(), inner_content);
    try render(&c, Text("base").sheet(outer.binding(), sheet_content), .{ .x = 0, .y = 0, .width = 200, .height = 200 }, &canvas);

    try testing.expectEqual(@as(usize, 2), ovs.items.len);
    try testing.expectEqual(OverlayStyle.sheet, ovs.items[0].style);
    try testing.expectEqual(OverlayStyle.alert, ovs.items[1].style);
}

test "view: Menu toggles a popover of items" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ovs: std.ArrayList(OverlayReq) = .empty;
    c.overlays = &ovs;
    var open = state.State(bool).init(testing.allocator, false);
    defer open.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // closed: no overlay; tapping the button opens the menu
    try render(&c, Menu("Options", &open, .{Button("A", action(Counter.inc))}), .{ .x = 0, .y = 0, .width = 100, .height = 200 }, &canvas);
    try testing.expectEqual(@as(usize, 0), ovs.items.len);
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 50, .y = 14 }));
    try testing.expect(open.get());

    // open: a single popover overlay holds the menu items
    env.hits.clearRetainingCapacity();
    ovs.clearRetainingCapacity();
    canvas.clearCommands();
    try render(&c, Menu("Options", &open, .{Button("A", action(Counter.inc))}), .{ .x = 0, .y = 0, .width = 100, .height = 200 }, &canvas);
    try testing.expectEqual(@as(usize, 1), ovs.items.len);
    try testing.expectEqual(OverlayStyle.popover, ovs.items[0].style);
}

test "view: TabView shows the selected tab and switches on tab-bar tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, 0);
    defer sel.deinit();
    const tabs = [_]Tab{
        .{ .label = "One", .content = Rectangle(Color.red).frame(80, 40) },
        .{ .label = "Two", .content = Rectangle(Color.blue).frame(80, 40) },
    };
    // tab 0 selected -> red content shows
    var fb0 = try renderToFb(&env, &c, TabView(sel.binding(), &tabs), .{ .x = 0, .y = 0, .width = 200, .height = 100 }, 200, 100);
    defer fb0.deinit();
    try testing.expect(countRed(&fb0) > 100);
    try testing.expect(countBlue(&fb0) < 20);

    // tap the second tab-bar segment (a .select hit region targeting value 1)
    var tapped = false;
    for (env.hits.items) |hr| {
        if (hr.action == .select and hr.action.select.value == 1) {
            try testing.expect(dispatchTap(env.hits.items, hr.rect.center()));
            tapped = true;
            break;
        }
    }
    try testing.expect(tapped);
    try testing.expectEqual(@as(i64, 1), sel.get());

    // re-render -> tab 1 (blue) content now shows
    env.hits.clearRetainingCapacity();
    var fb1 = try renderToFb(&env, &c, TabView(sel.binding(), &tabs), .{ .x = 0, .y = 0, .width = 200, .height = 100 }, 200, 100);
    defer fb1.deinit();
    try testing.expect(countBlue(&fb1) > 100);
}

test "view: List wraps rows in a scroll + divider-separated stack" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const tree = List(.{ Text("a"), Text("b") });
    try testing.expect(tree.kind == .scroll);
    const inner = tree.kind.scroll.content.*;
    try testing.expect(inner.kind == .stack);
    // 2 rows + 1 divider between them
    try testing.expectEqual(@as(usize, 3), inner.kind.stack.children.len);
}
