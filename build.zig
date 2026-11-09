const std = @import("std");
// The package manifest is the single source of truth for the version. Read it
// here and inject it into the module (below) as `build_options.version`, so
// `zigui.version` always matches `build.zig.zon` and the `zig fetch` tag.
const manifest = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core library module: pure Zig, no C dependencies. This is what the
    // test suite exercises, so the entire foundation runs headless and inside
    // Docker on Linux without a GPU or window server.
    const mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/zigui.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Inject the manifest version so `zigui.version` derives from build.zig.zon.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);
    mod.addImport("build_options", options.createModule());
    // Bundle the default font (Inter, OFL) as an embeddable blob, importable as
    // `@embedFile("inter_font")` from anywhere in the module.
    mod.addAnonymousImport("inter_font", .{
        .root_source_file = b.path("assets/fonts/Inter.ttf"),
    });
    // The other Inter weights/italics and JetBrains Mono (both OFL) behind
    // `FontSet`, which picks a face per view weight/italic/mono.
    for ([_][2][]const u8{
        .{ "inter_medium", "Inter-Medium.ttf" },
        .{ "inter_semibold", "Inter-SemiBold.ttf" },
        .{ "inter_bold", "Inter-Bold.ttf" },
        .{ "inter_italic", "Inter-Italic.ttf" },
        .{ "inter_bold_italic", "Inter-BoldItalic.ttf" },
        .{ "mono_regular", "JetBrainsMono-Regular.ttf" },
        .{ "mono_bold", "JetBrainsMono-Bold.ttf" },
    }) |f| mod.addAnonymousImport(f[0], .{ .root_source_file = b.path(b.fmt("assets/fonts/{s}", .{f[1]})) });
    // Bundle the icon font (the full Lucide set, ISC) the same way, importable as
    // `@embedFile("icon_font")`. See `src/icons.zig` and `assets/fonts/NOTICE.md`.
    mod.addAnonymousImport("icon_font", .{
        .root_source_file = b.path("assets/fonts/lucide.ttf"),
    });
    // Bundle the monochrome emoji fallback font (Noto Emoji, OFL), importable as
    // `@embedFile("emoji_font")`. Wired as a fallback face for glyphs Inter
    // lacks; see `assets/fonts/NOTICE.md`.
    mod.addAnonymousImport("emoji_font", .{
        .root_source_file = b.path("assets/fonts/NotoEmoji.ttf"),
    });

    // ---- tests ------------------------------------------------------------
    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run the zigui test suite");
    test_step.dependOn(&run_lib_tests.step);

    // ---- docs (optional) --------------------------------------------------
    const docs_step = b.step("docs", "Generate library documentation");
    const docs = b.addObject(.{ .name = "zigui", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // ---- examples (link SDL3; not part of `zig build test`) ---------------
    // `showcase` is the kitchen-sink gallery (every component + light/dark and
    // accent switchers); `edit` is the multi-line text editor. Both support a
    // headless `--screenshot <out.bmp>` flag for windowless rendering.
    // SDL3 is built from source as a lazy Zig package (see `linkSdl3`);
    // `-Dsdl3-prefix=<dir>` (with `include/` and `lib/`) links a prebuilt one.
    // `-Dmacos-sdk=$(xcrun --show-sdk-path)` is needed whenever macOS is an
    // explicit `-Dtarget` (Zig then treats it as a cross build and won't probe
    // the host SDK for AppKit/Metal).
    const sdl3_prefix = b.option([]const u8, "sdl3-prefix", "SDL3 install prefix (include/ and lib/ inside)");
    const macos_sdk = b.option([]const u8, "macos-sdk", "macOS SDK path for explicit macOS targets (xcrun --show-sdk-path)");
    // Windows executables are GUI-subsystem by default so launching one
    // doesn't open a console window; `-Dwindows-console` keeps the console
    // (log output, `--screenshot` messages) for debugging.
    const windows_console = b.option(bool, "windows-console", "Build Windows examples as console apps (shows log output)") orelse false;
    const sdl: SdlConfig = .{ .prefix = sdl3_prefix, .macos_sdk = macos_sdk, .windows_console = windows_console };
    // The examples only when zigui is the root build: a package that depends
    // on zigui reaches SDL through `linkApp` alone, so `b.dependency("zigui")`
    // never fetches or builds SDL for a consumer that draws no window.
    if (b.dep_prefix.len == 0) {
        addExample(b, mod, target, optimize, sdl, "showcase", "examples/showcase/main.zig");
        addExample(b, mod, target, optimize, sdl, "edit", "examples/edit/main.zig");
    }
}

/// What `linkApp` builds the SDL runtime for.
pub const AppOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// The macOS SDK root (`xcrun --show-sdk-path`), needed whenever macOS is
    /// an explicit `-Dtarget`; null lets Zig probe the host's.
    macos_sdk: ?[]const u8 = null,
    /// A prebuilt SDL3 (`include/` and `lib/` inside) instead of the package.
    sdl3_prefix: ?[]const u8 = null,
};

