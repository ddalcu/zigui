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
const ttf = @import("../text/ttf.zig");
const state = @import("../state/state.zig");
const icons = @import("../icons.zig");

// Component modules. The view layer is the engine + a thin facade: each module
// in `components/` owns a cohesive set of constructors (and, where relevant,
// their painting), and the public names are re-exported below.
const navigation = @import("../components/navigation.zig");
const tabs_mod = @import("../components/tabs.zig");
const menu_mod = @import("../components/menu.zig");
const grid = @import("../components/grid.zig");
const list_mod = @import("../components/list.zig");
const collections = @import("../components/collections.zig");
const text_buffer = @import("../components/text_buffer.zig");

pub const Binding = state.Binding;
/// The icon catalog enum. Call sites usually rely on enum-literal inference
/// (`Icon(.heart, …)`) and never spell this out; it's exported for the rare
/// explicit annotation. The `Icon`/`IconButton` constructors are below.
pub const IconName = icons.Icon;

const Allocator = std.mem.Allocator;
const Rect = geom.Rect;
const Point = geom.Point;
const Size = geom.Size;
const EdgeInsets = geom.EdgeInsets;
const Alignment = geom.Alignment;
const Theme = theme_mod.Theme;
const inf = std.math.inf(f32);

// --- Facade re-exports from component modules ------------------------------
// These keep the historical `view.X` public names stable while the
// implementations live in `components/`.
pub const NavState = navigation.NavState;
pub const NavigationSplitView = navigation.NavigationSplitView;
pub const NavigationSplitViewInset = navigation.NavigationSplitViewInset;
pub const NavigationLink = navigation.NavigationLink;
pub const NavBackButton = navigation.NavBackButton;
pub const Tab = tabs_mod.Tab;
pub const TabView = tabs_mod.TabView;
pub const Menu = menu_mod.Menu;
pub const ContextMenu = menu_mod.ContextMenu;
pub const LazyVGrid = grid.LazyVGrid;
pub const LazyHGrid = grid.LazyHGrid;
pub const List = list_mod.List;
pub const Sidebar = collections.Sidebar;
pub const SidebarStyled = collections.SidebarStyled;
pub const SidebarStyle = collections.SidebarStyle;
pub const SidebarItem = collections.SidebarItem;
pub const RadioGroup = collections.RadioGroup;
pub const Table = collections.Table;
pub const TableColumn = collections.TableColumn;
pub const DataTable = collections.DataTable;
pub const DataColumn = collections.DataColumn;
pub const SortColumn = collections.SortColumn;
pub const SortDir = collections.SortDir;
pub const TextFieldState = text_buffer.TextFieldState;

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

/// Closure context for `selectAction`: a (binding, value) pair bound at build
/// time and stored in the per-frame build arena, which outlives the frame until
/// the next rebuild, so a hit region's callback can safely read it.
const SelectCtx = struct { binding: Binding(i64), value: i64 };

fn selectThunk(p: ?*anyopaque) void {
    const c: *SelectCtx = @ptrCast(@alignCast(p.?));
    c.binding.set(c.value);
}

