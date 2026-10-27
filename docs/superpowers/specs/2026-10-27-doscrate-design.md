# DOSCrate — Design Spec

- **Date:** 2026-10-27
- **Status:** Draft, awaiting owner review
- **License (our code):** MIT — free app

## 1. Intent

A free, native macOS app for Apple Silicon that is both a **DOS game library/launcher** and a **friendly per-game settings editor**, using **DOSBox Staging** as the emulation engine.

**What the owner decided**

- Purpose: library + per-game settings (option C).
- Distribution: notarized direct download (DMG), not the Mac App Store.
- Engine: DOSBox Staging, **bundled inside the app**. Writing our own emulator is out of scope; revisit only if Staging blocks us.
- Games: import into a managed library *or* reference in place; metadata and covers entered manually. Online scraping comes later.
- Settings: a curated panel with presets, plus a raw `.conf` override editor.
- Play: DOSBox Staging runs as a separate process in its own window.
- License: MIT.

**Assumptions (owner can override)**

- macOS 15 Sequoia or later, Apple Silicon (arm64) only.
- SwiftUI, Swift 6 language mode with strict concurrency, Xcode 27.
- Working name "DOSCrate".

**Success criteria for v1**

1. A user downloads the DMG, drags the app to Applications, and it opens with no Gatekeeper warnings and with nothing else to install.
2. Dropping a DOS game folder or zip onto the window gives a playable library entry, usually with the right executable preselected.
3. Clicking Play launches the game in DOSBox Staging with the game's settings. Play time is recorded when it exits.
4. Changing a curated setting or the raw override changes the next launch's behavior, and the generated config can be inspected.
5. GPL obligations for the bundled Staging are met: license text, version, and source available.

## 2. Engine facts (verified 2026-10-27)

- `/Applications/DOSBox Staging.app`: version 0.83.0 (7b400), bundle id `io.github.dosbox-staging`, universal binary (x86_64 + arm64), Developer ID signed (team 944SS92GAH), hardened runtime. Binary at `Contents/MacOS/dosbox`, with dylibs in `Contents/MacOS/lib/`.
- The CLI options we rely on are `--conf` (repeatable, later files win), `--set`, `--noprimaryconf`, `--nolocalconf`, `--working-dir`, `-c <cmd>` (repeatable), `--noautoexec`, `--exit`, `--fullscreen`, `--machine`, and `--list-shaders`.
- The original DOSBox 0.74-3-3 was rejected because it is Intel-only and needs Rosetta 2, which is not installed and is being phased out after macOS 27.

## 3. Architecture

A SwiftUI app target plus four local Swift packages. Each package has one job and can be tested on its own.

| Unit | Responsibility | Depends on |
|---|---|---|
| `LibraryKit` | `Game` model (Codable); `LibraryStore`: scan, load, and save crate folders; watch the library folder; manage security-scoped bookmarks for referenced games; in-memory index for search and sort | Foundation |
| `ImportKit` | Turn a dropped folder, zip, ISO/CUE, or IMG into a new crate (copy, unzip, or reference); rank executable candidates; atomic create | LibraryKit |
| `ConfigKit` | Pure functions: presets + global overrides + per-game settings → `launch.conf`; generate `[autoexec]` (mounts, `cd`, run, exit); quote paths | LibraryKit (model types only) |
| `LauncherKit` | Locate the bundled `dosbox`; build the arguments; run it as a child `Process`; track sessions (one per game); capture stdout/stderr to logs; report exit status and play time | ConfigKit, LibraryKit |
| App target | Views, Preferences, About/Licenses, Sparkle updater, bundled Staging | all of the above |

**Data flow:** Import → crate on disk → `LibraryStore` → UI edits → `ConfigKit` writes `.cache/launch.conf` → `LauncherKit` runs `dosbox` → session ends → `LibraryStore` writes play stats to `game.json`.

### 3.1 Library on disk

The default location is `~/Documents/DOSCrate Library/`, and the user can change it in Preferences. Each game is one folder:

```
<Title>.doscrate/
  game.json          # metadata, settings, stats, schemaVersion
  cover.png          # optional
  override.conf      # optional raw Staging config, passed verbatim
  files/             # game contents (managed games only)
  .cache/
    launch.conf      # generated on every launch
    logs/            # last 5 session logs
```

- **Managed game:** the contents live in `files/`, which becomes C:.
- **Referenced game:** there is no `files/`. Instead, `game.json` stores the original path plus a bookmark (`URL.bookmarkData`), which is resolved before every launch. Stale bookmarks are refreshed.
- **`game.json` rules:**
  - It carries a `schemaVersion`.
  - Unknown keys are preserved when the file is rewritten (decoded into a raw JSON container and merged), so a newer app version doesn't lose data.
  - Writes are atomic (`Data.write(options: .atomic)`).
