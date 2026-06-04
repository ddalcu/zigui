# zigui — Product Requirements & Plan

> A cross-platform, declarative UI library written in pure Zig that brings a
> native macOS / SwiftUI look and feel to macOS, Linux, and Windows.

| | |
|---|---|
| **Project name** | `zigui` |
| **Language** | Zig (target: 0.16.x stable; track latest stable) |
| **License** | MIT |
| **Status** | Pre-alpha, usable toolkit — **core + post-v0 features implemented & tested (146 tests, green on macOS + Linux)** |
| **Last updated** | 2026-06-04 |

---

## 0. Implementation status (v0)

The full **pure-Zig core** is built and test-driven (146 tests, green on macOS
and inside Linux Docker):

- **Foundation:** geometry, color (+ alpha compositing), observable `State(T)` /
  `Binding(T)`, two-pass layout engine (stacks / spacer / padding / frame /
  alignment), tokenized macOS light & dark themes.
- **Rendering:** retained `Canvas` command list + a **pure-Zig software
  rasterizer** with SDF anti-aliasing (rounded rects, strokes, gradients, lines,
  clipping, glyph & image blits). This is what makes the whole visual layer
  unit-testable headlessly.
- **Text:** a from-scratch TrueType parser + glyph rasterizer (cmap 4/12, simple
  & composite `glyf`, quadratic beziers), glyph cache, shaping/measurement and
  word-wrap, bundled **Inter** (OFL).
- **View layer:** declarative value-tree with fluent modifiers, hit testing,
  `ForEach`, focus management.
- **Components (~22):** `Text` `Label` `Image` `TextField` · `Button` `Toggle`
  `Slider` `Stepper` `ProgressView` `Picker` · `VStack` `HStack` `ZStack`
  `Spacer` `Divider` `ScrollView` `List` `ForEach` · `Rectangle`
  `RoundedRectangle` `Circle` `Capsule` `Ellipse` `LinearGradient`.
- **Backend:** an SDL3 window + event loop (`src/app.zig`) presenting the
  software-rasterized framebuffer, with mouse, text-input and key routing.
- **Examples:** `hello` (counter) and `settings` (the macOS-like milestone
  demo); CI matrix (macOS/Linux/Windows) + a Linux `Dockerfile`.

