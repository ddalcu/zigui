//! Public component constructors, re-exported from the view layer as a single
//! namespace. Components are values: call a constructor and chain modifiers.
//!
//!     const c = @import("zigui").components;
//!     c.VStack(.{ c.Text("Hi").font(.title), c.Button("Go", onGo) })

const view = @import("view/view.zig");

// Layout containers
pub const VStack = view.VStack;
pub const HStack = view.HStack;
pub const ZStack = view.ZStack;
pub const Spacer = view.Spacer;
pub const MinSpacer = view.MinSpacer;
pub const Divider = view.Divider;
pub const VDivider = view.VDivider;
pub const ForEach = view.ForEach;
pub const ScrollView = view.ScrollView;
pub const ScrollViewOffset = view.ScrollViewOffset;
pub const ScrollViewState = view.ScrollViewState;
pub const ScrollState = view.ScrollState;
pub const ScrollRegion = view.ScrollRegion;
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
pub const NavigationSplitView = view.NavigationSplitView;
pub const NavigationLink = view.NavigationLink;
pub const NavBackButton = view.NavBackButton;
pub const NavState = view.NavState;
pub const Menu = view.Menu;
pub const ContextMenu = view.ContextMenu;

// Text & images
pub const Text = view.Text;
pub const WrappedText = view.WrappedText;
pub const Label = view.Label;
pub const Image = view.Image;
pub const Icon = view.Icon;
pub const IconButton = view.IconButton;
pub const IconName = view.IconName;
pub const TextField = view.TextField;
pub const TextFieldState = view.TextFieldState;
pub const TextEditor = view.TextEditor;

// Controls
pub const Button = view.Button;
pub const ButtonRoled = view.ButtonRoled;
pub const Toggle = view.Toggle;
pub const Slider = view.Slider;
pub const Stepper = view.Stepper;
pub const ProgressView = view.ProgressView;
pub const Picker = view.Picker;

// Shapes & gradients
pub const Rectangle = view.Rectangle;
pub const RoundedRectangle = view.RoundedRectangle;
pub const Circle = view.Circle;
pub const Capsule = view.Capsule;
pub const Ellipse = view.Ellipse;
pub const LinearGradient = view.LinearGradient;
pub const Material = view.Material;

// Misc
pub const Empty = view.Empty;
pub const fmt = view.fmt;