/// A `Callback` that sets `binding` to `value` — the building block for selection
/// in composed controls (sidebar rows, radio options, table rows). Lets those
/// stay pure composition over `onTap` without a dedicated `HitAction`.
pub fn selectAction(binding: Binding(i64), value: i64) Callback {
    const c = buildAlloc().create(SelectCtx) catch @panic("oom");
    c.* = .{ .binding = binding, .value = value };
    return .{ .ctx = c, .func = selectThunk };
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

    /// A blur `sigma` and an `alpha_scale` applied to the active theme's
    /// `Palette.glass` tint (so the frost is scheme-correct: light glass in light
    /// mode, dark glass in dark mode).
    pub const Spec = struct { alpha_scale: f32, sigma: f32 };

    pub fn spec(self: Material) Spec {
        return switch (self) {
            .ultra_thin => .{ .alpha_scale = 0.35, .sigma = 8 },
            .thin => .{ .alpha_scale = 0.55, .sigma = 10 },
            .regular => .{ .alpha_scale = 0.85, .sigma = 12 },
            .thick => .{ .alpha_scale = 1.0, .sigma = 14 },
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
    /// A background painted only while the cursor is within this view's frame
    /// (see `Context.hover_point`). Gives menu rows / list rows a live hover
    /// highlight without per-widget state.
    hover_fill: ?Color = null,
    /// Fired when a focused `TextField` is submitted (Enter). Stashed on the
    /// field's `TextFieldState` during paint; see `submitFocused`.
    on_submit: ?Callback = null,
    disabled: bool = false,
    /// Overlays presented from this view (sheets/alerts/popovers). A slice so a
    /// view can stack more than one — chaining `.sheet(...).alert(...)` appends
    /// rather than overwriting.
    overlay: []const OverlayMod = &.{},
    /// Overrides the auto-derived accessibility label for this view.
    a11y_label: ?[]const u8 = null,
    /// Hides this view (and its subtree) from the accessibility tree.
    a11y_hidden: bool = false,
    /// Draw the theme's freestanding Liquid Glass surface behind this view
    /// (SwiftUI's `.glassEffect()`): a capsule by default, or the view's
    /// `corner_radius` when one is set. See `Painter.glassSurface`.
    glass_effect: bool = false,
    /// Single-line text that shrinks to its proposed width and is tail-truncated
    /// with an ellipsis when it doesn't fit (SwiftUI `.lineLimit(1).truncationMode(.tail)`).
    /// Only meaningful on a `Text`. See `.truncated()`.
    truncate: bool = false,
    /// An `Image` that scales to fit its frame, preserving aspect ratio and
    /// centering (letterboxed) — instead of rendering at fixed native pixels.
    /// See `.scaledToFit()`.
    scaled_to_fit: bool = false,
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
/// The semantic appearance of a button. Defined by the theme layer (so painters
/// can switch on it) and re-exported here for view-side call sites.
pub const ButtonRole = theme_mod.Role;
pub const ButtonData = struct {
    label: []const u8,
    action: Callback,
    role: ButtonRole = .normal,
    /// Optional leading glyph (the native `Label("…", systemImage:)` button).
    icon: ?icons.Icon = null,
};

pub const ToggleData = struct { value: Binding(bool), label: []const u8 = "" };
pub const SliderData = struct { value: Binding(f32), min: f32 = 0, max: f32 = 1 };
pub const StepperData = struct { value: Binding(i64), label: []const u8 = "", min: i64 = std.math.minInt(i64), max: i64 = std.math.maxInt(i64), step: i64 = 1 };
pub const ProgressData = struct { value: f32 = 0, label: []const u8 = "" };
pub const ImageData = struct { image: canvas_mod.Image };
pub const LabelData = struct { title: []const u8, symbol_color: Color };
/// A glyph from the bundled icon font, tinted `color` (null = inherit the
/// environment's foreground) and laid out as a `size`×`size` square.
pub const IconData = struct { icon: icons.Icon, size: f32, color: ?Color = null };
/// A tappable icon: the glyph centered in a square control with a tap callback.
pub const IconButtonData = struct { icon: icons.Icon, size: f32, action: Callback };
pub const ScrollData = struct { axis: engine.Direction, offset: f32, content: *const View };

// TextFieldState + the pure UTF-8 line/column geometry and tab-aware
// metrics moved to `components/text_buffer.zig` (re-exported as
// `view.TextFieldState`). `drawEditorLine` below stays here because it
// needs the render context.

/// Draw a single editor line, rendering tabs as gaps to the next tab stop
/// (drawing text between tabs run-by-run) so caret/selection x's line up with it.
fn drawEditorLine(ctx: *const Context, canvas: *Canvas, line: []const u8, px: f32, color: Color, origin: Point) void {
    const tab_w = text_buffer.editorTabMetrics(ctx.cache.face, px).tab;
    var x: f32 = 0;
    var seg_start: usize = 0;
    for (line, 0..) |ch, i| {
        if (ch != '\t') continue;
        const seg = line[seg_start..i];
        if (seg.len > 0) {
            drawTextC(ctx, canvas, seg, px, color, .{ .x = origin.x + x, .y = origin.y }) catch {};
            x += shape.measureLineWidth(ctx.cache.face, seg, px);
        }
        x = (@floor(x / tab_w) + 1) * tab_w;
        seg_start = i + 1;
    }
    const tail = line[seg_start..];
    if (tail.len > 0) drawTextC(ctx, canvas, tail, px, color, .{ .x = origin.x + x, .y = origin.y }) catch {};
}

/// Scroll position for a `ScrollViewState`, owned by the app (like
/// `TextFieldState`) so it survives across frames and can be driven by the event
/// loop (mouse wheel) and by code (auto-follow). `content_h`/`viewport_h` are
/// written back by `paintScrollState` each frame so `maxOffset`/`atBottom` are
/// accurate; `offset` is what the view is scrolled by (vertical, in points).
pub const ScrollState = struct {
    offset: f32 = 0,
    content_h: f32 = 0,
    viewport_h: f32 = 0,
    /// Wall-clock time (ms, in the app's `setFrameTime` clock) of the most recent
    /// scroll. The overlay scrollbar shows only briefly after this, then fades out
    /// (see `paintScrollbar`). 0 means "never scrolled" → no bar.
    last_active_ms: u64 = 0,

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
/// A multi-line, scrollable text editor over a `TextFieldState` (buffer/caret/
/// selection) with vertical scroll in an app-owned `ScrollState`.
pub const TextEditorData = struct { state: *TextFieldState, scroll: *ScrollState, line_numbers: bool = true };
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
    icon: IconData,
    icon_button: IconButtonData,
    label: LabelData,
    scroll: ScrollData,
    /// A vertical scroll view whose offset lives in an app-owned `ScrollState`
    /// (so it can be wheel-driven and auto-followed), unlike `scroll`'s static
    /// offset.
    scroll_state: ScrollStateData,
    textfield: TextFieldData,
    /// A multi-line editor (see `TextEditorData`). Reuses `TextFieldState`, so it
    /// shares the focus/keyboard plumbing with `textfield`.
    text_editor: TextEditorData,
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
    /// Place the child within its frame box at the given alignment (the frame
    /// otherwise centers it). Pair with `frameWidth`/`frameMaxWidth` to leading-
    /// or trailing-align a cell's content.
    pub fn frameAlign(self: View, a: Alignment) View {
        var v = self;
        var f = v.mods.frame orelse FrameSpec{};
        f.alignment = a;
        v.mods.frame = f;
        return v;
    }
    /// Keep a `Text` on one line, shrinking it to the width it's offered and
    /// adding a trailing ellipsis when it overflows (SwiftUI `.lineLimit(1)`).
    pub fn truncated(self: View) View {
        var v = self;
        v.mods.truncate = true;
        return v;
    }
    /// Let an `Image` scale to fill the frame it's given (pair with
    /// `frameMaxWidth`/`frameMaxHeight`), preserving aspect ratio and centering —
    /// instead of rendering at fixed native pixels and overflowing.
    pub fn scaledToFit(self: View) View {
        var v = self;
        v.mods.scaled_to_fit = true;
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
    /// Draw the theme's freestanding Liquid Glass surface behind this view
    /// (SwiftUI's `.glassEffect()`): frost + sheen + rim, as a capsule by
    /// default or rounded to `.cornerRadius(r)` when one is set. Use it for
    /// toolbar pill clusters, floating bars, and inset sidebar panels.
    pub fn glassEffect(self: View) View {
        var v = self;
        v.mods.glass_effect = true;
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
    /// Paint `color` behind this view only while the cursor hovers it (honoring
    /// the view's `corner_radius`). Pair with `onTap` for menu/list rows.
    pub fn hoverFill(self: View, color: Color) View {
        var v = self;
        v.mods.hover_fill = color;
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
        // Append to any overlays already attached so `.sheet(...).alert(...)` keeps
        // both rather than the second clobbering the first.
        const old = self.mods.overlay;
        const list = buildAlloc().alloc(OverlayMod, old.len + 1) catch @panic("oom");
        @memcpy(list[0..old.len], old);
        list[old.len] = .{ .presented = presented, .content = boxed, .style = style };
        var v = self;
        v.mods.overlay = list;
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

    /// Override a stack's cross-axis alignment (default `.center`). For a
    /// `VStack` this controls horizontal alignment of its children, e.g.
    /// `.leading` to left-align them.
    pub fn alignment(self: View, a: Alignment) View {
        var v = self;
        if (v.kind == .stack) v.kind.stack.alignment = a;
        return v;
    }
};

// ---------------------------------------------------------------------------
// Build arena (per-frame) and constructors
// ---------------------------------------------------------------------------

threadlocal var current_arena: ?Allocator = null;

// --- Wrapped-text layout cache -------------------------------------------------
// Word-wrapping is recomputed on every measure AND paint of every `WrappedText`,
// so a long, mostly-static transcript re-wraps all its bubbles 60×/sec. This
// cache keys the wrap result by (content, font size, width) so settled text is a
// cheap lookup; only changing text (e.g. a streaming reply) actually re-wraps.
pub const WrapCache = struct {
    gpa: Allocator,
    map: std.AutoHashMapUnmanaged(u64, []shape.WrappedLine) = .empty,

    pub fn init(gpa: Allocator) WrapCache {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *WrapCache) void {
        self.clear();
        self.map.deinit(self.gpa);
    }
    fn clear(self: *WrapCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |v| self.gpa.free(v.*);
        self.map.clearRetainingCapacity();
    }
    fn keyFor(text: []const u8, px: f32, max_w: f32) u64 {
        var h = std.hash.Wyhash.init(0x21a17e);
        h.update(text);
        const pxq: u32 = @bitCast(px);
        const mwq: u32 = @intFromFloat(@max(0, @round(max_w)));
        h.update(std.mem.asBytes(&pxq));
        h.update(std.mem.asBytes(&mwq));
        return h.final();
    }
};

threadlocal var g_wrap_cache: ?*WrapCache = null;

/// Install the per-thread wrapped-text cache (the app's render loop owns it and
/// sets it once). Passing null disables caching (the default — headless/one-shot
/// renders just re-wrap each time).
pub fn setWrapCache(c: ?*WrapCache) void {
    g_wrap_cache = c;
}

/// Wrap `text`, returning cached line offsets when available. The returned slice
/// is valid for the current frame (cache-owned when cached, else `arena`-owned).
fn wrapCached(arena: Allocator, face: anytype, text: []const u8, px: f32, max_w: f32) []shape.WrappedLine {
    const wc = g_wrap_cache orelse
        return shape.wrapText(arena, face, text, px, max_w) catch &.{};
    const k = WrapCache.keyFor(text, px, max_w);
    if (wc.map.count() > 2048) wc.clear();
    const gop = wc.map.getOrPut(wc.gpa, k) catch
        return shape.wrapText(arena, face, text, px, max_w) catch &.{};
    if (gop.found_existing) {
        const lines = gop.value_ptr.*;
        // Guard against a (vanishingly rare) hash collision yielding offsets past
        // the current string — re-wrap rather than slice out of bounds.
        if (lines.len == 0 or lines[lines.len - 1].end <= text.len) return lines;
        wc.gpa.free(lines);
    }
    const lines = shape.wrapText(wc.gpa, face, text, px, max_w) catch {
        _ = wc.map.remove(k);
        return shape.wrapText(arena, face, text, px, max_w) catch &.{};
    };
    gop.value_ptr.* = lines;
    return lines;
}

/// The handful of theme colors that *composed* (theme-less) constructors need at
/// build time — chiefly selection tints for `Sidebar`/`Table`/`RadioGroup`.
/// Constructors have no `Context`, so the app publishes these once per frame via
/// `setThemeTokens`. The defaults match the macOS light theme, so headless tests
/// and un-wired callers render correctly without any setup.
pub const BuildTokens = struct {
    accent: Color = Color.fromRgb8(0, 122, 255),
    on_accent: Color = Color.white,
    /// Selected-content tint (AppKit's controlAccentColor — selected table
    /// rows, radio dots). Slightly muted vs `accent` on macOS.
    selection: Color = Color.fromRgb8(52, 120, 246),
    /// Neutral selected-row fill (macOS 26 sidebar selection is grey).
    quaternary_fill: Color = Color.black.withAlpha(0.12),
    /// Secondary text color, for subtitles in composed rows.
    secondary_label: Color = Color.fromRgb8(122, 122, 122),
    /// Subtle fill behind a hovered row.
    hover: Color = Color.black.withAlpha(0.06),
    /// Alternating-row stripe in tables.
    row_stripe: Color = Color.black.withAlpha(0.03),
};
threadlocal var build_tokens: BuildTokens = .{};

/// Publish the active theme's build-time tokens for composed constructors. Call
/// once per frame (the app does this in its build step) before building views.
pub fn setThemeTokens(t: Theme) void {
    build_tokens = .{
        .accent = t.colors.accent,
        .on_accent = t.colors.on_accent,
        .selection = t.colors.selection,
        .quaternary_fill = t.colors.quaternary_fill,
        .secondary_label = t.colors.secondary_label,
        .hover = t.colors.hover,
        .row_stripe = if (t.scheme == .dark) Color.white.withAlpha(0.04) else Color.black.withAlpha(0.03),
    };
}

/// Set the arena used by view constructors for the duration of building a view
/// tree. The framework calls this each frame; tests call it directly.
pub fn beginBuild(arena: Allocator) void {
    current_arena = arena;
}
pub fn endBuild() void {
    current_arena = null;
}
/// The per-frame build arena. Public so component modules in `components/` can
/// allocate the slices/children their constructors own.
pub fn buildAlloc() Allocator {
    return current_arena orelse @panic("zigui: view constructed outside beginBuild()/endBuild()");
}

/// The active build-time theme tokens, for composed (theme-less) constructors.
pub fn buildTokens() BuildTokens {
    return build_tokens;
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

/// Three dots bouncing in a phase-shifted wave — an inline "thinking…" indicator
/// (e.g. a streaming chat reply). `t_ms` is a monotonic millisecond clock (such
/// as `SDL_GetTicks`); this fn never reads a wall clock, so the caller must keep
/// redrawing (the app's busy-check does this during generation) for it to move.
pub fn LoadingDots(t_ms: u64, color: Color) View {
    const diam: f32 = 16; // dot diameter
    const amp: f32 = 10; // bounce height
    const cycle: u64 = 1000; // ms per wave
    const u = @as(f32, @floatFromInt(t_ms % cycle)) / @as(f32, @floatFromInt(cycle));
    const mk = struct {
        fn dot(uu: f32, idx: f32, c: Color) View {
            // Phase-shift each dot so they bounce in sequence; lift ∈ [0, amp].
            const ang = (uu - idx * 0.18) * std.math.tau;
            const lift = amp * 0.5 * (1.0 + @sin(ang));
            // Frame is `diam + amp` tall so the top/bottom padding (which sums to
            // `amp`) leaves a full `diam`-sized circle — padding shares the frame
            // with the shape, so a `diam`-tall frame would shrink the dot instead.
            return Circle(c)
                .frameWidth(diam)
                .frameHeight(diam + amp)
                .paddingInsets(.{ .top = amp - lift, .bottom = lift });
        }
    }.dot;
    return HStack(.{ mk(u, 0, color), mk(u, 1, color), mk(u, 2, color) }).spacing(7);
}

pub fn Button(label: []const u8, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap } } };
}
pub fn ButtonRoled(label: []const u8, role: ButtonRole, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap, .role = role } } };
}
/// A button with a leading glyph before the label — the macOS toolbar-pill
/// style (`Button { Label("Think", systemImage: …) }`). Neutral glass chrome;
/// use `ButtonIconRoled` for a tinted role.
pub fn ButtonIcon(label: []const u8, icon: icons.Icon, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap, .icon = icon } } };
}
pub fn ButtonIconRoled(label: []const u8, icon: icons.Icon, role: ButtonRole, on_tap: Callback) View {
    return .{ .kind = .{ .button = .{ .label = label, .action = on_tap, .role = role, .icon = icon } } };
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
/// A glyph from the bundled icon set, laid out as a `size`×`size` square and
/// tinted `color` (pass `null` to inherit the surrounding `.foreground`). Call
/// sites lean on enum-literal inference: `Icon(.heart, 18, null)`.
pub fn Icon(icon: icons.Icon, size: f32, color: ?Color) View {
    return .{ .kind = .{ .icon = .{ .icon = icon, .size = size, .color = color } } };
}
/// A tappable icon (toolbar/affordance style): the glyph centered in a square
/// control with a tap callback. The icon inherits the environment foreground;
/// compose `.foreground`/`.padding`/`.background` for styling.
pub fn IconButton(icon: icons.Icon, size: f32, on_tap: Callback) View {
    return .{ .kind = .{ .icon_button = .{ .icon = icon, .size = size, .action = on_tap } } };
}
/// A title with a small leading symbol swatch (placeholder for an icon set).
pub fn Label(title: []const u8, symbol_color: Color) View {
    return .{ .kind = .{ .label = .{ .title = title, .symbol_color = symbol_color } } };
}
pub fn TextField(placeholder: []const u8, fieldState: *TextFieldState) View {
    return .{ .kind = .{ .textfield = .{ .state = fieldState, .placeholder = placeholder } } };
}
/// A multi-line, scrollable plain-text editor (like SwiftUI's `TextEditor`). It
/// fills the space it is given. `editor_state` holds the buffer/caret/selection
/// (app-owned, like a `TextField`); `scroll_state` holds the vertical scroll so
/// the wheel can drive it and the caret can be followed. Pass `line_numbers` to
/// show a gutter. The event loop routes editing keys to whichever field is
/// focused, so no extra wiring is needed beyond owning the two states.
pub fn TextEditor(editor_state: *TextFieldState, scroll_state: *ScrollState, line_numbers: bool) View {
    return .{ .kind = .{ .text_editor = .{ .state = editor_state, .scroll = scroll_state, .line_numbers = line_numbers } } };
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

// List, LazyVGrid/LazyHGrid, TabView, Sidebar/RadioGroup/Table moved to
// `components/{list,grid,tabs,collections}.zig` (re-exported via the facade).

pub fn VStack(children: anytype) View {
    return makeStack(.vertical, 8, .center, children);
}
pub fn HStack(children: anytype) View {
    return makeStack(.horizontal, 8, .center, children);
}
pub fn ZStack(children: anytype) View {
    return makeStack(.depth, 0, .center, children);
}

pub fn makeStack(direction: engine.Direction, spc: f32, alignment: Alignment, children: anytype) View {
    return makeStackFromSlice(direction, spc, alignment, toViews(children));
}

/// Build a stack `View` from an already-allocated slice of children. Public so
/// composite components in `components/` can assemble rows/columns.
pub fn makeStackFromSlice(direction: engine.Direction, spc: f32, alignment: Alignment, views: []const View) View {
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

/// Normalize a tuple literal or `[]const View` into an owned `[]View` in the
/// build arena. Public for composite components that accept variadic children.
pub fn toViews(children: anytype) []View {
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

/// Splice any `.group` children (from `ForEach`) into a flat child list.
/// Public so composite containers (e.g. `List`) can flatten before laying out.
pub fn flattenGroups(views: []const View) []const View {
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
    /// Focus a `TextEditor` and place the caret at the clicked point. Carries the
    /// font metrics and the text-area origin/scroll so the byte index can be
    /// resolved in `performAction` (which has only the tap point, no `Context`).
    /// The same payload also drives mouse drag-selection (see `dispatchDrag`).
    text_click: TextClick,
    /// Select a specific value (e.g. a picker segment).
    select: struct { binding: Binding(i64), value: i64 },
};

/// Geometry captured for a `TextEditor`'s clickable text area, enough to map a
/// pixel point to a caret byte index (`caretIndexAt`) without a `Context`.
pub const TextClick = struct {
    state: *TextFieldState,
    face: *const ttf.Font,
    px: f32,
    origin: Point,
    scroll_y: f32,
    line_height: f32,
};

/// Map a pixel point to a caret byte index within a `TextEditor`, clamping to
/// the document (a point above/below/left maps to the nearest edge).
fn caretIndexAt(tc: TextClick, p: Point) usize {
    const txt = tc.state.text();
    const total = text_buffer.countLines(txt);
    const rel_y = p.y - tc.origin.y + tc.scroll_y;
    var li: usize = if (rel_y <= 0) 0 else @intFromFloat(rel_y / tc.line_height);
    if (li >= total) li = total - 1;
    const r = text_buffer.nthLineRange(txt, li);
    return r.start + text_buffer.caretInLine(tc.face, tc.px, txt[r.start..r.end], p.x - tc.origin.x);
}

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
    /// The cursor's current location in layout points, or null when the pointer
    /// is outside the window. Drives `Modifiers.hover_fill`. The app updates it
    /// on mouse-motion (and the main loop already redraws per event, so hover
    /// highlights track the cursor for free).
    hover_point: ?Point = null,
    /// Glyph cache for the bundled icon font (`Font.icons()`). When null, `Icon`
    /// and `IconButton` paint nothing — wire it (app + tests) to draw icons.
    icon_cache: ?*atlas.GlyphCache = null,

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

    /// Build a `theme.Surface` for the painter to draw chrome into — bundling
    /// the canvas with the active palette/metrics/scheme and the inherited
    /// opacity. The palette/metrics are borrowed from `self.theme`, valid for
    /// the duration of the painter call.
    pub fn surface(self: *const Context, canvas: *Canvas) theme_mod.Surface {
        return .{
            .canvas = canvas,
            .palette = &self.theme.colors,
            .metrics = &self.theme.metrics,
            .scheme = self.theme.scheme,
            .opacity = self.opacity,
        };
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

const control_h_padding: f32 = 11;
// Switch/slider/stepper geometry sampled from native macOS 26 controls.
const switch_w: f32 = 36;
const switch_h: f32 = 16;
const slider_h: f32 = 20;
const slider_knob_r: f32 = 8;
const slider_track_h: f32 = 5;
const progress_h: f32 = 7;
/// The native stepper is a single chevron column (up over down), not +/- boxes.
const stepper_w: f32 = 22;
const stepper_box_h: f32 = 24;
const label_icon: f32 = 14;
const label_gap: f32 = 6;
/// Padding around the glyph in an `IconButton` (wider than tall, like the
/// native glass icon-button capsule), enlarging its tap target.
const icon_button_pad_x: f32 = 9;
const icon_button_pad_y: f32 = 4;

/// Leading-glyph size and gap inside an icon-label button.
const button_icon_size: f32 = 14;
const button_icon_gap: f32 = 5;

fn buttonSize(ctx: *const Context, b: ButtonData) Size {
    const px = ctx.theme.typography.body.size;
    const lw = shape.measureLineWidth(ctx.cache.face, b.label, px);
    const lh = shape.lineHeight(ctx.cache.face, px);
    const iw: f32 = if (b.icon != null) button_icon_size + button_icon_gap else 0;
    return .{
        .width = iw + lw + 2 * control_h_padding,
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
        const lines = wrapCached(self.arena, self.face, self.string, self.px, max_w);
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
            const tw = shape.measureLineWidth(ctx.cache.face, t.string, px);
            const lh = shape.lineHeight(ctx.cache.face, px);
            // A truncating Text may shrink below its natural width (down to an
            // ellipsis) so the layout can fit it to a narrow cell; it's painted
            // tail-truncated. A normal Text is rigid at its measured width.
            if (v.mods.truncate) {
                const ell = shape.measureLineWidth(ctx.cache.face, "…", px);
                return .{ .leaf = .{
                    .min = .{ .width = @min(ell, tw), .height = lh },
                    .ideal = .{ .width = tw, .height = lh },
                    .max = .{ .width = tw, .height = lh },
                } };
            }
            return .{ .leaf = engine.SizingHints.fixedSize(.{ .width = tw, .height = lh }) };
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
        .image => |im| {
            const iw: f32 = @floatFromInt(im.image.width);
            const ih: f32 = @floatFromInt(im.image.height);
            // A scaled-to-fit image may shrink to 0 or grow to fill whatever frame
            // it's offered (it's drawn aspect-fit). A plain image is rigid at its
            // native pixel size.
            if (v.mods.scaled_to_fit) {
                return .{ .leaf = .{
                    .min = .{},
                    .ideal = .{ .width = iw, .height = ih },
                    .max = .{ .width = inf, .height = inf },
                } };
            }
            return .{ .leaf = engine.SizingHints.fixedSize(.{ .width = iw, .height = ih }) };
        },
        .icon => |ic| return .{ .leaf = engine.SizingHints.fixedSize(.{ .width = ic.size, .height = ic.size }) },
        .icon_button => |ib| {
            return .{ .leaf = engine.SizingHints.fixedSize(.{
                .width = ib.size + 2 * icon_button_pad_x,
                .height = ib.size + 2 * icon_button_pad_y,
            }) };
        },
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
        // The editor fills the space it is offered (the gutter/scroll live inside).
        .text_editor => return .{ .leaf = .{
            .min = .{ .width = 120, .height = 60 },
            .ideal = .{ .width = 360, .height = 220 },
            .max = .{ .width = inf, .height = inf },
        } },
        .picker => |pk| {
            const px = ctx.theme.typography.body.size;
            var w: f32 = 0;
            // Per-segment horizontal padding (each side gets half) so labels have
            // breathing room and don't crowd the segment dividers.
            for (pk.options) |opt| w += shape.measureLineWidth(ctx.cache.face, opt, px) + 40;
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
    // The text-field context menu sits above everything, including app overlays.
    try drawContextMenu(ctx, rect, canvas);
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
    // 1. Dimming scrim over the whole frame (theme-tinted; native macOS dims
    //    by ~20% black under modals). Popovers are light-dismiss but do NOT
    //    dim the window behind them.
    if (req.style != .popover) {
        try canvas.fillRect(root, ctx.theme.colors.scrim);
    }
    // 2. Tap-to-dismiss region beneath the content (appended before content's
    //    own regions, so a tap on the content hits the content first).
    if (req.dismiss) |d| {
        try ctx.hit_regions.append(ctx.arena, .{ .rect = root, .action = .{ .toggle = d }, .disabled = false });
    }

    // 3. Measure & position the content. macOS sheets are *centered* window
    //    modals (they don't hug the bottom edge like iOS).
    const prop: engine.Proposal = switch (req.style) {
        .sheet => .{ .width = @min(root.width - 160, 480), .height = null },
        .alert => .{ .width = @min(root.width - 80, 320), .height = null },
        .popover => .unspecified,
    };
    const size = measure(ctx, req.content, prop) catch Size{};
    const target = switch (req.style) {
        .sheet, .alert => centerRect(root, size),
        .popover => anchoredRect(root, req.anchor, size),
    };

    // 4. Panel frame (theme-drawn), then the content on top, clipped to the
    //    panel so rigid children (e.g. an unwrappable Text) can't paint past
    //    the rounded edge. Modals round more than popovers and use a different
    //    material (opaque vs frosted) on macOS.
    const kind: theme_mod.PanelKind = switch (req.style) {
        .sheet, .alert => .modal,
        .popover => .popover,
    };
    const radius = switch (kind) {
        .modal => ctx.theme.metrics.panel_corner_radius,
        .popover => ctx.theme.metrics.corner_radius,
    };
    try ctx.theme.painter.panel(ctx.surface(canvas), target, radius, kind);
    try canvas.pushClip(target, radius);
    try renderInto(ctx, req.content, target, canvas);
    try canvas.popClip();
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

    // Liquid Glass surface (behind any background fill): a capsule unless the
    // view set an explicit corner radius. Themes without a glass identity fall
    // back to a translucent track fill with a hairline ring.
    if (v.mods.glass_effect) {
        const gr = if (v.mods.corner_radius > 0) v.mods.corner_radius else outer.height / 2;
        const s = child_ctx.surface(canvas);
        if (child_ctx.theme.painter.glassSurface) |gs| {
            try gs(s, outer, gr);
        } else {
            try s.fill(outer, gr, child_ctx.theme.colors.control_track);
            try s.stroke(outer, gr, child_ctx.theme.metrics.hairline, child_ctx.theme.colors.control_border);
        }
    }

    // Background fill (behind content, spanning the padded frame).
    if (v.mods.background) |fill| try paintFill(canvas, outer, v.mods.corner_radius, fill, op, &child_ctx.theme.colors);

    // Hover highlight: painted over the background while the cursor is inside
    // this view (and it isn't disabled). Cheap point-in-rect test per frame.
    if (v.mods.hover_fill) |hc| {
        if (!child_ctx.disabled) {
            if (ctx.hover_point) |hp| {
                if (outer.contains(hp))
                    try paintFill(canvas, outer, v.mods.corner_radius, .{ .color = hc }, op, &child_ctx.theme.colors);
            }
        }
    }

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
    // pass in `render`, anchored to this view's frame. A view can carry several
    // (e.g. both `.sheet` and `.alert`); each is enqueued when its binding is on.
    if (ctx.overlays) |overlays| {
        for (v.mods.overlay) |ov| {
            if (ov.presented.get()) {
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
            const str = if (v.mods.truncate) truncateToWidth(ctx, t.string, px, rect.width) else t.string;
            drawTextC(ctx, canvas, str, px, ctx.foreground.multiplyAlpha(op), rect.origin()) catch {};
            // Accessibility always exposes the full, untruncated string.
            try emitA11y(ctx, v, rect, .static_text, t.string, "");
        },
        .wrapped_text => |wt| {
            paintWrappedText(ctx, v, wt, rect, canvas) catch {};
            try emitA11y(ctx, v, rect, .static_text, wt.string, "");
        },
        .shape => |sh| try paintShape(ctx, sh, rect, op, canvas),
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
            const r = if (v.mods.scaled_to_fit) aspectFitRect(rect, im.image.width, im.image.height) else rect;
            try canvas.drawImage(r, im.image);
            try emitA11y(ctx, v, rect, .image, "", "");
        },
        .icon => |ic| {
            try paintIcon(ctx, ic, rect, canvas);
            try emitA11y(ctx, v, rect, .image, "", "");
        },
        .icon_button => |ib| {
            try paintIconButton(ctx, ib, rect, canvas);
            try emitA11y(ctx, v, rect, .button, "", "");
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
        .text_editor => |ed| {
            try paintTextEditor(ctx, v, ed, rect, canvas);
            const val = ctx.arena.dupe(u8, ed.state.text()) catch "";
            try emitA11y(ctx, v, rect, .text_field, "", val);
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

fn paintFill(canvas: *Canvas, rect: Rect, radius: f32, fill: Fill, op: f32, palette: *const theme_mod.Palette) !void {
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
            // The frost tint comes from the active theme's (scheme-correct) glass
            // role, scaled per material level.
            const tint = palette.glass.multiplyAlpha(s.alpha_scale);
            try canvas.blurRect(rect, radius, s.sigma, tint.multiplyAlpha(op));
        },
    }
}

fn paintShape(ctx: *const Context, sh: ShapeData, rect: Rect, op: f32, canvas: *Canvas) !void {
    const palette = &ctx.theme.colors;
    switch (sh.shape) {
        .rect => try paintFill(canvas, rect, 0, sh.fill, op, palette),
        .rounded_rect => try paintFill(canvas, rect, sh.corner_radius, sh.fill, op, palette),
        .capsule => try paintFill(canvas, rect, @min(rect.width, rect.height) / 2, sh.fill, op, palette),
        .ellipse => try paintFill(canvas, rect, @min(rect.width, rect.height) / 2, sh.fill, op, palette),
        .circle => {
            const r = @min(rect.width, rect.height) / 2;
            const sq = Rect{ .x = rect.midX() - r, .y = rect.midY() - r, .width = 2 * r, .height = 2 * r };
            try paintFill(canvas, sq, r, sh.fill, op, palette);
        },
    }
}

fn paintButton(ctx: *const Context, b: ButtonData, rect: Rect, canvas: *Canvas) !void {
    const dim: f32 = if (ctx.disabled) 0.4 else 1.0;
    // The theme's painter draws the button chrome and tells us the label color.
    const hovered = if (ctx.hover_point) |hp| rect.contains(hp) else false;
    const surface = ctx.surface(canvas);
    var label_color: Color = undefined;
    if (b.icon != null and b.role == .normal and ctx.theme.painter.glassSurface != null) {
        // Icon-label buttons are the macOS *toolbar pill* style: a freestanding
        // glass capsule rather than the gently-rounded in-content button.
        try ctx.theme.painter.glassSurface.?(surface, rect, rect.height / 2);
        if (hovered and !ctx.disabled) {
            try surface.fill(rect, rect.height / 2, ctx.theme.colors.hover);
        }
        label_color = if (ctx.disabled) ctx.theme.colors.tertiary_label else ctx.theme.colors.label;
    } else {
        label_color = try ctx.theme.painter.button(surface, rect, b.role, .{
            .disabled = ctx.disabled,
            .hovered = hovered and !ctx.disabled,
        });
    }
    const px = ctx.theme.typography.body.size;
    const lw = shape.measureLineWidth(ctx.cache.face, b.label, px);
    const lh = shape.lineHeight(ctx.cache.face, px);
    const color = label_color.multiplyAlpha(ctx.opacity * dim);
    const iw: f32 = if (b.icon != null) button_icon_size + button_icon_gap else 0;
    const start_x = rect.x + (rect.width - (iw + lw)) / 2;
    if (b.icon) |ic| {
        if (ctx.icon_cache) |cache| {
            const ibox = Rect{
                .x = start_x,
                .y = vcenter(rect, button_icon_size),
                .width = button_icon_size,
                .height = button_icon_size,
            };
            font_mod.drawIcon(canvas, cache, ic.codepoint(), ibox, ctx.scale, color) catch {};
        }
    }
    const origin = Point{
        .x = start_x + iw,
        .y = rect.y + (rect.height - lh) / 2,
    };
    drawTextC(ctx, canvas, b.label, px, color, origin) catch {};
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

/// Tail-truncate `str` to fit `max_w` at font size `px`, appending an ellipsis
/// (returns `str` unchanged when it already fits). The clipped string is built in
/// the per-frame arena. Used for `.truncated()` single-line Text.
fn truncateToWidth(ctx: *const Context, str: []const u8, px: f32, max_w: f32) []const u8 {
    if (shape.measureLineWidth(ctx.cache.face, str, px) <= max_w) return str;
    const ell = "…";
    const ell_w = shape.measureLineWidth(ctx.cache.face, ell, px);
    if (max_w <= ell_w) return ell; // no room even for the body — just the ellipsis
    const budget = max_w - ell_w;
    // Longest UTF-8 prefix (whole codepoints) whose width fits the budget.
    var fit: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        const next = @min(i + cp_len, str.len);
        if (shape.measureLineWidth(ctx.cache.face, str[0..next], px) > budget) break;
        fit = next;
        i = next;
    }
    return std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ str[0..fit], ell }) catch ell;
}

/// The largest centered sub-rect of `rect` with the image's aspect ratio
/// (SwiftUI `.scaledToFit()` / `object-fit: contain`).
fn aspectFitRect(rect: Rect, iw: u32, ih: u32) Rect {
    const fw: f32 = @floatFromInt(iw);
    const fh: f32 = @floatFromInt(ih);
    if (fw <= 0 or fh <= 0 or rect.width <= 0 or rect.height <= 0) return rect;
    const scale = @min(rect.width / fw, rect.height / fh);
    const w = fw * scale;
    const h = fh * scale;
    return .{
        .x = rect.x + (rect.width - w) / 2,
        .y = rect.y + (rect.height - h) / 2,
        .width = w,
        .height = h,
    };
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
    // The view layer owns the knob *geometry*; the theme draws both the track
    // and the sliding thumb so the whole control matches the family.
    const s = ctx.surface(canvas);
    try ctx.theme.painter.switchTrack(s, sw, on);
    const knob_r = switch_h / 2 - 1.5;
    const knob_cx = if (on) sw.maxX() - knob_r - 1.5 else sw.x + knob_r + 1.5;
    const knob_rect = Rect{ .x = knob_cx - knob_r, .y = sw.midY() - knob_r, .width = 2 * knob_r, .height = 2 * knob_r };
    try ctx.theme.painter.switchKnob(s, knob_rect, on);
    try ctx.hit_regions.append(ctx.arena, .{ .rect = rect, .action = .{ .toggle = t.value }, .disabled = ctx.disabled });
}

fn paintSlider(ctx: *const Context, s: SliderData, rect: Rect, canvas: *Canvas) !void {
    const r = slider_knob_r;
    const track = Rect{ .x = rect.x + r, .y = rect.midY() - slider_track_h / 2, .width = rect.width - 2 * r, .height = slider_track_h };
    const denom = if (s.max - s.min == 0) 1 else s.max - s.min;
    const frac = std.math.clamp((s.value.get() - s.min) / denom, 0, 1);
    // The view layer owns the geometry (track + knob square); the theme draws
    // the groove, fill, and handle in its own style.
    const knob_cx = track.x + track.width * frac;
    const knob_rect = Rect{ .x = knob_cx - r, .y = rect.midY() - r, .width = 2 * r, .height = 2 * r };
    const hovered = if (ctx.hover_point) |hp| rect.contains(hp) else false;
    try ctx.theme.painter.slider(ctx.surface(canvas), track, frac, knob_rect, .{
        .disabled = ctx.disabled,
        .hovered = hovered and !ctx.disabled,
    });
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
    // The native macOS stepper: one small chevron column — up increments,
    // down decrements, split by an inset horizontal divider.
    const ctrl = Rect{
        .x = rect.maxX() - stepper_w,
        .y = vcenter(rect, stepper_box_h),
        .width = stepper_w,
        .height = stepper_box_h,
    };
    const hovered = if (ctx.hover_point) |hp| ctrl.contains(hp) else false;
    // The theme draws the box chrome; the divider and chevrons stay here.
    try ctx.theme.painter.stepperBox(ctx.surface(canvas), ctrl, .{
        .disabled = ctx.disabled,
        .hovered = hovered and !ctx.disabled,
    });
    const half = ctrl.height / 2;
    const up = Rect{ .x = ctrl.x, .y = ctrl.y, .width = ctrl.width, .height = half };
    const down = Rect{ .x = ctrl.x, .y = ctrl.y + half, .width = ctrl.width, .height = half };
    try canvas.line(.{ .x = ctrl.x + 4, .y = ctrl.midY() }, .{ .x = ctrl.maxX() - 4, .y = ctrl.midY() }, m.hairline, ctx.theme.colors.separator.multiplyAlpha(op));
    const mc = ctx.foreground.multiplyAlpha(op);
    const cw: f32 = 3.5; // chevron half-width
    try canvas.line(.{ .x = up.midX() - cw, .y = up.midY() + 1.5 }, .{ .x = up.midX(), .y = up.midY() - 2 }, 1.5, mc);
    try canvas.line(.{ .x = up.midX(), .y = up.midY() - 2 }, .{ .x = up.midX() + cw, .y = up.midY() + 1.5 }, 1.5, mc);
    try canvas.line(.{ .x = down.midX() - cw, .y = down.midY() - 1.5 }, .{ .x = down.midX(), .y = down.midY() + 2 }, 1.5, mc);
    try canvas.line(.{ .x = down.midX(), .y = down.midY() + 2 }, .{ .x = down.midX() + cw, .y = down.midY() - 1.5 }, 1.5, mc);
    try ctx.hit_regions.append(ctx.arena, .{ .rect = up, .action = .{ .step = .{ .binding = s.value, .delta = s.step, .min = s.min, .max = s.max } }, .disabled = ctx.disabled });
    try ctx.hit_regions.append(ctx.arena, .{ .rect = down, .action = .{ .step = .{ .binding = s.value, .delta = -s.step, .min = s.min, .max = s.max } }, .disabled = ctx.disabled });
}

fn paintProgress(ctx: *const Context, pr: ProgressData, rect: Rect, canvas: *Canvas) !void {
    const bar = Rect{ .x = rect.x, .y = rect.midY() - progress_h / 2, .width = rect.width, .height = progress_h };
    try ctx.theme.painter.progress(ctx.surface(canvas), bar, pr.value);
}

fn paintLabel(ctx: *const Context, l: LabelData, v: View, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const px = resolvedFontSize(ctx, v);
    const icon = Rect{ .x = rect.x, .y = vcenter(rect, label_icon), .width = label_icon, .height = label_icon };
    try canvas.fillRoundedRect(icon, 3, l.symbol_color.multiplyAlpha(op));
    const lh = shape.lineHeight(ctx.cache.face, px);
    drawTextC(ctx, canvas, l.title, px, ctx.foreground.multiplyAlpha(op), .{ .x = rect.x + label_icon + label_gap, .y = vcenter(rect, lh) }) catch {};
}

fn paintIcon(ctx: *const Context, ic: IconData, rect: Rect, canvas: *Canvas) !void {
    const cache = ctx.icon_cache orelse return; // no icon font wired -> draw nothing
    const color = (ic.color orelse ctx.foreground).multiplyAlpha(ctx.opacity);
    // The glyph is centered in its laid-out square (`rect`); `drawIcon` sizes it
    // to the smaller side and handles the HiDPI coverage trick.
    font_mod.drawIcon(canvas, cache, ic.icon.codepoint(), rect, ctx.scale, color) catch {};
}

fn paintIconButton(ctx: *const Context, ib: IconButtonData, rect: Rect, canvas: *Canvas) !void {
    // Icon buttons get the same neutral chrome as ordinary buttons (native
    // glass icon buttons are small capsules), with the glyph as the label.
    const hovered = if (ctx.hover_point) |hp| rect.contains(hp) else false;
    const label_color = try ctx.theme.painter.button(ctx.surface(canvas), rect, .normal, .{
        .disabled = ctx.disabled,
        .hovered = hovered and !ctx.disabled,
    });
    const dim: f32 = if (ctx.disabled) 0.4 else 1;
    const color = label_color.multiplyAlpha(ctx.opacity * dim);
    const box = rect.insetBy(icon_button_pad_x, icon_button_pad_y);
    font_mod.drawIcon(canvas, ctx.icon_cache orelse return, ib.icon.codepoint(), box, ctx.scale, color) catch {};
    try ctx.hit_regions.append(ctx.arena, .{ .rect = rect, .action = .{ .callback = ib.action }, .disabled = ctx.disabled });
}

/// Paint wrapped text: re-wrap to the laid-out rect width and draw each line,
/// stacked by line height, top-aligned within `rect`.
fn paintWrappedText(ctx: *const Context, v: View, wt: WrappedTextData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const px = resolvedFontSize(ctx, v);
    const lh = shape.lineHeight(ctx.cache.face, px);
    const color = ctx.foreground.multiplyAlpha(op);
    const lines = wrapCached(ctx.arena, ctx.cache.face, wt.string, px, rect.width);
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
    const focused = tf.state.focused;
    // Keep the focused field's submit callback current so `submitFocused` (fired
    // from the event loop on Enter) can reach it without the view tree.
    if (focused) tf.state.on_submit = v.mods.on_submit;
    // The theme draws the input surface (background + border).
    try ctx.theme.painter.field(ctx.surface(canvas), rect, radius, .{ .focused = focused });

    const px = ctx.theme.typography.body.size;
    const lh = shape.lineHeight(ctx.cache.face, px);
    // Inset text past the corner curve (more for pills).
    const pad: f32 = @max(8, @min(radius, 14));
    const ty = vcenter(rect, lh);
    const content = tf.state.text();

    // Selection highlight, drawn behind the text so the glyphs stay readable.
    if (focused) {
        if (tf.state.selectionRange()) |s| {
            const hx0 = rect.x + pad + shape.measureLineWidth(ctx.cache.face, content[0..s.start], px);
            const hx1 = rect.x + pad + shape.measureLineWidth(ctx.cache.face, content[0..s.end], px);
            try canvas.fillRect(.{ .x = hx0, .y = ty, .width = @max(1, hx1 - hx0), .height = lh }, ctx.theme.colors.selection.multiplyAlpha(op));
        }
    }

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
    // A `text_click` region (not a bare `.focus`) so a single-line field also
    // supports click-to-place-caret, drag-selection, and double-click word
    // selection — its one line starts at the text origin with no scroll.
    try ctx.hit_regions.append(ctx.arena, .{
        .rect = rect,
        .action = .{ .text_click = .{
            .state = tf.state,
            .face = ctx.cache.face,
            .px = px,
            .origin = .{ .x = rect.x + pad, .y = ty },
            .scroll_y = 0,
            .line_height = lh,
        } },
        .disabled = ctx.disabled,
    });
}

/// Width of the line-number gutter: enough for `nlines`' digits plus padding.
fn gutterWidth(face: *const ttf.Font, px: f32, nlines: usize, pad: f32) f32 {
    var digits: usize = 1;
    var n = nlines;
    while (n >= 10) : (n = n / 10) digits += 1;
    const zeros = "0000000000000000000"; // up to 19 digits
    const s = zeros[0..@min(digits, zeros.len)];
    return shape.measureLineWidth(face, s, px) + 2 * pad;
}

/// Paint a multi-line editor: rounded background + focus border, a line-number
/// gutter, selection highlight, the visible lines (vertically scrolled by the
/// `ScrollState`), and the caret. Auto-scrolls to keep the caret visible only
/// when it moved (so the wheel can scroll freely otherwise), registers a
/// `ScrollRegion` for the wheel, and a `text_click` hit region for click-to-
/// position-caret.
fn paintTextEditor(ctx: *const Context, v: View, ed: TextEditorData, rect: Rect, canvas: *Canvas) Allocator.Error!void {
    const st = ed.state;
    st.multiline = true;
    const op = ctx.opacity;
    const m = ctx.theme.metrics;
    const px = resolvedFontSize(ctx, v);
    const face = ctx.cache.face;
    const lh = shape.lineHeight(face, px);
    const focused = st.focused;

    const radius = if (v.mods.corner_radius > 0) v.mods.corner_radius else m.control_corner_radius;
    // The theme draws the editor surface (background + border).
    try ctx.theme.painter.field(ctx.surface(canvas), rect, radius, .{ .focused = focused });

    const text = st.text();
    const nlines = text_buffer.countLines(text);

    const pad: f32 = 8;
    const gutter_w: f32 = if (ed.line_numbers) gutterWidth(face, px, nlines, pad) else pad;
    const text_x = rect.x + gutter_w + pad;
    const top = rect.y + pad;
    const view_h = @max(0, rect.height - 2 * pad);

    // Scroll geometry, then auto-follow the caret only when it actually moved.
    ed.scroll.content_h = @as(f32, @floatFromInt(nlines)) * lh;
    ed.scroll.viewport_h = view_h;
    const caret_line = text_buffer.lineIndexOf(text, st.caret);
    if (st.caret != st.last_caret) {
        const cy = @as(f32, @floatFromInt(caret_line)) * lh;
        if (cy < ed.scroll.offset) {
            ed.scroll.offset = cy;
        } else if (cy + lh > ed.scroll.offset + view_h) {
            ed.scroll.offset = cy + lh - view_h;
        }
        st.last_caret = st.caret;
    }
    ed.scroll.offset = std.math.clamp(ed.scroll.offset, 0, ed.scroll.maxOffset());
    const off = ed.scroll.offset;

    const fg = ctx.foreground.multiplyAlpha(op);
    const num_c = ctx.theme.colors.tertiary_label.multiplyAlpha(op);
    const sel_c = ctx.theme.colors.selection.multiplyAlpha(op);
    const sel = st.selectionRange();
    const space_w = shape.measureLineWidth(face, " ", px);

    // Clip to the interior (inside the border/corners) while drawing content.
    try canvas.pushClip(rect.insetBy(2, 2), 0);

    if (ed.line_numbers) {
        const gx = rect.x + gutter_w;
        try canvas.line(.{ .x = gx, .y = rect.y }, .{ .x = gx, .y = rect.y + rect.height }, m.hairline, ctx.theme.colors.separator.multiplyAlpha(op));
    }

    var line_no: usize = 0;
    var pos: usize = 0;
    while (line_no < nlines) : (line_no += 1) {
        const lstart = pos;
        const lend = text_buffer.lineEndIndex(text, lstart);
        pos = lend + 1; // advance past the '\n' (or one past the end for the last line)
        const y = top - off + @as(f32, @floatFromInt(line_no)) * lh;
        if (y + lh < top or y > top + view_h) continue; // fully offscreen

        // Selection highlight: the part of [sel.start, sel.end] inside this line.
        if (sel) |s| {
            if (s.start <= lend and s.end >= lstart) {
                const a = @max(s.start, lstart);
                const b = @min(s.end, lend);
                const hx0 = text_x + text_buffer.editorPrefixWidth(face, px, text[lstart..a]);
                var hx1 = text_x + text_buffer.editorPrefixWidth(face, px, text[lstart..b]);
                if (s.end > lend) hx1 += space_w; // a selected line-break reads as a trailing sliver
                try canvas.fillRect(.{ .x = hx0, .y = y, .width = @max(1, hx1 - hx0), .height = lh }, sel_c);
            }
        }

        if (ed.line_numbers) {
            var buf: [20]u8 = undefined;
            const numstr = std.fmt.bufPrint(&buf, "{d}", .{line_no + 1}) catch "";
            const nw = shape.measureLineWidth(face, numstr, px);
            drawTextC(ctx, canvas, numstr, px, num_c, .{ .x = rect.x + gutter_w - pad - nw, .y = y }) catch {};
        }

        if (lend > lstart) drawEditorLine(ctx, canvas, text[lstart..lend], px, fg, .{ .x = text_x, .y = y });

        if (focused and line_no == caret_line) {
            const cx = text_x + text_buffer.editorPrefixWidth(face, px, text[lstart..st.caret]);
            try canvas.line(.{ .x = cx, .y = y + 1 }, .{ .x = cx, .y = y + lh - 1 }, 1, ctx.theme.colors.accent.multiplyAlpha(op));
        }
    }

    canvas.popClip() catch {};

    try ctx.hit_regions.append(ctx.arena, .{
        .rect = rect,
        .action = .{ .text_click = .{
            .state = st,
            .face = face,
            .px = px,
            .origin = .{ .x = text_x, .y = top },
            .scroll_y = off,
            .line_height = lh,
        } },
        .disabled = ctx.disabled,
    });
    if (ctx.scroll_regions) |regs| try regs.append(ctx.arena, .{ .rect = rect, .state = ed.scroll });
}

fn paintPicker(ctx: *const Context, pk: PickerData, rect: Rect, canvas: *Canvas) !void {
    const op = ctx.opacity;
    const n = pk.options.len;
    if (n == 0) return;
    const s = ctx.surface(canvas);
    // The theme draws the segmented track and the selected-segment chip.
    try ctx.theme.painter.segmentedTrack(s, rect);
    const seg_w = rect.width / @as(f32, @floatFromInt(n));
    const px = ctx.theme.typography.body.size;
    const lh = shape.lineHeight(ctx.cache.face, px);
    const selected = pk.selection.get();
    for (pk.options, 0..) |opt, i| {
        const seg = Rect{ .x = rect.x + @as(f32, @floatFromInt(i)) * seg_w, .y = rect.y, .width = seg_w, .height = rect.height };
        const is_sel = @as(i64, @intCast(i)) == selected;
        // The theme draws the selection chip and dictates its label color (an
        // accent-filled chip needs `on_accent` text, a pale chip keeps `label`).
        // Native unselected segment labels stay in the primary label color.
        const seg_text = if (is_sel)
            try ctx.theme.painter.segmentedSelection(s, seg)
        else
            ctx.theme.colors.label;
        const tw = shape.measureLineWidth(ctx.cache.face, opt, px);
        drawTextC(ctx, canvas, opt, px, seg_text.multiplyAlpha(op), .{
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
    try paintScrollbar(ctx, sd.state, rect, canvas);
}

/// Draw a slim, rounded scroll indicator on the right edge of `rect` when the
/// content overflows. The thumb's length and position track the visible
/// fraction, like a native overlay scrollbar. No-op when everything fits.
fn paintScrollbar(ctx: *const Context, ss: *const ScrollState, rect: Rect, canvas: *Canvas) Allocator.Error!void {
    const max = ss.maxOffset();
    if (max <= 0.5 or rect.height <= 0) return; // fits → nothing to show

    // Auto-hide: only visible briefly after the last scroll, then fade out.
    if (ss.last_active_ms == 0 or g_frame_time_ms == 0) return; // never scrolled / headless
    const since = g_frame_time_ms -| ss.last_active_ms;
    if (since >= scrollbar_visible_ms) return; // fully hidden
    const fade: f32 = if (since <= scrollbar_hold_ms)
        1
    else
        1 - @as(f32, @floatFromInt(since - scrollbar_hold_ms)) / @as(f32, @floatFromInt(scrollbar_fade_ms));

    const track_inset: f32 = 2;
    const width: f32 = 4;
    const track_h = rect.height - track_inset * 2;
    if (track_h <= 0) return;

    const visible_frac = std.math.clamp(rect.height / ss.content_h, 0.06, 1);
    const thumb_h = @max(24, track_h * visible_frac);
    const scroll_frac = std.math.clamp(ss.offset / max, 0, 1);
    const thumb_y = rect.y + track_inset + (track_h - thumb_h) * scroll_frac;
    const thumb_x = rect.x + rect.width - width - track_inset;

    const thumb = Rect{ .x = thumb_x, .y = thumb_y, .width = width, .height = thumb_h };
    // A muted thumb that reads on both light and dark surfaces.
    const col = ctx.theme.colors.secondary_label.withAlpha(0.45 * ctx.opacity * fade);
    try canvas.fillRoundedRect(thumb, width / 2, col);
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

/// The `TextEditor` currently being drag-selected (set on mouse-down over its
/// text, cleared on mouse-up). Identity only — the live geometry is re-read from
/// the current frame's hit regions on each motion event (so scrolling mid-drag
/// stays correct). Managed by the app/event loop.
threadlocal var g_drag: ?*TextFieldState = null;
/// The `Binding.ctx` of a slider being dragged (mouse held after a knob/track
/// press). Identifies the slider's hit region across rebuilds, the way `g_drag`
/// uses the `*TextFieldState` pointer for a text drag.
threadlocal var g_slider_drag: ?*anyopaque = null;

/// End an in-progress mouse drag-selection (the app calls this on mouse-up).
pub fn endDrag() void {
    g_drag = null;
    g_slider_drag = null;
}

/// Continue a drag started by a mouse-down on a `TextEditor` (extend the
/// caret) or a `Slider` (set its value from `p.x`). The dragged control's hit
/// region is re-emitted every frame, so this re-reads the current geometry.
/// No-op when no drag is active.
pub fn dispatchDrag(regions: []const HitRegion, p: Point) void {
    if (g_drag == null and g_slider_drag == null) return;
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.disabled) continue;
        switch (r.action) {
            .text_click => |tc| if (tc.state == g_drag) {
                tc.state.caret = caretIndexAt(tc, p);
                tc.state.pref_col = null;
                return;
            },
            .slider => |s| if (s.binding.ctx == g_slider_drag) {
                s.binding.set(sliderValueForX(s.track, s.min, s.max, p.x));
                return;
            },
            else => {},
        }
    }
}

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

/// Handle a double-click at `p`: if the top-most region under it is an editable
/// text field, select the word there and return true. Otherwise returns false so
/// the caller can fall back to a normal tap.
pub fn dispatchDoubleClick(regions: []const HitRegion, p: Point) bool {
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.disabled or !r.rect.contains(p)) continue;
        switch (r.action) {
            .text_click => |tc| {
                setFocus(tc.state);
                tc.state.selectWordAt(caretIndexAt(tc, p));
                g_drag = null; // a double-click selects a word; it does not arm a drag
                return true;
            },
            else => return false, // a non-text control is on top — let the caller tap it
        }
    }
    return false;
}

/// Handle a triple-click at `p`: if the top-most region under it is an editable
/// text field, select all of its text and return true. Otherwise returns false.
pub fn dispatchTripleClick(regions: []const HitRegion, p: Point) bool {
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.disabled or !r.rect.contains(p)) continue;
        switch (r.action) {
            .text_click => |tc| {
                setFocus(tc.state);
                tc.state.selectAll();
                g_drag = null;
                return true;
            },
            else => return false,
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
            // Surface the overlay scrollbar and keep the loop awake long enough
            // for it to fade back out (see scrollbarsAnimating / paintScrollbar).
            r.state.last_active_ms = g_frame_time_ms;
            g_scrollbar_until_ms = g_frame_time_ms + scrollbar_visible_ms;
            return true;
        }
    }
    return false;
}

// --- Auto-hiding overlay scrollbars -----------------------------------------
// The bar appears on scroll, holds for `scrollbar_hold_ms`, then fades over
// `scrollbar_fade_ms` and disappears. `scrollbar_visible_ms` is the full window.

const scrollbar_hold_ms: u64 = 1600;
const scrollbar_fade_ms: u64 = 400;
const scrollbar_visible_ms: u64 = scrollbar_hold_ms + scrollbar_fade_ms;

/// Wall-clock time (ms) of the current frame, set by the app via `setFrameTime`.
/// 0 in headless/tests, which keeps scrollbars hidden there.
var g_frame_time_ms: u64 = 0;
/// Time (ms) until which at least one scrollbar is still visible or fading.
var g_scrollbar_until_ms: u64 = 0;

/// The app calls this once per frame with its millisecond clock so scrollbars
/// can time their auto-hide.
pub fn setFrameTime(ms: u64) void {
    g_frame_time_ms = ms;
}

/// True while a recently-scrolled viewport's overlay scrollbar is still on
/// screen (or fading). The app's loop wakes at ~60fps while this holds so the
/// bar fades out instead of freezing on screen.
pub fn scrollbarsAnimating(now_ms: u64) bool {
    return now_ms < g_scrollbar_until_ms;
}

fn performAction(a: HitAction, p: Point) void {
    switch (a) {
        .callback => |cb| cb.call(),
        .toggle => |b| b.set(!b.get()),
        .slider => |s| {
            s.binding.set(sliderValueForX(s.track, s.min, s.max, p.x));
            g_slider_drag = s.binding.ctx; // arm a drag so mouse-move tracks the knob
        },
        .step => |s| {
            const next = std.math.clamp(s.binding.get() + s.delta, s.min, s.max);
            s.binding.set(next);
        },
        .focus => |fs| setFocus(fs),
        .text_click => |tc| {
            setFocus(tc.state);
            const idx = caretIndexAt(tc, p);
            tc.state.caret = idx;
            tc.state.last_caret = idx;
            // Anchor the selection here: a pure click leaves anchor == caret (no
            // selection); a drag (see dispatchDrag) then extends from this point.
            tc.state.sel_anchor = idx;
            tc.state.pref_col = null;
            g_drag = tc.state;
        },
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

// ---------------------------------------------------------------------------
// Text-field context menu (right-click → Cut / Copy / Paste / Select All).
// Drawn by zigui (not a native OS menu) as a top-level popup in `render`, so it
// works for every app and reuses the existing hit-region/dispatch machinery.
// Cut/Copy/Paste need the clipboard, which lives in the SDL layer (`app.zig`);
// the app registers function pointers via `setClipboardOps` so this core code
// stays platform-free.
// ---------------------------------------------------------------------------

/// Clipboard operations the app injects so the context menu can copy/paste.
pub const ClipboardOps = struct {
    /// Put the field's current selection on the system clipboard.
    copy: *const fn (*TextFieldState) void,
    /// Insert the clipboard's text at the field's caret (replacing any selection).
    paste: *const fn (*TextFieldState) void,
};
var g_clipboard: ?ClipboardOps = null;
pub fn setClipboardOps(ops: ClipboardOps) void {
    g_clipboard = ops;
}

const TextMenuState = struct { field: *TextFieldState, pos: Point, hover: ?MenuAction = null };
threadlocal var g_ctxmenu: ?TextMenuState = null;

pub fn contextMenuOpen() bool {
    return g_ctxmenu != null;
}
pub fn closeContextMenu() void {
    g_ctxmenu = null;
}

/// The top-most editable field whose hit region contains `p`, or null. The app's
/// right-click handler calls this to decide whether to pop the text menu.
pub fn fieldAt(regions: []const HitRegion, p: Point) ?*TextFieldState {
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.disabled or !r.rect.contains(p)) continue;
        switch (r.action) {
            .focus => |fs| return fs, // single-line TextField
            .text_click => |tc| return tc.state, // multi-line TextEditor
            else => {},
        }
    }
    return null;
}

/// Open the text context menu for `field` at layout point `p`. Focuses the field
/// so the menu's actions (and a follow-up paste) target it.
pub fn openContextMenu(field: *TextFieldState, p: Point) void {
    setFocus(field);
    g_ctxmenu = .{ .field = field, .pos = p };
}

/// Update which menu item the cursor is over (for the hover highlight). The app
/// calls this on mouse motion while the menu is open; `regions` are the current
/// frame's hit regions (which include the menu's item rows). A no-op if closed.
pub fn hoverContextMenu(regions: []const HitRegion, p: Point) void {
    if (g_ctxmenu == null) return;
    var found: ?MenuAction = null;
    var i = regions.len;
    while (i > 0) {
        i -= 1;
        const r = regions[i];
        if (r.disabled or !r.rect.contains(p)) continue;
        // The first (top-most) region under the cursor decides: a menu item row
        // sets the hover; anything else (e.g. the dismiss region) clears it.
        switch (r.action) {
            .callback => |cb| if (cb.func == &menuPerform) {
                const it: *MenuItem = @ptrCast(@alignCast(cb.ctx.?));
                found = it.action;
            },
            else => {},
        }
        break;
    }
    if (g_ctxmenu) |*cm| cm.hover = found;
}

fn eqAction(h: ?MenuAction, a: MenuAction) bool {
    return if (h) |x| x == a else false;
}

const MenuAction = enum { cut, copy, paste, select_all };
const MenuItem = struct { field: *TextFieldState, action: MenuAction };

fn menuPerform(p: ?*anyopaque) void {
    const it: *MenuItem = @ptrCast(@alignCast(p.?));
    const f = it.field;
    switch (it.action) {
        .cut => {
            if (g_clipboard) |ops| ops.copy(f);
            _ = f.deleteSelection();
        },
        .copy => if (g_clipboard) |ops| ops.copy(f),
        .paste => if (g_clipboard) |ops| ops.paste(f),
        .select_all => f.selectAll(),
    }
    closeContextMenu();
}

fn menuDismiss(_: ?*anyopaque) void {
    closeContextMenu();
}

fn menuRow(ctx: *const Context, field: *TextFieldState, label: []const u8, shortcut: []const u8, act: MenuAction, enabled: bool, hovered: bool) View {
    // A hovered (always enabled) row paints an accent highlight with inverted text;
    // disabled rows stay dimmed and un-highlighted.
    const label_fg = if (hovered) ctx.theme.colors.on_accent else if (enabled) ctx.theme.colors.label else ctx.theme.colors.tertiary_label;
    const short_fg = if (hovered) ctx.theme.colors.on_accent else ctx.theme.colors.tertiary_label;
    var row = HStack(.{
        Text(label).foreground(label_fg),
        Spacer(),
        Text(shortcut).font(.caption).foreground(short_fg),
    }).spacing(20).paddingInsets(.{ .top = 5, .leading = 10, .bottom = 5, .trailing = 10 }).frameMaxWidth();
    if (hovered) row = row.background(ctx.theme.colors.accent).cornerRadius(5);
    if (enabled) {
        const cx = ctx.arena.create(MenuItem) catch return row;
        cx.* = .{ .field = field, .action = act };
        row = row.onTap(.{ .ctx = cx, .func = menuPerform });
    }
    return row;
}

fn buildContextMenu(ctx: *const Context, field: *TextFieldState) View {
    const has_sel = field.hasSelection();
    const hov: ?MenuAction = if (g_ctxmenu) |cm| cm.hover else null;
    const rows = ctx.arena.alloc(View, 5) catch return Text("");
    rows[0] = menuRow(ctx, field, "Cut", "⌘X", .cut, has_sel, eqAction(hov, .cut));
    rows[1] = menuRow(ctx, field, "Copy", "⌘C", .copy, has_sel, eqAction(hov, .copy));
    rows[2] = menuRow(ctx, field, "Paste", "⌘V", .paste, true, eqAction(hov, .paste));
    rows[3] = Divider();
    rows[4] = menuRow(ctx, field, "Select All", "⌘A", .select_all, field.text().len > 0, eqAction(hov, .select_all));
    return VStack(rows).spacing(2).paddingInsets(.{ .top = 5, .leading = 6, .bottom = 5, .trailing = 6 }).frameMaxWidth();
}

/// Draw the open context menu (if any) as a top-level popup: a full-frame
/// dismiss region, then a positioned panel of items. Called by `render` after
/// the app's overlays so it sits on top and wins tap dispatch.
fn drawContextMenu(ctx: *const Context, root: Rect, canvas: *Canvas) Allocator.Error!void {
    const cm = g_ctxmenu orelse return;
    // Dismiss region beneath the menu: a tap anywhere not on an item closes it.
    // Appended before the items (added by renderInto below), so back-to-front
    // dispatch gives the items priority.
    try ctx.hit_regions.append(ctx.arena, .{ .rect = root, .action = .{ .callback = .{ .func = menuDismiss } }, .disabled = false });

    // The framework calls `render` after `endBuild`, so the build arena is closed.
    // Re-open it (saving/restoring) just long enough to construct the menu's views.
    const saved_arena = current_arena;
    current_arena = ctx.arena;
    defer current_arena = saved_arena;

    const menu = buildContextMenu(ctx, cm.field);
    const menu_w: f32 = 210;
    const size = measure(ctx, menu, .{ .width = menu_w, .height = null }) catch return;
    var x = cm.pos.x;
    if (x + size.width > root.maxX()) x = root.maxX() - size.width;
    if (x < root.x) x = root.x;
    var y = cm.pos.y;
    if (y + size.height > root.maxY()) y = root.maxY() - size.height;
    if (y < root.y) y = root.y;
    const target = Rect{ .x = x, .y = y, .width = size.width, .height = size.height };

    const radius = ctx.theme.metrics.corner_radius;
    try ctx.theme.painter.panel(ctx.surface(canvas), target, radius, .popover);
    try renderInto(ctx, menu, target, canvas);
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
    icon_font: font_mod.Font,
    cache: atlas.GlyphCache,
    icon_cache: atlas.GlyphCache,
    hits: std.ArrayList(HitRegion),
    arena_state: std.heap.ArenaAllocator,

    fn init() TestEnv {
        return .{
            .font = font_mod.Font.default(),
            .icon_font = font_mod.Font.icons(),
            .cache = undefined,
            .icon_cache = undefined,
            .hits = .empty,
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }
    fn setup(self: *TestEnv) void {
        self.cache = atlas.GlyphCache.init(testing.allocator, &self.font.face);
        self.icon_cache = atlas.GlyphCache.init(testing.allocator, &self.icon_font.face);
        beginBuild(self.arena_state.allocator());
    }
    fn ctx(self: *TestEnv) Context {
        var c = Context.init(@import("../theme/macos.zig").light, &self.cache, self.arena_state.allocator(), &self.hits);
        c.icon_cache = &self.icon_cache;
        return c;
    }
    fn deinit(self: *TestEnv) void {
        endBuild();
        self.cache.deinit();
        self.icon_cache.deinit();
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

test "view: Slider follows mouse drag after press" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var s = state.State(f32).init(testing.allocator, 0);
    defer s.deinit();
    var fb = try renderToFb(&env, &c, Slider(s.binding(), 0, 1), .{ .x = 0, .y = 0, .width = 100, .height = 20 }, 100, 20);
    defer fb.deinit();

    // Press near the left arms a drag.
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 5, .y = 10 }));
    try testing.expect(s.get() < 0.2);
    // Dragging the mouse right (button held) tracks the knob.
    dispatchDrag(env.hits.items, .{ .x = 95, .y = 10 });
    try testing.expect(s.get() > 0.8);
    // Dragging past the right edge clamps to max, not beyond.
    dispatchDrag(env.hits.items, .{ .x = 500, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.get(), 0.001);
    // After release, a stray move no longer changes the value.
    endDrag();
    dispatchDrag(env.hits.items, .{ .x = 5, .y = 10 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.get(), 0.001);
}

test "view: Icon paints a glyph from the bundled set" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var fb = try renderToFb(&env, &c, Icon(.heart, 24, Color.red), .{ .x = 0, .y = 0, .width = 24, .height = 24 }, 24, 24);
    defer fb.deinit();
    // Some red pixels were inked somewhere in the box.
    var inked: usize = 0;
    var y: u32 = 0;
    while (y < 24) : (y += 1) {
        var x: u32 = 0;
        while (x < 24) : (x += 1) {
            if (fb.at(x, y).r > 0.3) inked += 1;
        }
    }
    try testing.expect(inked > 0);
}

test "view: ButtonIcon reserves space for its leading glyph" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const plain = try measure(&c, Button("Think", action(Counter.inc)), .unspecified);
    const iconed = try measure(&c, ButtonIcon("Think", .sparkles, action(Counter.inc)), .unspecified);
    try testing.expectEqual(plain.height, iconed.height);
    try testing.expectEqual(plain.width + button_icon_size + button_icon_gap, iconed.width);
}

test "view: glassEffect draws the theme's glass surface behind content" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    // The macOS painter's glass surface starts with a backdrop frost.
    try render(&c, Empty().frame(80, 28).glassEffect(), .{ .x = 0, .y = 0, .width = 80, .height = 28 }, &canvas);
    var saw_blur = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .blur_rect) saw_blur = true;
    }
    try testing.expect(saw_blur);
}

test "view: SidebarStyled prominent selection is the accent row" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, 0);
    defer sel.deinit();
    const items = [_]SidebarItem{
        .{ .label = "New Chat", .detail = "just now" },
        .{ .label = "Older", .detail = "4h ago" },
    };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, SidebarStyled(&items, sel.binding(), .prominent), .{ .x = 0, .y = 0, .width = 220, .height = 200 }, &canvas);
    var has_accent_row = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .fill_rrect and cmd.fill_rrect.color.approxEql(c.theme.colors.selection, 0.05)) has_accent_row = true;
    }
    try testing.expect(has_accent_row);
}