- **Collections** are a `tags: [String]` field. Favorites is a boolean.
- The scanner reads `*.doscrate` folders, decodes them in parallel, and builds the in-memory index. A file-system watcher (DispatchSource/FSEvents) triggers an incremental rescan.

### 3.2 `Game` model (outline)

- `id` (UUID)
- `title`, `year?`, `developer?`, `publisher?`, `genre?`, `notes`
- `tags`, `isFavorite`
- `source`: `.managed` or `.referenced(path, bookmark)`
- `media`: optional CD and floppy images, as an ordered list for disc swapping
- `launch`: `executable` (path relative to C:), `arguments`, `preCommands`, `postCommands`, `exitWhenDone` (default true)
- `settings`: `GameSettings` (see 4.2), where every field is optional and `nil` means "inherit"
- `stats`: `totalPlaySeconds`, `lastPlayed?`, `launchCount`

## 4. UI

### 4.1 Main window

`NavigationSplitView`:

- **Sidebar:** All Games, Recently Played, Favorites, and Collections (tags, with add/rename/remove).
- **Content:** a cover grid with a toggle to switch to a list. It has search (title, developer, year, tag) and sort (title, year, last played, play time).
  - Missing covers get a generated placeholder: the title and year on a color derived from a hash of the title.
  - Double-click plays. The context menu has Play, Show in Finder, Edit, and Remove (with a choice of "remove from library" vs "move files to Trash" for managed games).
- **Detail/inspector:** cover (drop an image to replace it), metadata, play stats, Play/Stop button, and a running indicator. Three tabs:
  - **Info:** editable metadata.
  - **Settings:** the curated panel (4.2).
  - **Advanced:** a monospaced editor for `override.conf`, a link to the Staging config docs, and a read-only "Generated config" preview.

### 4.2 Curated settings

Every control has a "Preset default" (inherit) state.

| Group | Settings | Staging keys (indicative) |
|---|---|---|
| Preset | Auto, Early 80s (8088/CGA), 286, 386, 486, Pentium | sets the values below |
| CPU | cycles (auto / fixed N / max), core | `cpu_cycles`, `core`, `cputype` |
| Memory | memory size | `memsize` |
| Graphics | machine, shader, aspect correction, start fullscreen | `machine`, `shader`/`glshader`, `aspect`, `fullscreen` |
| Sound | sound card (SB16, SB Pro, AdLib only, GUS, none); MIDI (none, General MIDI via FluidSynth, MT-32) | `sbtype`, `oplmode`, `gus`, `mididevice`, `soundfont`, `romdir` |
| Drives | C: = game folder (fixed); optional D: CD image list; extra folder mounts | generated `[autoexec]` mount/imgmount |
| Startup | executable picker, arguments, pre/post commands, exit when done | generated `[autoexec]` |
| Input | mouse capture mode, keyboard layout | `mouse_capture`, `keyboard_layout` |

The exact Staging 0.83 key names and valid values must be checked against `dosbox --printconf` output and the shipped default config while implementing. ConfigKit keeps that mapping in one table.

### 4.3 Preferences

- Library location.
- Default preset.
- Global overrides, using the same curated controls plus a raw text box.
- Soundfont path (`.sf2`) and MT-32 ROM folder, both supplied by the user. We do not ship ROMs.
- Updates: Sparkle automatic checks on or off.

### 4.4 Import sheet

1. Drop or choose a folder, `.zip`, `.iso`/`.cue`, `.img`/`.ima`.
2. Choose "Copy into library" (the default) or "Keep in place". Archives and images are always copied.
3. Pick the executable. The ranked candidates are shown with the best one preselected.
4. Set the title, prefilled from the folder or archive name.
5. Create, done atomically.

**Executable ranking heuristics:**
- Candidates are `.EXE`, `.COM` and `.BAT` files, ranked:
  - higher if the name matches the folder or title, or if the file is in the root
  - lower if the name is `SETUP`, `INSTALL`, `INSTALLER`, `CONFIG`, `SETSOUND`, `UNINST`, or a known utility (`PKUNZIP`, `README`, ...)
- Ties are broken by depth, then size.

Zips are unpacked with `/usr/bin/ditto -x -k` (no extra dependency). An ISO/CUE or IMG becomes a media entry. The crate gets an empty `files/` as C:, and the user is guided to install from D:.

## 5. Launch and config generation

