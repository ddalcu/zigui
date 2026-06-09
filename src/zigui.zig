//! zigui — a cross-platform, declarative UI library written in pure Zig with a
//! native macOS / SwiftUI look and feel.
//!
//! This root module re-exports the public API. The core (everything below the
//! GPU/windowing backend) is pure Zig with no C dependencies, so the full test
//! suite runs headless on macOS, Linux, and Windows.

const std = @import("std");

/// The library version. `build.zig` reads it from `build.zig.zon` (the package
/// manifest) and injects it here, so the manifest is the single source of truth
/// — `zigui.version`, the `zig fetch` tag, and the manifest can never drift.
pub const version = std.SemanticVersion.parse(@import("build_options").version) catch unreachable;

// Foundation modules are re-exported here as they are implemented (TDD: a
// module is referenced for test discovery only once it exists).
pub const geometry = @import("layout/geometry.zig");
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const EdgeInsets = geometry.EdgeInsets;
pub const Alignment = geometry.Alignment;
pub const HorizontalAlignment = geometry.HorizontalAlignment;
pub const VerticalAlignment = geometry.VerticalAlignment;
pub const Axis = geometry.Axis;

pub const color = @import("render/color.zig");
pub const Color = color.Color;
pub const canvas = @import("render/canvas.zig");
pub const Canvas = canvas.Canvas;
pub const DrawCommand = canvas.DrawCommand;
pub const raster = @import("render/raster.zig");
pub const Framebuffer = raster.Framebuffer;

pub const observe = @import("state/observe.zig");
pub const Observer = observe.Observer;
pub const state = @import("state/state.zig");
pub const State = state.State;
pub const Binding = state.Binding;

pub const animation = @import("animation.zig");
pub const Animator = animation.Animator;
pub const Easing = animation.Easing;
pub const Tween = animation.Tween;

pub const layout = @import("layout/engine.zig");
pub const stack_layout = @import("layout/stack.zig");
pub const Node = layout.Node;
pub const Proposal = layout.Proposal;
pub const SizingHints = layout.SizingHints;
pub const LayoutResult = layout.LayoutResult;

pub const ttf = @import("text/ttf.zig");
pub const atlas = @import("text/atlas.zig");
pub const shape = @import("text/shape.zig");
pub const font = @import("text/font.zig");
pub const icons = @import("icons.zig");
pub const Font = font.Font;
pub const GlyphCache = atlas.GlyphCache;
pub const drawText = font.drawText;

pub const theme = @import("theme/theme.zig");
pub const macos = @import("theme/macos.zig");
pub const win2000 = @import("theme/win2000.zig");
pub const windows10 = @import("theme/windows10.zig");
pub const kde = @import("theme/kde.zig");
pub const mui = @import("theme/mui.zig");
pub const theme_registry = @import("theme/registry.zig");
pub const Theme = theme.Theme;
pub const Palette = theme.Palette;
pub const Painter = theme.Painter;
// Painter-authoring types — so third parties can implement a theme's chrome.
pub const Surface = theme.Surface;
pub const ControlState = theme.ControlState;
pub const Role = theme.Role;
pub const TextStyle = theme.TextStyle;
pub const FontWeight = theme.FontWeight;
pub const ColorScheme = theme.ColorScheme;
/// Built-in theme families (macOS, Windows 10, Windows 2000, KDE Plasma).
pub const ThemeFamily = theme_registry.Family;
/// Resolve a theme family to a concrete `Theme` for the OS color scheme.
pub const themeForScheme = theme_registry.forScheme;
/// The default theme (macOS light).
pub const default_theme = macos.light;