test "view: IconButton fires its callback on tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const Ctr = struct {
        var hits: u32 = 0;
        fn tap(_: ?*anyopaque) void {
            hits += 1;
        }
    };
    Ctr.hits = 0;
    const cb = Callback{ .func = Ctr.tap };
    var fb = try renderToFb(&env, &c, IconButton(.trash, 20, cb), .{ .x = 0, .y = 0, .width = 32, .height = 32 }, 32, 32);
    defer fb.deinit();
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 16, .y = 16 }));
    try testing.expectEqual(@as(u32, 1), Ctr.hits);
}

test "view: Icon paints nothing when no icon cache is wired" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    c.icon_cache = null; // simulate an app that didn't wire the icon font
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, Icon(.heart, 24, Color.red), .{ .x = 0, .y = 0, .width = 24, .height = 24 }, &canvas);
    // No glyph command emitted for the icon.
    for (canvas.commands.items) |cmd| try testing.expect(cmd != .glyph);
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
    // the chevron column hugs the trailing edge: up = top half increments
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 110, .y = 6 }));
    try testing.expectEqual(@as(i64, 6), s.get());
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 110, .y = 6 })); // clamp at max
    try testing.expectEqual(@as(i64, 6), s.get());
    // down = bottom half decrements
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 110, .y = 22 }));
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
    tf.moveLeft(false);
    tf.moveLeft(false);
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