**Config layering** (lowest to highest priority):
1. Staging built-in defaults (`--noprimaryconf --nolocalconf` keep the user's own Staging config out)
2. Global overrides from Preferences
3. Preset values
4. The game's curated settings
5. The game's `override.conf`

ConfigKit merges layers 2–4 into `.cache/launch.conf`, which includes a generated `[autoexec]`:

```
[autoexec]
mount c "<C: path>"
imgmount d "<disc1>" "<disc2>" -t iso      # if media present
c:
cd <exe dir>
<preCommands>
<exe> <arguments>
<postCommands>
exit                                       # if exitWhenDone
```

**Command line:**

```
<bundle>/Contents/Resources/DOSBox Staging.app/Contents/MacOS/dosbox \
  --noprimaryconf --nolocalconf \
  --conf <crate>/.cache/launch.conf \
  [--conf <crate>/override.conf] \
  [--fullscreen]
```

If `override.conf` also has an `[autoexec]`, it is appended after ours (Staging's multi-conf behavior). This is documented in the Advanced tab.

**Sessions:**
- `LauncherKit` starts a `Process`, with stdout and stderr piped to `.cache/logs/<timestamp>.log`.
- It records the start time and watches for termination, then reports exit status and duration.
- Stop sends SIGTERM, then SIGKILL after 5 seconds.
- One session per game. Different games can run at the same time.

## 6. Error handling

| Situation | Behavior |
|---|---|
| Bundled `dosbox` missing or unsigned | Fail before launch with an alert suggesting reinstall. Checked at app start too |
| Executable missing | Alert with "Choose executable…" |
| Referenced folder unreachable or bookmark stale | Alert with "Locate folder…". The game shows a "Missing" badge in the grid |
| Non-zero exit or crash | Session ends; play time still recorded; "Exited unexpectedly — View log" banner |
| Import failure or cancel | Nothing is created. Imports build in a temp dir and are moved into the library only on success |
| `game.json` unreadable | Renamed to `game.json.broken`; the game is shown as "Needs repair" with an option to recreate it |
| Library folder missing | First-run style prompt to choose or create one |

## 7. Packaging, signing, licensing

- **Build script** `scripts/fetch-staging.sh`: downloads a pinned DOSBox Staging release DMG (version and SHA-256 in `scripts/staging.lock`), checks it, and extracts the app to `Vendor/`. Ignored by git, never committed.
- **Xcode build phase:** copies it to `Contents/Resources/DOSBox Staging.app`.
- **Release script:**
  - Re-signs the nested dylibs, the `dosbox` binary and the nested app with our Developer ID and hardened runtime, inside out.
  - Signs our app, builds the DMG, notarizes it (`notarytool`) and staples it.
  - Entitlements are minimal; App Sandbox is not used.
- **Licenses:**
  - Our code is MIT (`LICENSE` at the repo root).
  - About › Licenses shows: our MIT license, Staging's GPL-2.0 text, Staging's bundled third-party notices, Sparkle's license, the exact Staging version and upstream tag URL, and a written offer for the source.
  - Each GitHub release also attaches the matching upstream Staging source tarball.
  - Staging is unmodified and runs as a separate process, so the GPL does not reach our code.
- **Updates:** Sparkle 2 with an EdDSA-signed appcast. A Staging upgrade ships as a new DOSCrate release.

## 8. Testing

- **Unit tests** (Swift Testing), per package:
  - ConfigKit: layer precedence, preset tables, `[autoexec]` generation, quoting paths with spaces and quotes, multi-disc imgmount, `exitWhenDone` toggling.
  - ImportKit: executable ranking against fixture folder trees, zip unpack, atomic cleanup on failure.
  - LibraryKit: `game.json` round-trip, unknown-key preservation, broken-file recovery, scanner over a fixture library.
  - LauncherKit: argument construction, session state machine (with a fake process runner).
- **Integration test:** run the bundled `dosbox` with `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy`, mounting a temp C: and running `-c "echo ok > C:\OUT.TXT" --exit`. Assert that the file exists. This is skipped when the vendor app hasn't been fetched.
- **Manual checklist:**
  - Import a redistributable shareware DOS game (folder and zip), play, quit, and check play time.
  - Referenced game on an external drive: unplug it and check the Missing state.
  - Multi-disc swap; fullscreen toggle.
  - Notarized DMG on a clean user account.
- **Gate:** `make test` (`xcodebuild test`) passes with zero warnings under Swift 6 strict concurrency, and `git diff --check` is clean.

## 9. Out of scope for v1

Online metadata and cover scraping (planned next), a schema-driven full "Advanced" settings UI, save states, a controller or gamepad mapping UI, 7z/rar import, iCloud sync features, a Mac App Store build, Intel Macs, localization beyond English, and a custom emulator.
