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
    // `-Dsdl3-prefix=<dir>` (with `include/` and `lib/`) points at an SDL3 install
    // anywhere — the way to build for Windows or against a self-built SDL.
    const sdl3_prefix = b.option([]const u8, "sdl3-prefix", "SDL3 install prefix (include/ and lib/ inside)");
    addExample(b, mod, target, optimize, sdl3_prefix, "showcase", "examples/showcase/main.zig");
    addExample(b, mod, target, optimize, sdl3_prefix, "edit", "examples/edit/main.zig");
}

/// Build a runnable example that links the SDL3-backed runtime (`src/app.zig`).
fn addExample(
    b: *std.Build,
    zigui_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl3_prefix: ?[]const u8,
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
    linkSdl3(b, app_mod, sdl_c, sdl3_prefix);
    // app.zig reaches AppKit (unified titlebar, menu bar, template tray icons)
    // through the Objective-C runtime.
    if (target.result.os.tag == .macos) app_mod.linkSystemLibrary("objc", .{});

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

/// Wire up SDL3 headers/libs. On a macOS build host, point at the Homebrew
/// prefix matching the host arch (Apple Silicon → /opt/homebrew, Intel →
/// /usr/local). On Linux the system linker / pkg-config finds SDL3.
/// An explicit `-Dsdl3-prefix` overrides both.
fn linkSdl3(b: *std.Build, m: *std.Build.Module, tc: *std.Build.Step.TranslateC, override: ?[]const u8) void {
    const host = @import("builtin");
    const prefix: ?[]const u8 = override orelse if (host.os.tag == .macos)
        (if (host.cpu.arch == .aarch64) "/opt/homebrew/opt/sdl3" else "/usr/local/opt/sdl3")
    else
        null;
    if (prefix) |p| {
        m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
        m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        m.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        tc.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
    }
    m.linkSystemLibrary("SDL3", .{});
}