test "TextFieldState: selection editing (insert/backspace replace, selectAll)" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.setText("hello world");
    // Select "world" by anchoring at 6 and moving to the end.
    tf.caret = 6;
    tf.sel_anchor = 6;
    tf.end(true);
    const r = tf.selectionRange().?;
    try testing.expectEqual(@as(usize, 6), r.start);
    try testing.expectEqual(@as(usize, 11), r.end);
    // Typing replaces the selection.
    try tf.insert("there");
    try testing.expectEqualStrings("hello there", tf.text());
    try testing.expect(!tf.hasSelection());
    // Select-all then backspace clears everything.
    tf.selectAll();
    tf.backspace();
    try testing.expectEqual(@as(usize, 0), tf.text().len);
}

test "TextFieldState: a plain move collapses the selection to an edge" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.setText("abcdef");
    tf.caret = 1;
    tf.sel_anchor = 4; // selection [1,4)
    tf.moveLeft(false); // collapse to the left edge
    try testing.expectEqual(@as(usize, 1), tf.caret);
    try testing.expect(!tf.hasSelection());
    tf.caret = 1;
    tf.sel_anchor = 4;
    tf.moveRight(false); // collapse to the right edge
    try testing.expectEqual(@as(usize, 4), tf.caret);
    try testing.expect(!tf.hasSelection());
}

