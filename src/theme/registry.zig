//! Theme registry: the catalog of built-in theme families and the logic that
//! resolves one to a concrete `Theme` for the current OS color scheme.
//!
//! A *family* (macOS, Windows 10, …) ships a light and a dark palette.
//! `forScheme` picks the right one, so the app can wire the OS appearance
//! (`app.systemTheme()`) straight through.

const std = @import("std");
const theme = @import("theme.zig");
const macos = @import("macos.zig");
const win2000 = @import("win2000.zig");
const windows10 = @import("windows10.zig");
const kde = @import("kde.zig");
const mui = @import("mui.zig");

const Theme = theme.Theme;
const ColorScheme = theme.ColorScheme;

/// The built-in theme families.
pub const Family = enum {
    macos,
    windows10,
    win2000,
    kde,
    mui,

    /// A human-readable name for menus/switchers.
    pub fn displayName(self: Family) []const u8 {
        return switch (self) {
            .macos => "macOS",
            .windows10 => "Windows 10",
            .win2000 => "Windows 2000",
            .kde => "KDE Plasma",
            .mui => "Material",
        };
    }
};

/// Resolve a family to a concrete `Theme` for `scheme`.
pub fn forScheme(family: Family, scheme: ColorScheme) Theme {
    const dark = scheme == .dark;
    return switch (family) {
        .macos => if (dark) macos.dark else macos.light,
        .windows10 => if (dark) windows10.dark else windows10.light,
        .win2000 => if (dark) win2000.dark else win2000.light,
        .kde => if (dark) kde.dark else kde.light,
        .mui => if (dark) mui.dark else mui.light,
    };
}

/// All families, in display order (handy for building a theme switcher).
pub const all = [_]Family{ .macos, .windows10, .win2000, .kde, .mui };

const testing = std.testing;

test "registry: every family has a dark palette" {
    for (all) |f| try testing.expectEqual(ColorScheme.dark, forScheme(f, .dark).scheme);
}

test "registry: macOS follows the requested scheme" {
    try testing.expectEqual(ColorScheme.dark, forScheme(.macos, .dark).scheme);
    try testing.expectEqual(ColorScheme.light, forScheme(.macos, .light).scheme);
}

test "registry: every family resolves and names itself" {
    for (all) |f| {
        const t = forScheme(f, .light);
        try testing.expect(t.name.len > 0);
        try testing.expect(f.displayName().len > 0);
    }
}
