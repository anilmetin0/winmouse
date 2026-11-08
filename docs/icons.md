# Icons

The existing WinMouse mark in `docs/assets/icon.svg` is the canonical app icon. The small-size
variant in `icon-small.svg` keeps its shape and colors but removes the desk grid and strengthens
the wheel and dividers at 16/32 points. The macOS iconset includes 1x and 2x variants at the
standard 16, 32, 128, 256 and 512 point sizes.

Regenerate the shared PNGs and macOS package on macOS:

```sh
swift scripts/build-icons.swift
iconutil -c icns build/WinMouse.iconset -o Resources/AppIcon.icns
```

AppKit renders the SVGs; no image package is installed. `Info.plist` references `AppIcon.icns`.
The update window and error helper use this app icon. The menu bar uses Apple's native
`computermouse` SF Symbol as an 18-point template image, so macOS supplies the light/dark tint.
The update action uses `arrow.triangle.2.circlepath`.

The landing's `brand/icon.svg`, header PNGs, README image, favicon and touch icon use the same
mark. Its Apple silhouette comes from [Simple Icons](https://cdn.simpleicons.org/apple), under
[CC0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md), and identifies the
macOS download. Inline SVG uses `currentColor`, so it follows each theme without a font glyph.
The favicon crops the small mark to its tile for legibility at 16 pixels and uses versioned URLs to refresh the browser cache.

Native icon guidance: [Apple HIG, App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
and [Menu bar extras](https://developer.apple.com/design/human-interface-guidelines/menu-bar-extras).
