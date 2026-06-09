# Bundled fonts

## Inter (`Inter.ttf`)

`Inter.ttf` is the **Inter** typeface by Rasmus Andersson, redistributed here
under the **SIL Open Font License, Version 1.1**.

- Project: https://rsms.me/inter/
- License: SIL Open Font License 1.1 (OFL) — full text bundled alongside this
  file as [`OFL.txt`](OFL.txt); also at https://openfontlicense.org

The file shipped here is the variable-font build (`InterVariable.ttf`), renamed
to `Inter.ttf`. zigui reads the default-master outlines from its `glyf` table.

## Noto Emoji (`NotoEmoji.ttf`)

`NotoEmoji.ttf` is the **monochrome** build of Google's **Noto Emoji** font,
redistributed under the **SIL Open Font License, Version 1.1** (same OFL text as
Inter, [`OFL.txt`](OFL.txt)).

- Project: https://github.com/googlefonts/noto-emoji
- License: SIL Open Font License 1.1 (OFL)

It is the variable-weight build (`NotoEmoji[wght].ttf`), renamed to
`NotoEmoji.ttf`; zigui reads the default-master `glyf` outlines. It is wired as a
**fallback face**: codepoints absent from Inter (emoji, and any other glyph it
lacks) resolve here and render through the same outline → coverage-mask path, so
emoji are monochrome and tint with the surrounding text color.

## Lucide icons (`icons.ttf`)

`icons.ttf` is a **subset** of the **Lucide** icon font (the `lucide-static`
build), redistributed under the **ISC License**.

- Project: https://lucide.dev
- License: ISC — full text bundled alongside this file as
  [`LICENSE-lucide`](LICENSE-lucide)

It contains only the ~64 glyphs that `src/icons.zig` exposes, mapped to their
original Lucide Private-Use-Area codepoints. zigui renders them through the same
`glyf` outline → coverage-mask path it uses for text, so icons are tintable and
HiDPI-crisp.

This is a redistributable open font; no Apple assets (SF Pro, SF Symbols, etc.)
are bundled. See the project root `LICENSE` for zigui's own MIT license.
