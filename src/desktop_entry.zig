//! Values for a freedesktop desktop entry (`.desktop` file), escaped per the
//! Desktop Entry Specification, so a path with spaces, quotes, `$`, `%` or
//! backslashes in it means what it says. Pure; `app.zig`'s
//! `installDesktopEntry` and `desktopEntryState` write and read with it.

const std = @import("std");

/// A value of type string: a backslash is written `\\`. Null when `text` holds
/// a control character (a newline would end the line, and the entry with it).
///
/// - `buf`: where the value is written.
/// - `text`: the raw value (a path, a name).
/// - Returns: the escaped value, in `buf`; null for a control character or
///   when `buf` is too small.
pub fn stringValue(buf: []u8, text: []const u8) ?[]const u8 {
    var w = Writer{ .buf = buf };
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return null;
        if (byte == '\\') w.put("\\\\") else w.put(&.{byte});
    }
    return w.done();
}

/// An `Exec` value that runs `program` with one argument, the file opened
/// (`%f`), or none when `with_file` is false. The program is quoted, with
/// the characters the spec reserves inside quotes (`"`, `` ` ``, `$`, `\`)
/// escaped by a backslash, and then the string rule applied on top (each of
/// those backslashes, and a literal one, doubled again: a backslash in the
/// path becomes four). A `%` is written `%%`, so no field code is read in
/// the path. Null when `program` holds a control character, which no
/// escape represents inside quotes.
///
/// - `buf`: where the value is written.
/// - `program`: the executable's absolute path.
/// - `with_file`: add the `%f` field code, so a file or folder can be opened with it.
/// - Returns: the value, in `buf`; null for a control character or when
///   `buf` is too small.
pub fn execValue(buf: []u8, program: []const u8, with_file: bool) ?[]const u8 {
    var w = Writer{ .buf = buf };
    w.put("\"");
    for (program) |byte| {
        if (byte < 0x20 or byte == 0x7f) return null;
        switch (byte) {
            // Quoting rule (`\x`), then the string rule doubles the backslash.
            '"', '`', '$' => {
                w.put("\\\\");
                w.put(&.{byte});
            },
            '\\' => w.put("\\\\\\\\"),
            '%' => w.put("%%"),
            else => w.put(&.{byte}),
        }
    }
    w.put("\"");
    if (with_file) w.put(" %f");
    return w.done();
}

/// Appends into a fixed buffer, remembering whether it ran out.
const Writer = struct {
    buf: []u8,
    len: usize = 0,
    full: bool = false,

    fn put(self: *Writer, bytes: []const u8) void {
        if (self.full or self.len + bytes.len > self.buf.len) {
            self.full = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn done(self: *const Writer) ?[]const u8 {
        return if (self.full) null else self.buf[0..self.len];
    }
};

test "a plain path is quoted and left alone" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\"/opt/My App/bin/app\"", execValue(&buf, "/opt/My App/bin/app", false).?);
    try std.testing.expectEqualStrings("\"/usr/bin/app\" %f", execValue(&buf, "/usr/bin/app", true).?);
}

test "reserved characters are escaped twice, and % is doubled" {
    var buf: [256]u8 = undefined;
    // In the file: a quote is \\" , a dollar \\$ , a backtick \\` , a backslash
    // \\\\ (four), and a percent %%.
    try std.testing.expectEqualStrings("\"/a\\\\\"b\\\\$c\\\\`d\\\\\\\\e%%f\"", execValue(&buf, "/a\"b$c`d\\e%f", false).?);
}

test "a control character or a short buffer is refused" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(null, execValue(&buf, "/a\nb", false));
    try std.testing.expectEqual(null, stringValue(&buf, "x\ty"));
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqual(null, execValue(&tiny, "/usr/bin/app", false));
}

test "a string value doubles its backslashes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\\\icons\\\\app.png", stringValue(&buf, "C:\\icons\\app.png").?);
    try std.testing.expectEqualStrings("/home/me/.local/share/icons/app.png", stringValue(&buf, "/home/me/.local/share/icons/app.png").?);
}