/// The SDL3-backed runtime (`src/app.zig`) for a package that depends on
/// zigui: import the result as `zigui_app` beside `dep.module("zigui")` (the
/// same core module it imports, so the two agree on every type). It links
/// SDL3 (fetched lazily, on first use), libc and, on macOS, the Objective-C
/// runtime. On the first configure SDL may not be fetched yet: the module is
/// returned unlinked and the build reruns once the package is there.
///
///     const zigui_dep = b.dependency("zigui", .{ .target = target, .optimize = optimize });
///     const app_mod = @import("zigui").linkApp(zigui_dep, .{ .target = target, .optimize = optimize });
///     exe.root_module.addImport("zigui", zigui_dep.module("zigui"));
///     exe.root_module.addImport("zigui_app", app_mod);
pub fn linkApp(dep: *std.Build.Dependency, opts: AppOptions) *std.Build.Module {
    const b = dep.builder;
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigui", .module = dep.module("zigui") }},
    });
    app_mod.addImport("sdl_c", sdl_c.createModule());
    const sdl: SdlConfig = .{ .prefix = opts.sdl3_prefix, .macos_sdk = opts.macos_sdk, .windows_console = false };
    linkSdl3(b, app_mod, sdl_c, opts.target, opts.optimize, sdl);
    if (opts.target.result.os.tag == .macos) {
        if (opts.macos_sdk) |sdk| addMacosSdk(b, app_mod, sdk);
        app_mod.linkSystemLibrary("objc", .{});
    }
    return app_mod;
}

/// Where SDL3 and (for explicit macOS targets) the system SDK come from.
const SdlConfig = struct {
    prefix: ?[]const u8,
    macos_sdk: ?[]const u8,
    windows_console: bool,
};

/// Build a runnable example that links the SDL3-backed runtime (`src/app.zig`).
fn addExample(
    b: *std.Build,
    zigui_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: SdlConfig,
    name: []const u8,
    root_path: []const u8,
) void {
    // The SDL-linking runtime module. SDL's headers come in through translate-c
    // (`@cImport` is gone in Zig 0.17), importable as `sdl_c`.
    const sdl_c = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl_c.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigui", .module = zigui_mod }},
    });
    app_mod.addImport("sdl_c", sdl_c.createModule());
    linkSdl3(b, app_mod, sdl_c, target, optimize, sdl);
    // app.zig reaches AppKit (unified titlebar, menu bar, template tray icons)
    // through the Objective-C runtime.
    if (target.result.os.tag == .macos) {
        if (sdl.macos_sdk) |sdk| addMacosSdk(b, app_mod, sdk);
        app_mod.linkSystemLibrary("objc", .{});
    }

    // libc headers the examples use (stdio/time), via translate-c as `cstdio`.
    const cstdio = b.addTranslateC(.{
        .root_source_file = b.path("examples/cstdio.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_path),
            .target = target,
            .optimize = optimize,
            // libc so examples can use POSIX headers directly (`cstdio`);
            // the SDL runtime needs it regardless.
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = zigui_mod },
                .{ .name = "zigui_app", .module = app_mod },
                .{ .name = "cstdio", .module = cstdio.createModule() },
            },
        }),
    });
    // The app icon (assets/icon, generated by tools/icon/mkico.py): the PNG is
    // importable as `@embedFile("app_icon")` for `Config.icon_png` (window /
    // Dock icon on macOS and Linux); on Windows the multi-size .ico is also
    // embedded as a resource for Explorer, the title bar and the taskbar.
    exe.root_module.addAnonymousImport("app_icon", .{ .root_source_file = b.path("assets/icon/zigz.png") });
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/icon/zigui.rc") });
        if (!sdl.windows_console) exe.subsystem = .windows;
    }
    const install = b.addInstallArtifact(exe, .{});

    // `zig build <name>` builds (and installs) the example.
    const build_step = b.step(name, b.fmt("Build the '{s}' example", .{name}));
    build_step.dependOn(&install.step);

    // `zig build run-<name>` builds then launches it (opens a window).
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&install.step);
    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the '{s}' example", .{name}));
    run_step.dependOn(&run_cmd.step);
}

/// Wire up SDL3. By default SDL3 is built from source as a Zig package
/// (castholm/SDL, pinned in build.zig.zon) and linked statically, so the
/// examples need nothing installed beyond the Zig toolchain. The dependency is
/// lazy: `zig build test` never fetches or compiles it.
/// `-Dsdl3-prefix=<dir>` (with `include/` and `lib/`) links a prebuilt SDL3
/// install instead — e.g. a self-built SDL, or a distro package on Linux.
fn linkSdl3(
    b: *std.Build,
    m: *std.Build.Module,
    tc: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl: SdlConfig,
) void {
    if (sdl.prefix) |p| {
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        m.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        tc.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        m.linkSystemLibrary("SDL3", .{});
        return;
    }
    const sdl_dep = if (sdl.macos_sdk) |sdk| b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        .system_include_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) },
        .system_framework_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) },
        .library_path = std.Build.LazyPath{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) },
    }) else b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
    });
    // First pass: the package is fetched, then build() reruns.
    const dep = sdl_dep orelse return;
    const sdl_lib = dep.artifact("SDL3");
    m.linkLibrary(sdl_lib);
    tc.addIncludePath(sdl_lib.getEmittedIncludeTree());
}

/// Point a module at a macOS SDK's headers, frameworks and libraries (the
/// `-Dmacos-sdk` path), which Zig doesn't probe for an explicit macOS target.
fn addMacosSdk(b: *std.Build, m: *std.Build.Module, sdk: []const u8) void {
    m.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk}) });
    m.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
}
