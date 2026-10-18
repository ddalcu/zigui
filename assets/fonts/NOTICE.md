# Bundled fonts

## Inter (`Inter.ttf`)

`Inter.ttf` is the **Inter** typeface by Rasmus Andersson, redistributed here
under the **SIL Open Font License, Version 1.1**.

- Project: https://rsms.me/inter/
- License: SIL Open Font License 1.1 (OFL) — full text bundled alongside this
  file as [`OFL.txt`](OFL.txt); also at https://openfontlicense.org

The file shipped here is the variable-font build (`InterVariable.ttf`), renamed
to `Inter.ttf`. zigui reads the default-master outlines from its `glyf` table.
The static `Inter-Medium`, `-SemiBold`, `-Bold`, `-Italic` and `-BoldItalic`
cuts (same license) back the weight/italic faces in `FontSet`.

## JetBrains Mono (`JetBrainsMono-Regular.ttf`, `JetBrainsMono-Bold.ttf`)

The monospace face for code, by JetBrains, under the **SIL Open Font License,
Version 1.1** — full text in [`OFL-JetBrainsMono.txt`](OFL-JetBrainsMono.txt).

- Project: https://www.jetbrains.com/lp/mono/

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

## Lucide icons (`lucide.ttf`)

`lucide.ttf` is the **Lucide** icon font (the `lucide-static` build),
redistributed under the **ISC License**.

- Project: https://lucide.dev
- License: ISC — full text bundled alongside this file as
  [`LICENSE-lucide`](LICENSE-lucide)

Every glyph is exposed by `src/icons.zig` under its original Lucide
Private-Use-Area codepoint. zigui renders them through the same
`glyf` outline → coverage-mask path it uses for text, so icons are tintable and
HiDPI-crisp.

This is a redistributable open font; no Apple assets (SF Pro, SF Symbols, etc.)
are bundled. See the project root `LICENSE` for zigui's own MIT license.