**Renderer decision (supersedes §2's wgpu plan):** the renderer rasterizes on
the **CPU** and presents through SDL3. This is a real, working,
identical-everywhere renderer that is fully testable headlessly and performs well
(build examples with `-Doptimize=ReleaseFast`). **wgpu-native is dropped for now**
— the SDL3 software-raster path is the chosen, shipping renderer, not a
placeholder. Because the `Canvas` command list cleanly isolates drawing, a GPU
backend could still be slotted in later behind the same interface with no
component changes, but it is no longer on the critical path.

The post-v0 feature set is now **implemented**: navigation (`NavigationSplitView`,
stack), `TabView`, modals (sheet/alert/popover, `Menu`/`ContextMenu`), grids
(`LazyVGrid`/`LazyHGrid`), animation, materials/blur, an accessibility node tree,
HiDPI scaling, wrapped text, app-owned scrolling, and a cross-platform system
tray (`app.Tray`). A streaming LLM-chat example (`examples/llm-chat`) exercises
them end-to-end.

---

## 1. Vision

SwiftUI is the gold standard for ergonomic, declarative, good-looking native
UI — but it is Apple-only and closed. `zigui` aims to deliver a **SwiftUI-like
developer experience and macOS-like visual design on every desktop OS**, using
its **own rendering pipeline** rather than wrapping native platform widgets.

On macOS, `zigui` draws with the same engine it uses on Linux and Windows — it
is *not* a translation layer to AppKit/SwiftUI. This guarantees pixel-identical
results across platforms and keeps the codebase a single, readable Zig project.

**Non-goals:** 100% SwiftUI API compatibility, source/binary compatibility with
Swift, mobile (iOS/Android) support in v1, web/WASM target in v1.

### Guiding principles

1. **Readability over cleverness.** This is an open-source framework people
   will read to learn from. Prefer explicit, well-named code over dense
   comptime metaprogramming. Comptime is a tool, not a goal.
2. **One renderer, all platforms.** Identical output everywhere.
3. **SwiftUI as a north star, not a spec.** We borrow concepts and naming where
   they help; we diverge freely where Zig idioms or clarity demand it.
4. **No hidden magic.** State, layout, and rendering should be inspectable and
   debuggable.
5. **Minimal, vetted dependencies.** Each C dependency must earn its place.

---

## 2. Architectural decisions (locked)

These were decided up front and frame the rest of the plan.

> **Update:** the **Rendering** row below was the original plan. As shipped, the
> renderer is a **pure-Zig CPU software rasterizer presented via SDL3**, and
> **wgpu-native has been dropped** (see §0). The row is kept for history.

| Area | Decision | Rationale |
|---|---|---|
| **Rendering** | ~~GPU via wgpu-native~~ → **pure-Zig CPU software rasterizer, presented via SDL3** | One code path, identical everywhere, fully testable headlessly, no GPU dependency to build/ship. wgpu dropped for now. |
| **API style** | **Comptime declarative tree** (`VStack(.{ Text("Hi"), Button(...) })`) | Closest feel to SwiftUI's declarative syntax while staying pure Zig. |
| **Windowing/input** | **SDL3** | Battle-tested window + input + GPU-surface creation across all 3 OSes. |
| **State / reactivity** | **Observable state + dirty flag** | Explicit `State(T)`; mutation marks subscribing views dirty and re-renders just those. Simpler & more debuggable than full tree diffing. |
| **Fonts / text** | **Bundle Inter (OFL)** + **pure-Zig TrueType rasterizer** + SDF atlas | SF-Pro-like look, legally clean, no C font dependency. |
| **Look & feel** | **Themeable, macOS default theme** | Ships looking like macOS everywhere; theming system allows custom/platform skins later. |
| **v1 scope** | **Usable toolkit** | Foundations + ~15–20 components + theming + state. Target: build a real settings-screen demo app. |

### Dependency budget

| Dependency | Type | Purpose | Justification |
|---|---|---|---|
| `SDL3` | C lib | Windowing + input + present (examples only) | Avoids 3 hand-written platform layers. Linked only into example executables, never the core/tests. |
| Inter font | asset (OFL) | Default UI font | SF-Pro-like, redistributable. |
| Pure-Zig TTF rasterizer | Zig code | Glyph rasterization | Keeps text stack dependency-free. |

> `wgpu-native` was in the original budget but has been **dropped** — the 2D
> renderer is a pure-Zig CPU rasterizer (no GPU dependency). Everything except
> SDL3 (layout, widgets, theming, state, text, the software rasterizer) is
> **pure Zig** with no external dependencies, and SDL3 links only into the
> example binaries — the library and its 146-test suite have **zero C deps**.

---

## 3. System architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Application code                                            │
│    VStack(.{ Text("Hello"), Button("Tap", .{...}) })         │
├─────────────────────────────────────────────────────────────┤
│  View layer        declarative views, modifiers, comptime    │
│                    tree construction                         │
├─────────────────────────────────────────────────────────────┤
│  State / reactivity   State(T), bindings, dirty propagation  │
├─────────────────────────────────────────────────────────────┤
│  Layout engine     flexbox-like constraint solver, stacks,   │
│                    frames, padding, alignment                │
├─────────────────────────────────────────────────────────────┤
│  Theming           macOS default theme, design tokens,       │
│                    colors, typography, metrics, dark mode    │
├─────────────────────────────────────────────────────────────┤
│  2D vector renderer   rounded rects, strokes, gradients,     │
│  (pure Zig)           shadows, clipping, text quads          │
├──────────────────────────────┬──────────────────────────────┤
│  Text engine                 │  Render backend               │
│  Inter + pure-Zig TTF        │  pure-Zig CPU rasterizer      │
│  + glyph cache               │  (SDF AA) → framebuffer       │
├──────────────────────────────┴──────────────────────────────┤
│  Platform layer    SDL3: window, event loop, input, present  │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Module layout (proposed)

```
zigui/
├── build.zig                # SDL3 linked into examples only
├── build.zig.zon            # no external zig deps (SDL3 linked from the system)
├── PRD.md
├── README.md
├── LICENSE                  # MIT
├── assets/
│   └── fonts/Inter-*.ttf    # OFL
├── src/
│   ├── zigui.zig            # public root / re-exports
│   ├── app.zig              # App, Scene, WindowGroup, run loop
│   ├── platform/
│   │   └── sdl.zig          # window, events, surface
│   ├── render/
│   │   ├── canvas.zig       # 2D draw-command list (backend-neutral seam)
│   │   ├── raster.zig       # pure-Zig CPU rasterizer (SDF AA) → framebuffer
│   │   └── color.zig        # (the proposed gpu/ wgpu backend was dropped)
│   ├── text/
│   │   ├── ttf.zig          # pure-Zig TrueType parser/rasterizer
│   │   ├── atlas.zig        # SDF glyph atlas
│   │   ├── shape.zig        # layout, line breaking
│   │   └── font.zig
│   ├── layout/
│   │   ├── engine.zig       # measure/arrange passes
│   │   ├── stack.zig        # V/H/Z stack solvers
│   │   └── geometry.zig     # Size, Rect, EdgeInsets, Alignment
│   ├── state/
│   │   ├── state.zig        # State(T), Binding(T)
│   │   └── observe.zig      # dirty propagation
│   ├── view/
│   │   ├── view.zig         # View interface, modifier chain
│   │   ├── modifier.zig     # padding, frame, background, etc.
│   │   └── tree.zig         # retained node tree + reconciliation
│   ├── theme/
│   │   ├── theme.zig        # Theme struct, tokens
│   │   └── macos.zig        # default macOS theme values
│   └── components/
│       ├── text.zig
│       ├── button.zig
│       ├── stacks.zig
│       ├── ...              # see component inventory
│       └── ...
├── examples/
│   ├── hello/
│   └── settings/            # v1 milestone demo
└── tests/
```

---

## 4. SwiftUI component inventory & port plan

This is the working catalog of SwiftUI's surface area, mapped to `zigui`
equivalents with target tiers. Naming follows SwiftUI where it reads well in
Zig; modifiers become chained methods or fields in the comptime config struct.

**Tier legend:** **T1** = v1 "usable toolkit" must-have · **T2** = v1.x
fast-follow · **T3** = later / nice-to-have · **N/A** = out of scope or
platform-specific.

### 4.1 Layout containers

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `VStack` / `HStack` / `ZStack` | `VStack` / `HStack` / `ZStack` | **T1** | Core layout primitives. |
| `Spacer` | `Spacer` | **T1** | Flexible space. |
| `Divider` | `Divider` | **T1** | |
| `Grid` / `GridRow` | `Grid` | **T2** | |
| `LazyVStack` / `LazyHStack` | `LazyVStack` / `LazyHStack` | **T2** | Virtualized. |
| `LazyVGrid` / `LazyHGrid` | `LazyVGrid` / `LazyHGrid` | **T2** | |
| `ScrollView` | `ScrollView` | **T1** | Needs clipping + scroll input. |
| `List` | `List` | **T1** | Core; sectioned in T2. |
| `Form` | `Form` | **T2** | Settings-style grouped layout. |
| `Section` | `Section` | **T2** | |
| `GeometryReader` | `GeometryReader` | **T2** | |
| `ViewThatFits` | `ViewThatFits` | **T3** | |

### 4.2 Text & images

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `Text` | `Text` | **T1** | Styling, weight, color, multiline. |
| `Label` | `Label` | **T2** | Text + icon. |
| `TextField` | `TextField` | **T1** | Editing, caret, selection. |
| `SecureField` | `SecureField` | **T2** | |
| `TextEditor` | `TextEditor` | **T2** | Multiline editing. |
| `Image` | `Image` | **T1** | PNG/decoded bitmap. |
| `AsyncImage` | `AsyncImage` | **T3** | Needs async/IO story. |
| SF Symbols | `Symbol` (bundled icon set) | **T2** | Use an open icon set (e.g. Lucide/Phosphor) — SF Symbols are proprietary. |

### 4.3 Controls

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `Button` | `Button` | **T1** | Variants/styles. |
| `Toggle` | `Toggle` | **T1** | macOS switch look. |
| `Slider` | `Slider` | **T1** | |
| `Stepper` | `Stepper` | **T2** | |
| `Picker` | `Picker` | **T2** | Menu/segmented variants. |
| `Menu` | `Menu` | **T2** | Popover menu. |
| `DatePicker` | `DatePicker` | **T3** | |
| `ColorPicker` | `ColorPicker` | **T3** | |
| `ProgressView` | `ProgressView` | **T2** | Bar + spinner. |
| `Gauge` | `Gauge` | **T3** | |
| `Link` | `Link` | **T2** | |
| `SegmentedControl` (Picker style) | via `Picker` | **T2** | |

### 4.4 Navigation & presentation

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `NavigationStack` / `NavigationSplitView` | `NavigationStack` / `NavigationSplitView` | **T2** | Sidebar + detail (mac-like). |
| `TabView` | `TabView` | **T2** | |
| `Sheet` / `.sheet` | `Sheet` | **T2** | Modal presentation. |
| `Popover` / `.popover` | `Popover` | **T2** | |
| `Alert` / `.alert` | `Alert` | **T2** | |
| `ConfirmationDialog` | `ConfirmationDialog` | **T3** | |
| `Toolbar` | `Toolbar` | **T2** | Window toolbar (mac titlebar style). |
| `ContextMenu` | `ContextMenu` | **T2** | |
| Menu bar / commands | `Commands` | **T3** | Native menu bar integration is platform-specific. |

### 4.5 Modifiers (chained config)

| SwiftUI modifier | zigui | Tier |
|---|---|---|
| `.padding()` | `.padding` | **T1** |
| `.frame(width:height:)` | `.frame` | **T1** |
| `.background()` | `.background` | **T1** |
| `.foregroundStyle()` / `.foregroundColor()` | `.foreground` | **T1** |
| `.cornerRadius()` / `.clipShape()` | `.cornerRadius` / `.clip` | **T1** |
| `.font()` | `.font` | **T1** |
| `.opacity()` | `.opacity` | **T1** |
| `.shadow()` | `.shadow` | **T1** |
| `.overlay()` / `.border()` | `.overlay` / `.border` | **T1** |
| `.offset()` / `.position()` | `.offset` / `.position` | **T2** |
| `.rotationEffect()` / `.scaleEffect()` | `.rotation` / `.scale` | **T2** |
| `.onTapGesture` / `.gesture` | `.onTap` / `.gesture` | **T1 / T2** |
| `.animation()` / `withAnimation` | `.animation` | **T2** |
| `.disabled()` | `.disabled` | **T1** |
| `.hidden()` | `.hidden` | **T2** |
| `.zIndex()` | `.zIndex` | **T2** |

### 4.6 State & data flow

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `@State` | `State(T)` | **T1** | Observable value + dirty flag. |
| `@Binding` | `Binding(T)` | **T1** | Two-way reference into a `State`. |
| `@Observable` / `ObservableObject` | `Observable` | **T2** | Object-level observation. |
| `@Environment` / `EnvironmentValues` | `Environment` | **T2** | Theme, color scheme injection. |
| `@EnvironmentObject` | (covered by `Environment`) | **T2** | |
| `@StateObject` | `StateObject` | **T2** | Owned reference state. |
| `ForEach` | `ForEach` | **T1** | Collection → views, keyed. |
| `@AppStorage` | `AppStorage` | **T3** | Persisted settings. |

### 4.7 Drawing & effects

| SwiftUI | zigui | Tier |
|---|---|---|
| `Rectangle` / `RoundedRectangle` | `Rectangle` / `RoundedRectangle` | **T1** |
| `Circle` / `Ellipse` / `Capsule` | `Circle` / `Ellipse` / `Capsule` | **T1** |
| `Path` | `Path` | **T2** |
| `LinearGradient` / `RadialGradient` / `AngularGradient` | `LinearGradient` / `RadialGradient` / `AngularGradient` | **T1 / T2** |
| `Canvas` | `Canvas` | **T2** |
| `.blur()` / material / `.background(.ultraThinMaterial)` | `Material` / `.blur` | **T3** | Mac vibrancy/blur is GPU-expensive; later. |

### 4.8 App structure

| SwiftUI | zigui | Tier | Notes |
|---|---|---|---|
| `App` protocol | `App` | **T1** | Entry point. |
| `WindowGroup` / `Scene` | `WindowGroup` / `Scene` | **T1** | |
| `Settings` scene | `Settings` | **T3** | |
| `@main` | `zigui.run(App)` | **T1** | Zig has no `@main` attribute; explicit run. |

---

## 5. The programming model

### 5.1 Declarative views (comptime tree)

```zig
const zigui = @import("zigui");
const Text = zigui.Text;
const Button = zigui.Button;
const VStack = zigui.VStack;

fn ContentView(state: *AppState) zigui.View {
    return VStack(.{ .spacing = 12 }, .{
        Text("Welcome to zigui")
            .font(.title)
            .foreground(.primary),
        Text(state.message)
            .foreground(.secondary),
        Button("Click me", .{ .onTap = onClick })
            .padding(8),
    });
}
```

Open design questions to resolve in implementation (documented, not yet
decided):

- How children of heterogeneous types are stored in the comptime tuple and
  type-erased into the retained node tree.
- Modifier chaining ergonomics (`.padding(8).background(...)`) vs a config
  struct, and how to keep error messages readable.
- Memory ownership: arena-per-frame for transient view structs vs retained
  nodes that persist across frames.

### 5.2 State & reactivity (observable + dirty flag)

```zig
var count = zigui.State(i32).init(0);

// reading subscribes the current view; writing marks subscribers dirty
Button("Increment", .{ .onTap = struct {
    fn f() void { count.set(count.get() + 1); }
}.f });

Text(zigui.fmt("Count: {d}", .{count.get()}));
```

- `State(T)` holds a value plus a list of subscribing view nodes.
- Reading inside a view's body records a subscription.
- `set()` (or `update()`) marks subscribers **dirty**; the run loop re-renders
  only dirty subtrees on the next frame.
- `Binding(T)` is a typed two-way handle into a `State(T)` for controls like
  `TextField` and `Toggle`.

### 5.3 Layout

A two-pass, SwiftUI-inspired layout protocol:

1. **Measure / propose:** parent proposes a size; child returns its desired
   size given that proposal.
2. **Arrange / place:** parent assigns final frames to children based on
   alignment, spacing, and `Spacer`/flexible-frame rules.

Stacks, frames, padding, and alignment guides are the core. The engine is pure
Zig and unit-testable without a GPU.

### 5.4 Rendering pipeline

1. Layout produces a tree of placed nodes with absolute rects.
2. Each node emits **draw commands** to the 2D `Canvas` (rounded rects,
   strokes, gradients, blur/material, clip pushes/pops, glyph & image quads).
3. The **pure-Zig software rasterizer** executes the command list into an RGBA
   framebuffer with SDF anti-aliasing (and, on HiDPI, at device resolution).
4. SDL3 uploads the framebuffer to a streaming texture and presents it.

Text: glyphs are rasterized by the pure-Zig TTF engine and kept in a **glyph
cache** keyed by glyph + pixel size, so they are reused cheaply across frames.

---

## 6. Theming

- `Theme` is a struct of **design tokens**: color roles (`primary`,
  `secondary`, `accent`, `background`, `controlBackground`, `separator`, …),
  typography scale (`largeTitle`, `title`, `headline`, `body`, `caption`),
  spacing/metrics, corner radii, and control sizing.
- `theme/macos.zig` provides the default token values tuned to match macOS
  (light + dark). This ships as the default everywhere.
- Apps can supply a custom `Theme` or override individual tokens via
  `Environment`. A future platform-native theme can be added without touching
  component code.
- **Dark mode** is a first-class theme variant from day one.

> Legal note: we ship **Inter** (OFL) and an **open icon set** for symbols.
> We do **not** redistribute SF Pro, SF Symbols, or other Apple assets. The
> "mac look" is achieved through tuned tokens and metrics, not Apple assets.

---

## 7. Milestones & roadmap

### v0.1 — Foundations (architecture proof)
**Goal:** a styled `Text` + `Button` in a resizable window on macOS, Linux,
and Windows, sharing one renderer.

- [x] `build.zig` + `build.zig.zon` wiring SDL3 on all 3 OSes (wgpu dropped).
- [x] Platform layer: window creation, event loop, input (SDL3).
- [x] Renderer: pure-Zig CPU software rasterizer → framebuffer, presented via SDL3.
- [x] 2D canvas: filled & stroked rounded rects, solid colors, clipping.
- [ ] Text engine: pure-Zig TTF parse + raster, SDF atlas, draw a text run.
- [ ] Layout engine: measure/arrange, `VStack`/`HStack`, padding, frame.
- [ ] State: `State(T)`, dirty flag, dirty-driven re-render.
- [ ] View tree: comptime construction → retained node tree.
- [ ] Components: `Text`, `Button`, `VStack`, `HStack`, `Rectangle`, `Spacer`.
- [ ] Theme: macOS default tokens (light), color + typography.
- [ ] `examples/hello`.

### v0.2 — Core interaction
- [ ] Modifiers: `.background`, `.foreground`, `.cornerRadius`, `.shadow`,
      `.font`, `.opacity`, `.border`, `.overlay`, `.disabled`, `.onTap`.
- [ ] `ZStack`, `Divider`, gradients (`LinearGradient`).
- [ ] `TextField` with caret/selection; `Binding(T)`.
- [ ] `Toggle`, `Slider`.
- [ ] `ScrollView` with clipping + scroll/wheel input.
- [ ] Dark mode theme variant + `Environment` color scheme.
- [ ] Shapes: `Circle`, `Capsule`, `RoundedRectangle`.

### v0.3 — Lists & data flow
- [ ] `List`, `ForEach` (keyed), `Section`, `Form`.
- [ ] `LazyVStack`/`LazyHStack` virtualization.
- [ ] `Image` (PNG decode), `Label`, `Symbol` (open icon set).
- [ ] `ProgressView`, `Picker`, `Stepper`, `Menu`.
- [ ] `Observable`/`StateObject`.

### v1.0 — Usable toolkit (milestone target)
**Goal:** build a real **settings-screen demo app** end to end.

- [ ] `examples/settings`: sidebar + form, toggles, sliders, pickers, text
      fields, sections — looking convincingly macOS-like on all 3 OSes.
- [ ] `NavigationSplitView` / sidebar, `TabView`, `Toolbar`.
- [ ] `Sheet`, `Popover`, `Alert`, `ContextMenu`.
- [ ] Basic animation (`.animation`, transitions for show/hide).
- [ ] Theming docs + custom theme example.
- [ ] Solid docs, API reference, getting-started guide.
- [ ] CI building + testing on macOS, Linux, Windows.
- [ ] ~15–20 polished components (see Tier T1 + key T2).

### Post-v1 (T2/T3 backlog)
Navigation polish, `TextEditor`, `Grid`/`LazyGrid`, `DatePicker`,
`ColorPicker`, `Canvas`/`Path` drawing, materials/vibrancy/blur,
`AsyncImage`, accessibility (see §9), `AppStorage`, menu-bar commands,
gesture system, and broader SwiftUI parity.

---

## 8. Quality, testing & tooling

- **Unit tests** for layout (golden size/frame assertions), state propagation,
  TTF parsing, and the path/geometry math — all runnable without a GPU.
- **Snapshot/visual tests:** render canvases to an offscreen buffer and compare
  against golden PNGs to catch visual regressions cross-platform.
- **CI matrix:** macOS + Linux + Windows; build all examples, run tests,
  produce snapshot diffs as artifacts.
- **`zig fmt`** enforced; documented public API with doc comments.
- **Examples are tests:** every example must build in CI.

---

## 9. Open questions & risks

| Topic | Question / risk | Plan |
|---|---|---|
| Comptime ergonomics | Heterogeneous children in a comptime tuple + type erasure into retained nodes; compile-time cost & error legibility. | **Resolved:** `View` is a single value type (a `Kind` union + `Modifiers`), so `[]const View` children just work. Constructors accept a tuple literal (`VStack(.{a, b})`) and copy it into the build arena. Modifiers are plain methods returning a `View` by value — no comptime metaprogramming, readable errors. |
| Memory model | Per-frame arena for transient view structs vs persistent retained nodes. | **Resolved:** a per-frame **arena** holds the view tree, lowered layout nodes, draw commands and hit regions; it is reset (not freed) each frame and persists until the next rebuild, so hit regions stay valid during event dispatch. Observable state lives outside the arena (app-owned). |
| Text shaping | Complex scripts / RTL / ligatures / bidi not covered by a simple rasterizer. | v1 targets Latin/basic shaping; flag advanced shaping (HarfBuzz-equivalent) as post-v1. |
| Accessibility | No native a11y tree when we draw everything ourselves. | Out of scope for v1; design an accessibility node tree as a tracked post-v1 workstream (screen readers, focus). |
| HiDPI / scaling | Per-monitor DPI, fractional scaling across OSes. | Handle scale factor in the layout→render transform from v0.1; test on HiDPI displays. |
| ~~wgpu-native maturity~~ | API churn, build/distribution per OS. | **Resolved by dropping it** — the CPU software rasterizer needs no GPU dependency and is identical everywhere. A GPU backend behind the `Canvas` seam remains possible but is not planned. |
| Software-raster performance | CPU rasterizing a full HiDPI window each frame can be slow. | Event-driven loop (render on change, not a fixed FPS) + ship/run with `ReleaseFast`, where it is smooth. A GPU backend is the lever if it's ever needed. |
| IME / international input | Text input for non-Latin keyboards. | Rely on SDL3 text input events; full IME composition is post-v1. |
| "Mac look" fidelity | Matching macOS metrics/animation curves without Apple assets. | Tune theme tokens against reference screenshots; accept "convincingly mac-like," not pixel-identical to AppKit. |

---

## 10. Summary

`zigui` is a pure-Zig, single-renderer, declarative UI library that targets a
macOS/SwiftUI look and feel across macOS, Linux, and Windows. It renders with a
**pure-Zig CPU software rasterizer presented via SDL3** (wgpu-native was dropped —
the SDL3 path works well and keeps the core C-dependency-free), a comptime
declarative view API, observable-state reactivity, and a bundled Inter font with
a pure-Zig text stack. It ships a "usable toolkit" of ~20 polished components plus
navigation, tabs, modals, grids, animation, materials, accessibility, HiDPI, and
a cross-platform system tray — proven by settings, showcase, and streaming
LLM-chat demos, with readability and open-source approachability as first-class
goals.