test "TextFieldState: multi-line up/down keeps the preferred column" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.setText("hello\nhi\nworld"); // lines: 0:"hello" 1:"hi" 2:"world"
    // Put the caret at column 4 of the first line ("hell|o").
    tf.caret = 4;
    tf.moveDown(false); // line 1 "hi" is shorter -> clamp to its end (col 2, byte 8)
    try testing.expectEqual(@as(usize, 8), tf.caret);
    tf.moveDown(false); // line 2 "world" -> preferred column 4 restored ("worl|d", byte 9+4)
    try testing.expectEqual(@as(usize, 13), tf.caret);
    // Home/End and 1-based line/col.
    tf.home(false);
    try testing.expectEqual(@as(usize, 9), tf.caret);
    const lc = tf.lineCol();
    try testing.expectEqual(@as(usize, 3), lc.line);
    try testing.expectEqual(@as(usize, 1), lc.col);
    tf.end(false);
    try testing.expectEqual(@as(usize, 14), tf.caret);
}

test "TextFieldState: forward delete and revision tracking" {
    var tf = TextFieldState.init(testing.allocator);
    defer tf.deinit();
    try tf.setText("abc");
    const r0 = tf.revision;
    tf.caret = 1;
    tf.deleteForward(); // removes 'b'
    try testing.expectEqualStrings("ac", tf.text());
    try testing.expectEqual(@as(usize, 1), tf.caret);
    try testing.expect(tf.revision != r0); // a mutation bumped the revision
    tf.caret = tf.buffer.items.len;
    tf.deleteForward(); // at end -> no-op
    try testing.expectEqualStrings("ac", tf.text());
}

