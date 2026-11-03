# What's New in DOSCrate

## 1.0.3

- **Per-Game Setup & Sound Utility (`SETUP.EXE` / `INSTALL.EXE`)**: Automatically detects setup and sound configuration utilities on import, adds a **Setup program** picker under **Startup**, and provides **Setup** / **Run Setup** actions in the inspector and context menu without affecting play statistics.
- **`.cue` / `.bin` CD-ROM Image Sets in Drives**: Add `.cue`/`.bin` CD-ROM image sets directly from **Add Disc or Floppy Image…** in the inspector's **Drives** section, with automatic track copying, collision numbering, and companion track cleanup on removal.
- **Custom Cover & Screenshot Management + In-Game Captures**: Choose or remove cover art from the cover context menu, add or remove custom screenshots in the **Art** strip, and automatically surface screenshots captured during DOSBox Staging gameplay (`[capture] capture_dir`).
- **Multi-Game Batch Inspector**: Select multiple games in the grid or list to batch-toggle favorites, add or remove tags, edit shared metadata (`Genre`, `Year`, `Developer`, `Publisher`), or apply a machine preset across the selection.
- **Show Game Files (`C:`) in Finder & On-Demand Logs**: Open a game's mounted `C:` folder directly in Finder from the context menu and view or reveal `dosbox.log` anytime from the **Advanced** tab or context menu.

## 1.0.2

- **Instant Single-Game Imports**: Single-game imports now add the game to your library immediately and copy game files or disc images in the background with a loading indicator.
- **Extra Folder Mounts (`D:`–`Y:`)**: Mount additional host folders as DOS drives alongside CD-ROM and floppy images in the inspector's **Drives** section.
- **Cancelable Batch Removal**: Multi-game library removals can now be canceled from the status bar while keeping games that have not yet been removed.
- **Reveal Imported Games**: Importing a game while a search query or sidebar/metadata filter would hide it now automatically clears the hiding filter and selects the game.
- **What's New Window & Update Notes**: View release notes for the current and past versions anytime from **DOSCrate → What's New…** or inside Sparkle update prompts.
- **Path & Config Hardening**: Hardened `C:` root path traversal checks, case-insensitive collection tag and `[dosbox]`/`[cpu]`/`[sblaster]` config matching, relative CUE sheet track paths, and concurrent session stop handling.

## 1.0.1

- **Per-Game Controller & Joystick Emulation**: Configure per-game controller mode (`None`, `2-Axis Joystick`, `4-Axis Joystick`, `Gamepad → Keyboard`) and button mappings in the inspector's **Controller** section, plus global controller defaults in **Settings**.
- **Media Copy Safety**: Prevented orphaned disc or floppy image files when changing selection while a media copy is in progress.

## 1.0.0

- **Initial Release**: Native macOS library manager and launcher for MS-DOS games, built with Swift 6 and SwiftUI and bundling DOSBox Staging 0.83.0.
- **Flexible Game Imports**: Import folders, `.zip` archives, CD-ROM (`.iso`, `.cue`/`.bin`), and floppy (`.img`, `.ima`) images as self-contained `.doscrate` bundles or referenced folders, including batch and subfolder imports.
- **LaunchBox Metadata & Artwork**: Automatic and manual metadata, cover art, and screenshot matching by title, publisher, developer, and year.
- **DOS & Standard Themes**: Classic 16-color VGA palette with the `PxPlus IBM VGA 8x16` font or native macOS controls.
- **Hardware Presets & Per-Game Tuning**: Era presets from XT (1981) through Pentium (1995), plus per-game CPU cycles, RAM, CRT shaders, Sound Blaster / GUS / General MIDI / MT-32, and drive mounts.
