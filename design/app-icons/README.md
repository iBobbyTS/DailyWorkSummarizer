# DeskBrief App Icon Assets

This directory keeps the app icon source files, generated candidates, and conversion records used while preparing the DeskBrief macOS icon.

## Current packaged icon

- `deskbrief-icon-dark-source.png` is the current source image used to generate `DeskBrief/Assets.xcassets/AppIcon.appiconset`.
- `deskbrief-icon-light-source.png` is kept as the light-mode source candidate for future Icon Composer work.

## Deterministic vector candidates

- `deskbrief-icon-dark-vector.svg`
- `deskbrief-icon-dark-vector.png`
- `deskbrief-icon-light-vector.svg`
- `deskbrief-icon-light-vector.png`

The vector candidates use two logical SVG layers:

- `screen-and-chart-layer`: monitor, screen, and six fixed-position bars.
- `foreground-screenshot-layer`: screenshot cards drawn over the screen layer.

The PNG files are rendered from SVG with ImageMagick:

```sh
magick -background none design/app-icons/deskbrief-icon-dark-vector.svg -resize 1024x1024 design/app-icons/deskbrief-icon-dark-vector.png
magick -background none design/app-icons/deskbrief-icon-light-vector.svg -resize 1024x1024 design/app-icons/deskbrief-icon-light-vector.png
```

## AI generation records

- `generated-records/codex-generated-images-full/` is a full copy of the local Codex generated image directory at the time these icon assets were committed.
- `generated-records/codex-generated-images/` keeps the primary conversation image outputs from the shared Codex generation directory.

The generated records are intentionally kept in the repository so prior logo attempts can be inspected without relying on files under `$CODEX_HOME`.

## AppIcon conversion

The current app icon set is generated from `deskbrief-icon-dark-source.png`:

```sh
magick design/app-icons/deskbrief-icon-dark-source.png -resize 16x16 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 32x32 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 64x64 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-64.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 128x128 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 256x256 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 512x512 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png
magick design/app-icons/deskbrief-icon-dark-source.png -resize 1024x1024 DeskBrief/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```