test "view: editorPrefixWidth snaps tabs to tab stops" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const face = &env.font.face;
    const px: f32 = 14;
    const tab_w = text_buffer.editorTabMetrics(face, px).tab;
    // A leading tab advances exactly one tab stop.
    try testing.expectApproxEqAbs(tab_w, text_buffer.editorPrefixWidth(face, px, "\t"), 0.01);
    // Text then a tab snaps forward to the *next* stop (never less than the text).
    const w_ab = shape.measureLineWidth(face, "ab", px);
    const after = text_buffer.editorPrefixWidth(face, px, "ab\t");
    try testing.expect(after > w_ab);
    try testing.expectApproxEqAbs(@as(f32, 0), @mod(after, tab_w), 0.01);
}

test "view: TextEditor paints line numbers and places the caret on click" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ed = TextFieldState.init(testing.allocator);
    defer ed.deinit();
    var sc = ScrollState{};
    try ed.setText("alpha\nbeta\ngamma");
    ed.caret = 0;
    ed.last_caret = 0;

    var fb = try renderToFb(&env, &c, TextEditor(&ed, &sc, true), .{ .x = 0, .y = 0, .width = 300, .height = 200 }, 300, 200);
    defer fb.deinit();
    // The editor registers one hit region (the whole rect) carrying a text_click.
    try testing.expectEqual(@as(usize, 1), env.hits.items.len);
    try testing.expect(env.hits.items[0].action == .text_click);

    // Click on the second visible line -> caret lands on line 1 ("beta").
    const lh = shape.lineHeight(&env.font.face, c.theme.typography.body.size);
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 200, .y = 8 + lh + 2 }));
    try testing.expect(ed.focused);
    try testing.expectEqual(@as(usize, 1), text_buffer.lineIndexOf(ed.text(), ed.caret));
}