pub const view = @import("view/view.zig");
pub const View = view.View;
pub const Context = view.Context;
pub const Callback = view.Callback;
pub const action = view.action;
pub const actionCtx = view.actionCtx;
pub const HitRegion = view.HitRegion;
pub const dispatchTap = view.dispatchTap;
pub const dispatchDoubleClick = view.dispatchDoubleClick;
pub const dispatchTripleClick = view.dispatchTripleClick;
pub const ScrollState = view.ScrollState;
pub const ScrollRegion = view.ScrollRegion;
pub const dispatchScroll = view.dispatchScroll;
pub const setFrameTime = view.setFrameTime;
pub const scrollbarsAnimating = view.scrollbarsAnimating;
pub const dispatchDrag = view.dispatchDrag;
pub const endDrag = view.endDrag;
pub const render = view.render;
pub const renderInto = view.renderInto;
pub const renderScaled = view.renderScaled;
pub const measureView = view.measure;
pub const OverlayStyle = view.OverlayStyle;
pub const OverlayReq = view.OverlayReq;
pub const A11yRole = view.A11yRole;
pub const A11yNode = view.A11yNode;
pub const beginBuild = view.beginBuild;
pub const endBuild = view.endBuild;
pub const focusedField = view.focusedField;
pub const setFocus = view.setFocus;
pub const clearFocus = view.clearFocus;
pub const submitFocused = view.submitFocused;

// Text-field context menu (right-click Cut/Copy/Paste/Select All).
pub const ClipboardOps = view.ClipboardOps;
pub const setClipboardOps = view.setClipboardOps;
pub const fieldAt = view.fieldAt;
pub const openContextMenu = view.openContextMenu;
pub const closeContextMenu = view.closeContextMenu;
pub const contextMenuOpen = view.contextMenuOpen;
pub const hoverContextMenu = view.hoverContextMenu;

// Public component constructors (also available via `zigui.components.*`).
pub const components = @import("components.zig");
pub const Text = view.Text;
pub const WrappedText = view.WrappedText;
pub const VStack = view.VStack;
pub const HStack = view.HStack;
pub const ZStack = view.ZStack;
pub const Spacer = view.Spacer;
pub const MinSpacer = view.MinSpacer;
pub const Divider = view.Divider;
pub const ForEach = view.ForEach;
pub const Button = view.Button;
pub const ButtonRoled = view.ButtonRoled;
pub const Empty = view.Empty;
pub const Toggle = view.Toggle;
pub const Slider = view.Slider;
pub const Stepper = view.Stepper;
pub const ProgressView = view.ProgressView;
pub const Picker = view.Picker;
pub const TextField = view.TextField;
pub const TextFieldState = view.TextFieldState;
pub const TextEditor = view.TextEditor;
pub const Label = view.Label;
pub const Image = view.Image;
pub const Icon = view.Icon;
pub const IconButton = view.IconButton;
pub const IconName = view.IconName;
pub const ScrollView = view.ScrollView;
pub const ScrollViewState = view.ScrollViewState;
pub const ScrollViewOffset = view.ScrollViewOffset;
pub const List = view.List;
pub const LazyVGrid = view.LazyVGrid;
pub const LazyHGrid = view.LazyHGrid;
pub const Tab = view.Tab;
pub const TabView = view.TabView;
pub const Sidebar = view.Sidebar;
pub const SidebarItem = view.SidebarItem;
pub const RadioGroup = view.RadioGroup;
pub const Table = view.Table;
pub const TableColumn = view.TableColumn;
pub const selectAction = view.selectAction;
pub const setThemeTokens = view.setThemeTokens;
pub const BuildTokens = view.BuildTokens;
pub const NavigationSplitView = view.NavigationSplitView;
pub const NavigationLink = view.NavigationLink;
pub const NavBackButton = view.NavBackButton;
pub const NavState = view.NavState;
pub const Menu = view.Menu;
pub const ContextMenu = view.ContextMenu;
pub const VDivider = view.VDivider;
pub const Rectangle = view.Rectangle;
pub const RoundedRectangle = view.RoundedRectangle;
pub const Circle = view.Circle;
pub const Capsule = view.Capsule;
pub const Ellipse = view.Ellipse;
pub const LinearGradient = view.LinearGradient;
pub const Material = view.Material;

test {
    std.testing.refAllDecls(@This());
    _ = @import("integration_test.zig");
}

test "version is parsed from the package manifest" {
    // Derived from build.zig.zon via build_options; a malformed manifest version
    // would have already failed the comptime parse. Guard against a 0.0.0 stub.
    try std.testing.expect(version.major != 0 or version.minor != 0 or version.patch != 0);
}
