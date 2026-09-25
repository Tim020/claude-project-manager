# App icon — light & dark

Light appearance = design 3b (blue body, dark folder, teal prompt).
Dark appearance = design 3a (dark body, blue folder, white prompt).

## Contents
- `AppIcon.appiconset/` — drop into `Assets.xcassets/` (replace the existing `AppIcon.appiconset`). Contains all macOS sizes (16–512 pt, @1x/@2x) for both appearances; dark variants are tagged `luminosity: dark` in `Contents.json`.
- `source/AppIcon-light.svg`, `source/AppIcon-dark.svg` — vector masters (512 viewBox, 1024 px). Artwork follows the macOS grid: 412 pt rounded body (radius 92) centred on a 512 canvas with a baked drop shadow.
- `source/AppIcon-*-1024.png` — 1024 px masters.

## Instructions for the coding agent
1. Replace `Assets.xcassets/AppIcon.appiconset` with the folder provided. Ensure the target's *App Icon* build setting (`ASSETCATALOG_COMPILER_APPICON_NAME`) is `AppIcon`.
2. Appearance switching is handled by the OS: macOS 26+ shows the dark variant when the system is in Dark Mode. Earlier macOS versions ignore the dark entries and always show the light icon — no code needed.
3. If Xcode reports the dark appearance entries as unsupported for the `mac` idiom, use Icon Composer instead: create `AppIcon.icon`, build layers from the SVG masters (body, folder, cards, flap, prompt), set the Dark appearance colours listed below, and add the `.icon` file to the target.
4. Do not add runtime icon switching (`NSApp.applicationIconImage`) — the system appearance handles it.

## Colours
| Layer | Light (3b) | Dark (3a) |
|---|---|---|
| Body | #3498db | #222222 |
| Folder back + tab | #1b1b1b | #2980b9 |
| Back card | #6c757d | #6c757d |
| Front card | #444444 | #303030 |
| Status dots | #00bc8c / #f39c12 / #adb5bd | same |
| Front flap | #222222 | #3498db |
| Prompt `>_` | #00bc8c | #ffffff |