test "view: TextEditor mouse drag selects a range" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ed = TextFieldState.init(testing.allocator);
    defer ed.deinit();
    var sc = ScrollState{};
    try ed.setText("alpha\nbeta\ngamma");

    var fb = try renderToFb(&env, &c, TextEditor(&ed, &sc, true), .{ .x = 0, .y = 0, .width = 300, .height = 200 }, 300, 200);
    defer fb.deinit();
    const lh = shape.lineHeight(&env.font.face, c.theme.typography.body.size);

    // Press near the start of line 0 ("alpha"), then drag to the end of line 1.
    try testing.expect(dispatchTap(env.hits.items, .{ .x = 2, .y = 8 + 2 }));
    try testing.expect(!ed.hasSelection()); // a press alone is just a caret
    dispatchDrag(env.hits.items, .{ .x = 250, .y = 8 + lh + 2 });
    const r = ed.selectionRange().?;
    try testing.expectEqual(@as(usize, 0), r.start);
    try testing.expectEqual(@as(usize, 10), r.end); // through the end of "beta"
    endDrag();
    // After the drag ends, a further "motion" must not change the selection.
    dispatchDrag(env.hits.items, .{ .x = 10, .y = 8 + 2 });
    try testing.expectEqual(@as(usize, 10), ed.selectionRange().?.end);
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

test "view: RadioGroup selects an option on tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, 0);
    defer sel.deinit();
    const opts = [_][]const u8{ "One", "Two", "Three" };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, RadioGroup(sel.binding(), &opts), .{ .x = 0, .y = 0, .width = 200, .height = 120 }, &canvas);
    try testing.expectEqual(@as(usize, 3), env.hits.items.len); // one tap target per option
    // tapping the second row sets the binding to index 1
    try testing.expect(dispatchTap(env.hits.items, env.hits.items[1].rect.center()));
    try testing.expectEqual(@as(i64, 1), sel.get());
}

test "view: Sidebar selects a row on tap and highlights the selection" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, 0);
    defer sel.deinit();
    const items = [_]SidebarItem{
        .{ .label = "Inbox", .icon = .mail },
        .{ .label = "Sent" },
        .{ .label = "Drafts" },
    };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, Sidebar(&items, sel.binding()), .{ .x = 0, .y = 0, .width = 220, .height = 300 }, &canvas);
    try testing.expectEqual(@as(usize, 3), env.hits.items.len);
    // the selected (row 0) draws the neutral selection wash behind it
    var has_selection = false;
    for (canvas.commands.items) |cmd| {
        if (cmd == .fill_rrect and cmd.fill_rrect.color.approxEql(c.theme.colors.quaternary_fill, 0.05)) has_selection = true;
    }
    try testing.expect(has_selection);
    // tapping the third row selects it
    try testing.expect(dispatchTap(env.hits.items, env.hits.items[2].rect.center()));
    try testing.expectEqual(@as(i64, 2), sel.get());
}

test "view: Table shows a header + rows and selects a row on tap" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sel = state.State(i64).init(testing.allocator, -1);
    defer sel.deinit();
    const cols = [_]TableColumn{ .{ .title = "Name" }, .{ .title = "Age", .width = 60 } };
    const rows = [_][]const []const u8{
        &.{ "Ada", "36" },
        &.{ "Alan", "41" },
        &.{ "Grace", "45" },
    };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, Table(&cols, &rows, sel.binding()), .{ .x = 0, .y = 0, .width = 300, .height = 200 }, &canvas);
    // selection enabled -> one callback tap target per data row (header has none)
    var row_hits: usize = 0;
    var second: ?Rect = null;
    for (env.hits.items) |hr| {
        if (hr.action == .callback) {
            if (row_hits == 1) second = hr.rect;
            row_hits += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), row_hits);
    try testing.expect(dispatchTap(env.hits.items, second.?.center()));
    try testing.expectEqual(@as(i64, 1), sel.get());
}

test "view: DataTable sortable header toggles the sort binding" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var sort = state.State(SortColumn).init(testing.allocator, .{});
    defer sort.deinit();
    const cols = [_]DataColumn{
        .{ .title = "Name" }, // not sortable -> no tap target
        .{ .title = "Size", .width = 80, .sortable = true, .trailing = true },
    };
    const rows = [_][]const View{
        &.{ Text("Ada"), Text("6 GB") },
        &.{ Text("Alan"), Text("9 GB") },
    };
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, DataTable(&cols, &rows, sort.binding(), null), .{ .x = 0, .y = 0, .width = 300, .height = 200 }, &canvas);

    // Only the one sortable header registers a tap target.
    var header_hit: ?Rect = null;
    var count: usize = 0;
    for (env.hits.items) |hr| {
        if (hr.action == .callback) {
            header_hit = hr.rect;
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);

    // First tap on a fresh column sorts by it, descending.
    try testing.expect(dispatchTap(env.hits.items, header_hit.?.center()));
    try testing.expectEqual(@as(i64, 1), sort.get().index);
    try testing.expectEqual(SortDir.descending, sort.get().dir);

    // Tapping the same column again toggles to ascending.
    try testing.expect(dispatchTap(env.hits.items, header_hit.?.center()));
    try testing.expectEqual(SortDir.ascending, sort.get().dir);
}

test "view: truncateToWidth shortens overflowing text with an ellipsis" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    const long = "Qwen3.6-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-NEO-CODE";
    const px: f32 = 13;
    const full = shape.measureLineWidth(c.cache.face, long, px);

    // Ample room → returned unchanged.
    try testing.expectEqualStrings(long, truncateToWidth(&c, long, px, full + 10));

    // Constrained → shortened, ends with the ellipsis, and fits the budget.
    const out = truncateToWidth(&c, long, px, full / 2);
    try testing.expect(out.len < long.len);
    try testing.expect(std.mem.endsWith(u8, out, "…"));
    try testing.expect(shape.measureLineWidth(c.cache.face, out, px) <= full / 2);
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

