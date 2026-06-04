# zigui

A cross-platform, declarative UI library written in **pure Zig** that brings a
native macOS / SwiftUI look and feel to macOS, Linux, and Windows.

> Status: pre-alpha, but a usable toolkit. See [PRD.md](PRD.md) for the full
> design & roadmap.

## Screenshots

| Settings demo | Showcase (nav · tabs · sheet · material) | Streaming LLM chat |
|---|---|---|
| ![Settings](docs/settings.png) | ![Showcase](docs/showcase.png) | ![LLM chat](docs/llm-chat.png) |

All three are the **same pure-Zig renderer** — no native widgets.

## Why

SwiftUI is the gold standard for ergonomic, good-looking native UI — but it is
Apple-only and closed. `zigui` delivers a SwiftUI-like developer experience and
macOS-like visual design on every desktop OS, using its **own rendering
pipeline** rather than wrapping native platform widgets. The same engine draws
on every platform, so output is identical everywhere.

## Hello, zigui

```zig
const zigui = @import("zigui");

fn body(st: *AppState) zigui.View {
    return zigui.VStack(.{
        zigui.Text("Hello, zigui!").font(.large_title),
        zigui.Text(zigui.components.fmt("Count: {d}", .{st.count.get()}))
            .foreground(zigui.default_theme.colors.secondary_label),
        zigui.Button("Increment", zigui.actionCtx(AppState, st, AppState.inc)),
    }).spacing(16).padding(40);
}
```

## Components

Layout: `VStack` `HStack` `ZStack` `Spacer` `Divider` `ScrollView` `List`
`ForEach` · Text/Media: `Text` `Label` `Image` `TextField` `TextEditor` ·
Controls: `Button` `Toggle` `Slider` `Stepper` `ProgressView` · Shapes:
`Rectangle` `RoundedRectangle` `Circle` `Capsule` `Ellipse` `LinearGradient`.

`TextEditor` is a multi-line, scrollable plain-text editor: line numbers, a
click-positionable caret, selection (mouse drag or Shift+arrows / Select-All),
tab stops, and wheel + caret-follow scrolling. See the [`edit`](examples/edit)
example.

Modifiers chain fluently: `.padding()` `.frame()` `.background()`
`.foreground()` `.font()` `.cornerRadius()` `.border()` `.opacity()` `.onTap()`
`.disabled()` `.frameMaxWidth()` …

## Architecture at a glance

| Layer | Choice |
|---|---|
| API style | comptime/value declarative tree with fluent modifiers |
| State | observable `State(T)` + `Binding(T)` + dirty flag |
| Layout | two-pass measure/arrange engine (SwiftUI-style proposals) |
| Text | bundled Inter (OFL) + pure-Zig TrueType rasterizer + glyph cache |
| Theme | macOS light/dark, fully tokenized |
| 2D drawing | retained `Canvas` command list |
| Renderer (tests / headless) | **pure-Zig software rasterizer** (SDF anti-aliasing) |
| Renderer (on-screen) | software rasterizer presented via **SDL3** |
| Windowing / input | **SDL3** |

The **core** (geometry, color, state, layout, theme, view tree, text, canvas,
software rasterizer, components) is pure Zig with **no C dependencies** — the
entire test suite runs headless on macOS, Linux, and Windows.

> **Renderer note.** zigui rasterizes on the CPU and presents the framebuffer
> through SDL3 — a real, working, identical-everywhere renderer. A wgpu GPU
> backend is **not currently planned** (the SDL3 path works well); because all
> drawing is expressed as a `Canvas` command list, one could still be slotted in
> later behind the same interface without touching any component.

## Use zigui in your project

zigui is distributed through Zig's built-in package manager — there's no central
registry, just a URL fetched and content-hashed into your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/ddalcu/zigui#v0.1.0
```

Then wire the module in your `build.zig`:

```zig
const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zigui", zigui_dep.module("zigui"));
```

and `const zigui = @import("zigui");` in your code. The `zigui` module is **pure
Zig with no C dependencies** (the bundled Inter font travels with it). To put
pixels on screen, pair it with your own windowing/present loop, or start from the
SDL3 backend in [`src/app.zig`](src/app.zig) — SDL3 is only needed for display.

## Build & test

```sh
zig build test            # full test suite (headless — no GPU/window needed)
zig build test --summary all
zig build docs            # API docs into zig-out/docs
```

Run the demo apps (require SDL3 — `brew install sdl3` on macOS,
`apt install libsdl3-dev` on Linux):

```sh
zig build run-hello                  # minimal counter
zig build run-settings               # macOS-like Settings demo
zig build run-showcase               # nav · tabs · sheet · material · a11y
zig build run-llm-chat               # streaming chat over an OpenAI-compatible API
zig build run-edit                   # a multi-line text editor (TextEdit/gedit-like)
zig build hello settings showcase llm-chat edit   # build the examples without running them
```

> Run with `-Doptimize=ReleaseFast` for smooth UI — the CPU software rasterizer
> is much slower in the default Debug build. The `llm-chat` demo talks to a local
> OpenAI-compatible server (e.g. `mlx-serve --serve --model <model> --port 11234`);
> see [`examples/llm-chat`](examples/llm-chat).

### Validate on Linux via Docker

```sh
docker build -t zigui-test .   # downloads Zig, runs the full suite on Linux
```

Requires Zig 0.16.0+.

## Extending zigui

Adding a component or one of the planned features (navigation, tabs, modals,
grids, animation, materials/blur, accessibility, HiDPI)? See
**[CLAUDE.md](CLAUDE.md)** — it documents the architecture, the build/test
gotchas, the "add a component" recipe, and a concrete implementation plan (with
the exact code seams) for each deferred feature.

## License

MIT (see [LICENSE](LICENSE)). The bundled font **Inter** is under the SIL Open
Font License (see [assets/fonts/NOTICE.md](assets/fonts/NOTICE.md)). No Apple
assets are redistributed.
