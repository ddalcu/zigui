//! The bundled icon catalog. `Icon` names a glyph in the subset of the Lucide
//! icon font shipped as `assets/fonts/icons.ttf` (see `assets/fonts/NOTICE.md`
//! for licensing). Each tag's integer value is the glyph's codepoint in the
//! font's Private Use Area, so rendering an icon is just `glyphIndex(codepoint)`
//! through the ordinary text path — icons are tintable and HiDPI-crisp for free.
//!
//! Use them via the `Icon`/`IconButton` view constructors in `view.zig`, e.g.
//! `Icon(.heart, 18, theme.colors.accent)` or `IconButton(.trash, 18, onTap)`.
//! Enum-literal inference means call sites rarely spell `Icon` out — `.heart`
//! resolves against the parameter type.
//!
//! Regenerate (font + this enum) from /tmp/zigui-icons via the subset script;
//! `assets/fonts/icons-rows.json` records the [zig_name, lucide_name, codepoint]
//! rows the build was generated from.

const std = @import("std");

/// A glyph in the bundled icon font. The value is its PUA codepoint.
pub const Icon = enum(u21) {
    /// lucide `circle-alert`
    alert = 0xE077,
    /// lucide `arrow-down`
    arrow_down = 0xE042,
    /// lucide `arrow-left`
    arrow_left = 0xE048,
    /// lucide `arrow-right`
    arrow_right = 0xE049,
    /// lucide `arrow-up`
    arrow_up = 0xE04A,
    /// lucide `audio-lines`
    audio_lines = 0xE55A,
    /// lucide `badge-check`
    badge_check = 0xE241,
    /// lucide `bell`
    bell = 0xE059,
    /// lucide `bookmark`
    bookmark = 0xE060,
    /// lucide `boxes`
    boxes = 0xE2D0,
    /// lucide `calendar`
    calendar = 0xE063,
    /// lucide `check`
    check = 0xE06C,
    /// lucide `chevron-down`
    chevron_down = 0xE06D,
    /// lucide `chevron-left`
    chevron_left = 0xE06E,
    /// lucide `chevron-right`
    chevron_right = 0xE06F,
    /// lucide `chevron-up`
    chevron_up = 0xE070,
    /// lucide `clock`
    clock = 0xE087,
    /// lucide `x`
    close = 0xE1B2,
    /// lucide `copy`
    copy = 0xE09E,
    /// lucide `cpu`
    cpu = 0xE0A9,
    /// lucide `download`
    download = 0xE0B2,
    /// lucide `pencil`
    edit = 0xE1F9,
    /// lucide `eye`
    eye = 0xE0BA,
    /// lucide `eye-off`
    eye_off = 0xE0BB,
    /// lucide `file`
    file = 0xE0C0,
    /// lucide `film`
    film = 0xE0D0,
    /// lucide `folder`
    folder = 0xE0D7,
    /// lucide `hard-drive`
    hard_drive = 0xE0ED,
    /// lucide `heart`
    heart = 0xE0F2,
    /// lucide `circle-help`
    help = 0xE082,
    /// lucide `house`
    home = 0xE0F5,
    /// lucide `image`
    image = 0xE0F6,
    /// lucide `info`
    info = 0xE0F9,
    /// lucide `list`
    list = 0xE106,
    /// lucide `loader`
    loader = 0xE109,
    /// lucide `lock`
    lock = 0xE10B,
    /// lucide `mail`
    mail = 0xE10F,
    /// lucide `menu`
    menu = 0xE115,
    /// lucide `message-circle`
    message_circle = 0xE116,
    /// lucide `minus`
    minus = 0xE11C,
    /// lucide `moon`
    moon = 0xE11E,
    /// lucide `ellipsis`
    more_horizontal = 0xE0B6,
    /// lucide `ellipsis-vertical`
    more_vertical = 0xE0B7,
    /// lucide `pause`
    pause = 0xE12E,
    /// lucide `play`
    play = 0xE13C,
    /// lucide `plus`
    plus = 0xE13D,
    /// lucide `refresh-cw`
    refresh = 0xE145,
    /// lucide `scroll-text`
    scroll_text = 0xE45F,
    /// lucide `search`
    search = 0xE151,
    /// lucide `send`
    send = 0xE152,
    /// lucide `settings`
    settings = 0xE154,
    /// lucide `share-2`
    share = 0xE156,
    /// lucide `shield-check`
    shield_check = 0xE1FF,
    /// lucide `sparkles`
    sparkles = 0xE412,
    /// lucide `star`
    star = 0xE176,
    /// lucide `sun`
    sun = 0xE178,
    /// lucide `trash-2`
    trash = 0xE18E,
    /// lucide `lock-open`
    unlock = 0xE10C,
    /// lucide `upload`
    upload = 0xE19E,
    /// lucide `user`
    user = 0xE19F,
    /// lucide `users`
    users = 0xE1A4,
    /// lucide `volume-2`
    volume = 0xE1AB,
    /// lucide `wand-2`
    wand = 0xE357,
    /// lucide `zap`
    zap = 0xE1B4,

    /// The font codepoint this icon maps to.
    pub fn codepoint(self: Icon) u21 {
        return @intFromEnum(self);
    }
};

test "icons: every tag maps into the Private Use Area" {
    for (std.enums.values(Icon)) |ic| {
        const cp = ic.codepoint();
        try std.testing.expect(cp >= 0xE000 and cp <= 0xF8FF);
    }
}
