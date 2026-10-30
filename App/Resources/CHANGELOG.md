# What's New in DOSCrate

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
