# CLAUDE.md — working on zigui

Agent-facing guide: how to build/test, the non-obvious gotchas, the architecture
map, the recipe for adding a component, and how the post-v0 feature set
(navigation, tabs, modals, grids, animation, materials, accessibility, HiDPI) is
implemented. User-facing docs live in [README.md](README.md); design rationale in
[PRD.md](PRD.md).

## TL;DR

`zigui` is a SwiftUI-like UI library in **pure Zig 0.16**. The core (geometry,
color, state, layout, theme, text, canvas, software rasterizer, view layer,
components) has **no C dependencies** and is fully unit-tested headlessly. SDL3
links only into example executables (`src/app.zig`). The on-screen renderer is a
**CPU software rasterizer presented via SDL3** (wgpu is the planned upgrade —
see PRD §0/§9; the `Canvas` command list is the seam).

The post-v0 feature set — grids, tabs, navigation, modals/overlays, animation,
materials/blur, accessibility, and HiDPI — is **implemented**; see
[Post-v0 features](#post-v0-features-implemented) for the shipped APIs and the
seams each one uses.

## Build / test / run — and the gotchas

```sh
zig build test --summary all                # 146 tests, headless. THIS is the inner loop.
zig build hello settings showcase llm-chat  # build the examples (does NOT run them)
zig build run-showcase                       # opens a window — blocks on the event loop
docker build -t zigui-test .                 # run the full suite on Linux

# Headless proof the llm-chat networking works against a real LLM (no window):
./zig-out/bin/llm-chat --smoke "say hi" --model <name>            # one-shot
./zig-out/bin/llm-chat --smoke "count to 5" --model <name> --stream  # SSE path
```

- **Use `zig build test`, NOT `zig test src/zigui.zig`.** The bundled Inter font
  is an anonymous import `inter_font` wired only in `build.zig`
  (`mod.addAnonymousImport("inter_font", ...)`); `text/ttf.zig` does
  `@embedFile("inter_font")`. The raw `zig test` invocation has no such import
  and fails.
- **Never run `zig build run-*` in a headless/agent context** — it opens an SDL
  window and blocks in `SDL_WaitEvent`. Use `zig build hello settings` to verify
  the backend compiles/links.
- Tests are **inline** (`test "..." {}` blocks). A module's tests only run if the
  root (`src/zigui.zig`) imports it — add a `pub const x = @import(...)` there.
- **Zig 0.16 gotchas hit during the build** (so you don't rediscover them):
  - `std.ArrayList(T)` is **unmanaged**: `var l: std.ArrayList(T) = .empty;`
    then `l.append(allocator, x)`, `l.deinit(allocator)`.
  - `std.testing.refAllDeclsRecursive` is gone; use `refAllDecls`.
  - `std.fs` is reorganized (no `cwd()`/`accessAbsolute` free fns; moved to
    `std.Io.Dir`). The build script avoids fs probing entirely.
  - **The new `std.Io` model removed a lot from `std`**: the socket primitives
    (`socket`/`connect`/`fcntl`/`send`/`recv`/`close`) are gone from `std.posix`
    *and* not `pub` in `std.c`; `std.net` moved to `std.Io.net`; `std.time` lost
    `milliTimestamp`/`sleep`; `std.process.argsAlloc` is gone (args arrive via a
    `std.process.Init.Minimal` first param to `main`, iterated with
    `std.process.Args.iterate`); `std.heap.GeneralPurposeAllocator` is gone (use
    `page_allocator`/`DebugAllocator`). `examples/llm-chat` sidesteps the socket
    gap by `@cImport`-ing the POSIX headers (libc is linked) — see its
    `chat_client.zig`.
  - **Inferred error sets + recursion = "dependency loop"**. Mutually/​self-
    recursive fns that allocate must declare an explicit error set, e.g.
    `Allocator.Error!void` (see `engine.arrange`, `ttf.collectEdges`).
  - **Don't name fields/methods after primitives** (`u16`, `i16`, …) — compile
    error. (See the `Be` reader in `ttf.zig` using `rdU16` etc.)

## Architecture map (data flow)

```
View (value tree)               src/view/view.zig
  └─ buildNode → layout.Node     (lowering; modifiers become padding/frame nodes)
       └─ engine.arrange → LayoutResult (frames)   src/layout/engine.zig (+ stack.zig)
            └─ paint co-walks View + LayoutResult, emitting DrawCommands
                 → Canvas (command list)           src/render/canvas.zig
                      └─ raster.render → Framebuffer (RGBA)  src/render/raster.zig  [tests/headless]
                      └─ (future) wgpu backend                                       [on-screen GPU]
app.zig (SDL3): build → render → upload framebuffer to texture → present → events
```

| File | Responsibility |
|---|---|
| `src/view/view.zig` | **The hub.** `View`, `Kind` union, constructors, `Modifiers`, `buildNode`/`measure`/`render`/`paint`/`paintContent`, `HitAction`/`dispatchTap`, focus. Most features touch this. |
| `src/layout/engine.zig` | `Node` union, `Proposal`, `SizingHints`, `measure`, `arrange`→`LayoutResult`. Pure, tested. |
| `src/layout/stack.zig` | `distribute()` — the stack space-allocation math. Pure. |
| `src/render/canvas.zig` | `DrawCommand` union + `Canvas` builder. The renderer-agnostic seam. |
| `src/render/raster.zig` | `Framebuffer` + software rasterizer (SDF AA). Where new draw primitives get pixels. |
| `src/text/*` | `ttf` (parser+rasterizer), `atlas` (`GlyphCache`), `shape` (measure/wrap), `font` (`drawText`). |
| `src/theme/*` | `Theme` tokens; `macos.light`/`macos.dark`. |
| `src/state/*` | `State(T)`, `Binding(T)`, `Observer`. |
| `src/app.zig` | SDL3 window/event loop. **Only file that links C.** Where overlays, animation ticking, HiDPI scale, and key routing get wired. |
| `src/components.zig`, `src/zigui.zig` | Public re-exports. |

### Key invariants
- **Per-frame arena.** The view tree, lowered nodes, draw commands, and hit
  regions are all allocated in an arena that is `reset(.retain_capacity)` each
  frame and **persists until the next rebuild** — so hit regions stay valid
  during event dispatch. Observable `State`/`Binding` live *outside* the arena
  (app-owned).
- **Constructors use a thread-local build arena** set by `view.beginBuild(arena)`
  / `endBuild()`. Build views only between those calls (the app and `TestEnv` do
  this for you).
- **`dispatchTap` walks hit regions back-to-front** (last appended = topmost).
  This is why overlays/modals work: append their regions last.
- **Paint inherits environment** via a copied `child_ctx` (foreground, font_size,
  opacity, disabled). Add new inherited properties there.

## Recipe: add a component

1. **Data + `Kind` variant** in `view.zig` (e.g. `pub const FooData = struct {…};`
   then add `foo: FooData` to `Kind`).
2. **Constructor** free fn: `pub fn Foo(...) View { return .{ .kind = .{ .foo = … } }; }`
   (use `buildAlloc()` if it needs to own a slice/child).
3. **Sizing** — add an arm to `buildContentNode` returning an `engine.Node`
   (usually a `.leaf` with `SizingHints`, or a `.stack`/`.padding`/`.frame`).
4. **Painting** — add an arm to `paintContent` that emits `Canvas` commands for
   `clr.frame`; multiply colors by `ctx.opacity`.
5. **Interaction (optional)** — add a `HitAction` variant, handle it in
   `performAction`, and `ctx.hit_regions.append(ctx.arena, …)` in your paint fn.
6. **Re-export** in `components.zig` and `zigui.zig`.
7. **Test** (inline, using the `TestEnv`/`Harness` pattern): build → `render` to a
   `Framebuffer` → assert pixels and/or state mutations via `dispatchTap`.

Study `Toggle`/`Slider`/`Picker` end-to-end as the template — they cover sizing,
painting, and `Binding`-mutating interaction.

## Testing conventions
- Inline `test` blocks; pixel assertions via the software rasterizer
  (`Framebuffer.at(x,y)` → `Color`, plus `approxEql`, `luminance`).
- Reuse the `TestEnv` (in `view.zig`) / `Harness` (in `integration_test.zig`)
  helpers: they set up a `Font`, `GlyphCache`, arena, hit list, and `Context`.
- Anything time-based **must take `dt` as a parameter** (no `std.time.*` /
  `Date.now` in tested code) so it stays deterministic.

---

## Post-v0 features (implemented)

All of these ship, are headless-tested, and are re-exported from `zigui.zig` /
`components.zig`. The cross-feature integration test in `integration_test.zig`
exercises nav + tabs + sheet + material + a11y together; `examples/showcase`
demos them in a real window. Notes below record *how* each is wired and the
deliberate deviations from the original plan, so you can extend safely.

### Grids — `LazyVGrid` / `LazyHGrid` (composition, no new primitive)
`LazyVGrid(columns, spacing, items, mapFn)` maps `items`→cells, chunks them into
rows, and returns a `VStack` of `HStack`s; `LazyHGrid` is the transpose. Cells get
`.frameMaxWidth()`/`.frameMaxHeight()` for even tracks, and a short final row is
padded with invisible `Empty()` cells so **columns stay aligned**. No `Kind`-level
grid was needed. (`view.zig`; tests `LazyVGrid …`/`LazyHGrid …`.)

### TabView — `Tab` + `TabView` (composition, reuses `.select`)
`TabView(selection: Binding(i64), tabs: []const Tab)` →
`VStack(.{ tabs[sel].content.frameMaxWidth(), Divider(), bar })`. The tab **bar is
a `Picker`** over the tab labels — that reuses `Picker`'s `.select` `HitAction` and
its selected-segment styling for free, so no new interaction was added. The body
switches on the binding; rebuilt each frame.

### Navigation — `NavigationSplitView` + `NavState`/`NavigationLink`/`NavBackButton`
- **Split view:** `NavigationSplitView(sidebar, detail, sidebar_fill: Color)` =
  `HStack(.{ sidebar.frameWidth(220).frameMaxHeight().background(sidebar_fill),
  VDivider(), detail.frameMaxWidth().frameMaxHeight() })`. The fill is a parameter
  because constructors have no theme. **Note:** it uses the new `VDivider` (a rigid
  narrow-width, full-height hairline), *not* `Divider` — a `Divider` is
  flex-width in an `HStack` and would eat half the detail pane.
- **Stack:** `NavState` (app-owned, `TextFieldState` pattern) holds an
  `ArrayList(i64)` route stack with `push/pop/top/depth`. `NavigationLink(label,
  route, nav)` is a `Button` reusing `.callback` — its closure ctx is a
  build-arena `NavPushCtx{nav, route}` (no new `HitAction`). `NavBackButton(label,
  nav)` pops. The body switches on `nav.top()`; render a back button when
  `nav.depth() > 0`.

### Overlays — sheets/alerts/popovers/menus (the one shared-infra phase)
The single-pass paint can't draw on top of everything, so render is split:
- **`renderInto`** = `buildNode→arrange→paint` — *collects* overlay requests and
  a11y nodes into `ctx`'s sinks but does **not** draw overlays.
- **`render`** = `renderInto(root)` **then drains** `ctx.overlays` once. The drain
  loop is index-based, so overlay content that itself presents an overlay (nesting)
  is appended and drained too — each exactly once, no recursion, no double scrim.
- `ScrollView` content and overlay content call **`renderInto`, never `render`** —
  this is the invariant that keeps the drain single-pass. Don't call `render`
  recursively.

`Context` gained `overlays: ?*ArrayList(OverlayReq)` (+ `a11y`, `scale`) as
**defaulted** fields; `Context.init` is unchanged and `initFull` wires the sinks
(so every pre-existing caller compiled untouched — do the same for future sinks).
`.sheet/.alert/.popover(presented, content)` modifiers store an `OverlayMod`
(content boxed in the build arena); when `presented.get()`, `paint` appends an
`OverlayReq{content, style, anchor=outer, dismiss=presented}` instead of drawing
inline. The drain draws a `Color.black.withAlpha(0.2)` scrim, a full-screen
tap-to-dismiss region (action `.toggle` on the dismiss binding — appended *before*
the content's own regions so content taps win), a panel bg, then the content
positioned by style (sheet=bottom, alert=centered, popover=`anchoredRect` near the
anchor). Back-to-front `dispatchTap` gives overlays priority automatically — a
modal scrim correctly blocks taps to the content beneath. `Menu`/`ContextMenu` =
a button/trigger toggling an app-owned `State(bool)` that drives a `.popover` of
item buttons. (There is no `.menu` overlay style; menus use `.popover`.)

### Accessibility — parallel a11y tree (`Context.a11y`; tree only)
`A11yNode{rect, role, label, value}` with `A11yRole{static_text, button, switch_,
slider, text_field, image, header}` (trailing `_` dodges the `switch` keyword).
`emitA11y` in `paintContent` appends one node per meaningful component when the
sink is non-null (Text→static_text, Button→button+label, Toggle→switch_+"on"/"off",
Slider→slider+value, TextField→text, Label→title, Image→image). `.accessibilityLabel`
overrides the label; `.accessibilityHidden(true)` clears `child_ctx.a11y` for the
subtree (drops it and its descendants). The **native platform bridge**
(NSAccessibility / AT-SPI / UIA) that consumes this tree is still a separable
follow-up in `app.zig`/`src/platform/`.

### Materials / blur — `blur_rect` + box blur
`DrawCommand.blur_rect{rect, radius, sigma, tint}` (`canvas.zig`) is implemented in
`raster.zig` as a separable box blur that reads from a **scratch snapshot** of the
affected region (never in place — avoids feedback aliasing), composites `tint`, and
respects the clip stack. `Material{ultra_thin, thin, regular, thick}` → `{tint,
sigma}` via `Material.spec()`; `Fill.material` + `.backgroundMaterial(m)` emit the
blur. Because the rasterizer runs commands in order, a material background frosts
whatever was drawn beneath it (earlier siblings / parent bg), not its own children.
Keep `blur_rect` backend-neutral: a future wgpu backend samples the framebuffer.

### Animation — `src/animation.zig` (dt-injected)
`Easing{linear, ease_in, ease_out, ease_in_out}` + `apply(t)`, `Tween`, and
`Animator{animateTo(state_ptr: *State(f32), target, duration, easing), tick(dt),
active()}`. `tick(dt)` advances `elapsed`, writes the eased value via `State.set`
(which marks subscribers dirty), snaps to the end and drops finished tweens.
**`dt` is a parameter — no wall clock** (determinism). The app loop owns one
`Animator`, exposes it via `app.animator()` for callbacks to start animations, and
when `active()` switches from `SDL_WaitEvent` to `SDL_WaitEventTimeout(&ev, 16)` +
`tick(dt from SDL_GetTicks)` + redraw each frame.

### HiDPI / content scaling — `renderScaled`
`renderScaled(ctx, v, point_rect, scale, canvas)` lays out + paints in **logical
points** (so layout math, theme metrics, and **hit regions stay in points**), then
uniformly scales the produced command list (rects/points/radii/widths/blur sigma ×
scale; glyph & image coverage untouched). The crispness trick: text is drawn with
`font.drawTextScaled`, which rasterizes glyph **coverage at `px*scale`** (device
resolution) but emits the quad in point space; the later ×scale lands the quad on
device pixels mapping 1:1 to the coverage — crisp, not an upscaled blur.
`dispatchTap` therefore operates in **points**, so the app converts/uses logical
mouse coordinates (SDL already reports points) — no conversion needed. `app.zig`
sizes the framebuffer/texture in device pixels (`SDL_GetWindowSizeInPixels`) and
fills the backdrop in pixels (renderScaled only scales the view commands it
appends).

### Streaming-chat additions — wrapped text, app-owned scroll, Enter-submit
Added to support `examples/llm-chat` (a streaming LLM client); all headless-tested.

- **`WrappedText(s)` — width-dependent multi-line text.** A wrapped block's height
  depends on the proposed width, which static `SizingHints` can't express, so the
  pure engine gained a new leaf: `Node.measured{ ctx, measureFn }` whose
  `measure(prop)` is answered by `measureFn` directly (and arranges leaf-like to its
  rect). `WrappedText` lowers to a `.measured` capturing `{face, arena, string, px}`;
  `measureFn` wraps at `prop.width` (reusing `shape.wrapText`) and returns
  `lines·lineHeight`; paint re-wraps at `rect.width` and draws each line via
  `drawTextC` (so HiDPI still works). Use it (not `Text`) for paragraphs/bubbles.
- **`ScrollState` + `ScrollViewState` — app-owned, wheel-driven, auto-followable.**
  `ScrollState{offset, content_h, viewport_h}` (the `TextFieldState` ownership
  pattern) with `maxOffset`/`scrollBy`/`scrollToBottom`/`atBottom`.
  `ScrollViewState(&state, content)` is `ScrollView` but reads `state.offset`;
  `paintScrollState` writes back the measured heights, clamps the offset, and (when
  `Context.scroll_regions` is set) registers a `ScrollRegion`. `dispatchScroll(regions,
  point, dy)` routes a wheel delta to the top-most region under the point (back-to-
  front, like `dispatchTap`). To pin a streaming transcript: set `offset` huge when
  it `atBottom()` — paint clamps it to the new bottom each frame.
- **`.onSubmit(cb)` + `submitFocused()` — Enter-to-send.** `Modifiers.on_submit` is
  stashed onto the focused field's `TextFieldState` during paint, so the event loop
  can fire it on Enter without the view tree (same indirection as focus).
- **`app.zig` wiring** (build-only verified): mouse wheel → `dispatchScroll`; Enter →
  `submitFocused` (ESC still `clearFocus`); a `setBusyCheck(fn)` hook — while it
  returns true (or the animator is active) the loop wakes on a 16 ms timeout and
  rebuilds, so `body` can poll an in-flight socket each frame. New `Context`
  sink `scroll_regions` is defaulted-null (the 137→146 existing tests stayed green).
- **`examples/llm-chat`** is single-threaded: `chat_client.zig` sets the socket
  non-blocking and `body` calls `client.poll()` each frame — no threads, all `State`
  mutation on the UI thread. It speaks OpenAI `/v1/chat/completions` (streaming SSE,
  de-chunking inline; one-shot for `--smoke`). Networking is `@cImport`-ed POSIX (see
  the `std.Io` gotcha above), kept in the example, not the library.
- **`TextField` honors `.cornerRadius(r)`** (else the theme's control radius) so a
  field can be pill-shaped (`.frameHeight(38).cornerRadius(19)`) — the only library
  change for the SwiftUI-style polish; everything else (sidebar rounded-selection
  rows, bordered "New Chat", circular ↑ send button, accent bubbles, centered
  `.alert` settings dialog) is composed from existing primitives in the example.
  Note left-aligning text in a full-width row needs `HStack(.{ v, Spacer() })` — a
  bare `.frameMaxWidth()` centers (frame default alignment). Inter has the arrows/
  punctuation used (↑ ■ × …); verify any new glyph before relying on it.
- **Headless UI iteration**: `llm-chat --screenshot <out.bmp> [--settings]` renders
  one frame of the real `body` to a BMP without a window (libc `fopen`/`fwrite`,
  since `std.fs` needs `std.Io` in 0.16) — `sips -s format png` to view. Build
  examples with **`-Doptimize=ReleaseFast`**: the CPU software rasterizer is ~10×
  slower in the default Debug build, which reads as UI lag.
- **System tray** (`app.Tray`/`app.TrayMenu` in `app.zig`) wraps **SDL3's native
  tray API** (`SDL_tray.h`) → NSStatusItem / Shell_NotifyIcon / StatusNotifierItem,
  so it's cross-platform with no per-OS code. The icon is an `SDL_Surface` built
  from RGBA — `llm-chat` draws its status dot via `Canvas`→`raster`→`toRgba8Alloc`
  (same pipeline as the window). The **menu is OS-drawn and retained** (build once,
  mutate imperatively — not the per-frame view tree): entries are labels/checkboxes/
  submenus/separators with a `zigui.Callback` dispatched through a C-ABI thunk
  (`SDL_TrayCallback`). `app.zig` also gained `Config.hide_on_close` + `showWindow`/
  `hideWindow`/`quit` globals (mirrors `g_animator`) so the close button hides to the
  tray and the loop skips rendering while `SDL_WINDOW_HIDDEN`. Caveat: SDL may invoke
  tray callbacks off the main thread on some platforms (main-thread on macOS) — keep
  them to flipping app-owned state / show-hide-quit.

## Coding conventions
- Readability over cleverness (it's an open-source teaching codebase). Match the
  surrounding comment density and naming. Avoid heavy comptime.
- Colors always go through `multiplyAlpha(ctx.opacity)` when painting.
- New shapes/effects: add a `DrawCommand` and handle it in **both** the software
  rasterizer now and (eventually) the wgpu backend — keep command semantics
  backend-neutral.
- Run `zig build test` after every change; keep it green.