test "view: chaining .sheet and .alert keeps both overlays (neither clobbers)" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();
    var ovs: std.ArrayList(OverlayReq) = .empty;
    c.overlays = &ovs;
    var sheet_on = state.State(bool).init(testing.allocator, true);
    defer sheet_on.deinit();
    var alert_on = state.State(bool).init(testing.allocator, false);
    defer alert_on.deinit();

    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    const root = Rect{ .x = 0, .y = 0, .width = 200, .height = 200 };
    const base = Text("Base")
        .sheet(sheet_on.binding(), Rectangle(Color.red).frame(80, 40))
        .alert(alert_on.binding(), Rectangle(Color.blue).frame(80, 40));

    // Only the sheet is presented → exactly one overlay, and it's the sheet.
    try render(&c, base, root, &canvas);
    try testing.expectEqual(@as(usize, 1), ovs.items.len);
    try testing.expectEqual(OverlayStyle.sheet, ovs.items[0].style);

    // Turn the alert on too → both present (the .alert did not overwrite .sheet).
    ovs.clearRetainingCapacity();
    env.hits.clearRetainingCapacity();
    canvas.clearCommands();
    alert_on.set(true);
    try render(&c, base, root, &canvas);
    try testing.expectEqual(@as(usize, 2), ovs.items.len);
    try testing.expectEqual(OverlayStyle.sheet, ovs.items[0].style);
    try testing.expectEqual(OverlayStyle.alert, ovs.items[1].style);
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

test "view: double-click selects the word; TextField exposes text_click" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();

    var field = TextFieldState.init(testing.allocator);
    defer field.deinit();
    try field.setText("foo barbaz qux");

    // selectWordAt expands to the word boundaries around an index.
    field.selectWordAt(5); // inside "barbaz"
    const r = field.selectionRange().?;
    try testing.expectEqualStrings("barbaz", field.text()[r.start..r.end]);

    // A run of whitespace selects together (not a word).
    field.selectWordAt(3); // the space after "foo"
    const rs = field.selectionRange().?;
    try testing.expectEqualStrings(" ", field.text()[rs.start..rs.end]);

    // The single-line field now registers a `text_click`, so a double-click
    // dispatch near the left edge selects the first word.
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, TextField("ph", &field), .{ .x = 0, .y = 0, .width = 200, .height = 40 }, &canvas);
    try testing.expectEqual(@as(usize, 1), env.hits.items.len);
    try testing.expect(env.hits.items[0].action == .text_click);
    try testing.expect(dispatchDoubleClick(env.hits.items, .{ .x = 12, .y = 20 }));
    const r2 = field.selectionRange().?;
    try testing.expectEqualStrings("foo", field.text()[r2.start..r2.end]);

    // Triple-click selects the whole field.
    try testing.expect(dispatchTripleClick(env.hits.items, .{ .x = 12, .y = 20 }));
    const r3 = field.selectionRange().?;
    try testing.expectEqual(@as(usize, 0), r3.start);
    try testing.expectEqual(field.text().len, r3.end);
}

test "view: TextField selection highlight is visible" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();

    var field = TextFieldState.init(testing.allocator);
    defer field.deinit();
    try field.setText("hello");
    setFocus(&field);
    defer clearFocus();

    const rect = Rect{ .x = 0, .y = 0, .width = 140, .height = 36 };

    // The focus border is also blue, so diff a no-selection render against a
    // fully-selected one — the difference is the highlight block.
    field.sel_anchor = null; // just a caret
    var fb0 = try renderToFb(&env, &c, TextField("ph", &field), rect, 140, 36);
    defer fb0.deinit();
    const before = countBlue(&fb0);

    env.hits.clearRetainingCapacity();
    field.selectAll();
    var fb1 = try renderToFb(&env, &c, TextField("ph", &field), rect, 140, 36);
    defer fb1.deinit();
    const after = countBlue(&fb1);

    try testing.expect(after > before + 50); // the selection adds a solid blue block
}

test "view: text context menu — fieldAt, render, actions, clipboard hook" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    var c = env.ctx();

    var field = TextFieldState.init(testing.allocator);
    defer field.deinit();
    try field.setText("hello world");

    // Record clipboard calls routed through the injected ops.
    const Rec = struct {
        var copied: bool = false;
        var pasted: bool = false;
        fn copy(f: *TextFieldState) void {
            _ = f;
            copied = true;
        }
        fn paste(f: *TextFieldState) void {
            _ = f;
            pasted = true;
        }
    };
    Rec.copied = false;
    Rec.pasted = false;
    setClipboardOps(.{ .copy = Rec.copy, .paste = Rec.paste });
    defer g_clipboard = null;
    defer closeContextMenu(); // never leak menu state into later tests, even on failure

    // fieldAt finds the single-line TextField under a point (it registers a
    // `text_click` region).
    var canvas = Canvas.init(testing.allocator);
    defer canvas.deinit();
    try render(&c, TextField("ph", &field), .{ .x = 0, .y = 0, .width = 400, .height = 300 }, &canvas);
    try testing.expect(fieldAt(env.hits.items, .{ .x = 20, .y = 15 }) == &field);

    // Open the menu and re-render. Crucially, build the arg view, then `endBuild`
    // BEFORE render — exactly as the framework does — so this guards the bug where
    // the menu's own views were constructed after the build arena had closed.
    env.hits.clearRetainingCapacity();
    field.selectAll(); // a selection enables Cut/Copy so they register hit regions
    openContextMenu(&field, .{ .x = 10, .y = 10 });
    try testing.expect(contextMenuOpen());
    const menu_arg = TextField("ph", &field);
    endBuild();
    defer beginBuild(env.arena_state.allocator()); // restore for env.deinit()'s endBuild()
    try render(&c, menu_arg, .{ .x = 0, .y = 0, .width = 400, .height = 300 }, &canvas);
    try testing.expect(env.hits.items.len >= 4); // field + dismiss + enabled items

    // Hover: pointing at the Copy item's region sets the menu's hovered action.
    var copy_rect: ?Rect = null;
    for (env.hits.items) |r| switch (r.action) {
        .callback => |cb| if (cb.func == &menuPerform) {
            const it: *MenuItem = @ptrCast(@alignCast(cb.ctx.?));
            if (it.action == .copy) copy_rect = r.rect;
        },
        else => {},
    };
    try testing.expect(copy_rect != null);
    hoverContextMenu(env.hits.items, .{ .x = copy_rect.?.x + 5, .y = copy_rect.?.y + 5 });
    try testing.expect(eqAction(g_ctxmenu.?.hover, .copy));
    // Pointing at empty space (the dismiss region) clears the hover.
    hoverContextMenu(env.hits.items, .{ .x = 380, .y = 280 });
    try testing.expect(g_ctxmenu.?.hover == null);

    // Copy fires the hook (no mutation) and closes the menu.
    var copy_item = MenuItem{ .field = &field, .action = .copy };
    menuPerform(&copy_item);
    try testing.expect(Rec.copied);
    try testing.expect(!contextMenuOpen());
    try testing.expectEqualStrings("hello world", field.text());

    // Select All then Cut copies and clears the buffer.
    field.selectAll();
    try testing.expect(field.hasSelection());
    var cut_item = MenuItem{ .field = &field, .action = .cut };
    menuPerform(&cut_item);
    try testing.expect(Rec.copied);
    try testing.expectEqual(@as(usize, 0), field.text().len);
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
    // tab 0 selected -> red content shows. (The tab bar's selected segment is
    // an accent chip, so some blue is always present; the blue *content* is
    // asserted as a large relative jump after switching tabs.)
    var fb0 = try renderToFb(&env, &c, TabView(sel.binding(), &tabs), .{ .x = 0, .y = 0, .width = 200, .height = 100 }, 200, 100);
    defer fb0.deinit();
    try testing.expect(countRed(&fb0) > 100);
    const blue_with_red_tab = countBlue(&fb0);

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

    // re-render -> tab 1 (blue) content now shows, red is gone
    env.hits.clearRetainingCapacity();
    var fb1 = try renderToFb(&env, &c, TabView(sel.binding(), &tabs), .{ .x = 0, .y = 0, .width = 200, .height = 100 }, 200, 100);
    defer fb1.deinit();
    try testing.expect(countBlue(&fb1) > blue_with_red_tab + 100);
    try testing.expect(countRed(&fb1) < 100);
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

// ── Painter seam ────────────────────────────────────────────────────────────

test "painter: macOS draws glass where Win2000 chisels a bevel" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const macos = @import("../theme/macos.zig");
    const win2000 = @import("../theme/win2000.zig");
    const tree = Button("OK", action(Counter.inc));

    // macOS prominent button: a blue glass gradient.
    const prominent = ButtonRoled("OK", .prominent, action(Counter.inc));
    var mc = env.ctx();
    mc.theme = macos.light;
    const ms = try measure(&mc, prominent, .unspecified);
    const mw: u32 = @intFromFloat(@ceil(ms.width));
    const mh: u32 = @intFromFloat(@ceil(ms.height));
    env.hits.clearRetainingCapacity();
    var mfb = try renderToFb(&env, &mc, prominent, Rect.fromOriginSize(.{}, ms), mw, mh);
    defer mfb.deinit();

    // Win2000 button: a silver face with a dark-shadow bottom bevel.
    var wc = env.ctx();
    wc.theme = win2000.light;
    const ws = try measure(&wc, tree, .unspecified);
    const ww: u32 = @intFromFloat(@ceil(ws.width));
    const wh: u32 = @intFromFloat(@ceil(ws.height));
    env.hits.clearRetainingCapacity();
    var wfb = try renderToFb(&env, &wc, tree, Rect.fromOriginSize(.{}, ws), ww, wh);
    defer wfb.deinit();

    // Win2000's outer bottom edge is the dark-shadow grey; macOS's body is blue.
    const w_bottom = wfb.at(ww / 2, wh - 1);
    try testing.expect(w_bottom.approxEql(win2000.light.colors.control_dark_shadow, 0.2));
    const m_mid = mfb.at(mw / 2, mh / 2);
    try testing.expect(m_mid.b > m_mid.r); // glass gradient is blue, not grey
    // ...and that same spot in Win2000 is the neutral silver face, not blue.
    const w_mid = wfb.at(ww / 2, wh / 2);
    try testing.expect(!(w_mid.b > w_mid.r + 0.1));
}

test "painter: Material tint follows the color scheme" {
    var env = TestEnv.init();
    env.setup();
    defer env.deinit();
    const macos = @import("../theme/macos.zig");
    // A frosted panel over a known (white) backdrop: the glass tint comes from
    // the theme's scheme-correct `Palette.glass`, so light vs dark differ.
    const tree = Empty().frame(40, 40).backgroundMaterial(.regular);
    const rect = Rect{ .x = 0, .y = 0, .width = 40, .height = 40 };

    var lc = env.ctx();
    lc.theme = macos.light;
    var lfb = try renderToFb(&env, &lc, tree, rect, 40, 40);
    defer lfb.deinit();

    var dc = env.ctx();
    dc.theme = macos.dark;
    var dfb = try renderToFb(&env, &dc, tree, rect, 40, 40);
    defer dfb.deinit();

    // Light glass keeps the white backdrop bright; dark glass darkens it.
    try testing.expect(lfb.at(20, 20).luminance() > dfb.at(20, 20).luminance() + 0.2);
}

test "painter: every family paints all controls without error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const families = [_]Theme{
        @import("../theme/macos.zig").light,
        @import("../theme/macos.zig").dark,
        @import("../theme/win2000.zig").light,
        @import("../theme/windows10.zig").light,
        @import("../theme/windows10.zig").dark,
        @import("../theme/kde.zig").light,
        @import("../theme/kde.zig").dark,
        @import("../theme/mui.zig").light,
        @import("../theme/mui.zig").dark,
    };
    const r = Rect{ .x = 0, .y = 0, .width = 60, .height = 24 };
    const knob = Rect{ .x = 0, .y = 0, .width = 18, .height = 18 };
    for (families) |th| {
        var canvas = Canvas.init(arena.allocator());
        const s = theme_mod.Surface{ .canvas = &canvas, .palette = &th.colors, .metrics = &th.metrics, .scheme = th.scheme };
        const p = th.painter;
        _ = try p.button(s, r, .normal, .{});
        try p.field(s, r, 4, .{});
        try p.segmentedTrack(s, r);
        _ = try p.segmentedSelection(s, r);
        try p.switchTrack(s, r, true);
        try p.switchKnob(s, knob, true);
        try p.slider(s, r, 0.5, knob, .{});
        try p.stepperBox(s, r, .{});
        try p.progress(s, r, 0.5);
        try p.panel(s, r, 8, .modal);
        try p.panel(s, r, 8, .popover);
        try testing.expect(canvas.commands.items.len > 0);
    }
}
