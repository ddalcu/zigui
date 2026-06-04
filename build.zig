const std = @import("std");

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
    // Bundle the default font (Inter, OFL) as an embeddable blob, importable as
    // `@embedFile("inter_font")` from anywhere in the module.
    mod.addAnonymousImport("inter_font", .{
        .root_source_file = b.path("assets/fonts/Inter.ttf"),
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
    addExample(b, mod, target, optimize, "hello", "examples/hello/main.zig");
    addExample(b, mod, target, optimize, "settings", "examples/settings/main.zig");
    addExample(b, mod, target, optimize, "showcase", "examples/showcase/main.zig");
    addExample(b, mod, target, optimize, "llm-chat", "examples/llm-chat/main.zig");
    addExample(b, mod, target, optimize, "edit", "examples/edit/main.zig");

    // A headless screenshot tool: renders a UI to a BMP using *only* the pure
    // `zigui` module + libc (no SDL), so CI can produce a per-OS screenshot on
    // every platform. Not an `addExample` (those link SDL3).
    const screenshot = b.addExecutable(.{
        .name = "screenshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/screenshot/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // for the libc BMP writer (std.fs needs std.Io in 0.16)
            .imports = &.{.{ .name = "zigui", .module = mod }},
        }),
    });
    const screenshot_install = b.addInstallArtifact(screenshot, .{});
    b.step("screenshot", "Build the headless screenshot tool")
        .dependOn(&screenshot_install.step);
    const screenshot_run = b.addRunArtifact(screenshot);
    screenshot_run.step.dependOn(&screenshot_install.step);
    if (b.args) |args| screenshot_run.addArgs(args);
    b.step("run-screenshot", "Render a UI screenshot to a BMP (pass the path: -- out.bmp)")
        .dependOn(&screenshot_run.step);
}

/// Build a runnable example that links the SDL3-backed runtime (`src/app.zig`).
fn addExample(
    b: *std.Build,
    zigui_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_path: []const u8,
) void {
    // The SDL-linking runtime module.
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zigui", .module = zigui_mod }},
    });
    linkSdl3(app_mod);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_path),
            .target = target,
            .optimize = optimize,
            // libc so examples can `@cImport` POSIX headers directly (e.g. the
            // llm-chat socket client); the SDL runtime needs it regardless.
            .link_libc = true,
            .imports = &.{
                .{ .name = "zigui", .module = zigui_mod },
                .{ .name = "zigui_app", .module = app_mod },
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
fn linkSdl3(m: *std.Build.Module) void {
    const host = @import("builtin");
    if (host.os.tag == .macos) {
        const prefix = if (host.cpu.arch == .aarch64)
            "/opt/homebrew/opt/sdl3"
        else
            "/usr/local/opt/sdl3";
        m.addIncludePath(.{ .cwd_relative = prefix ++ "/include" });
        m.addLibraryPath(.{ .cwd_relative = prefix ++ "/lib" });
        m.addRPath(.{ .cwd_relative = prefix ++ "/lib" });
    }
    m.linkSystemLibrary("SDL3", .{});
}
