# DOSCrate v1: open items

State as of the merge of PR #1 (`d07a896`, 2026-10-27). The code, tests (`make generate test`, 0 warnings) and review fixes are done; this lists what is not.

## Before a real release

- **Release build never run.** `scripts/release.sh` (Developer ID signing, notarization, DMG, Sparkle `appcast.xml` generation, source tarball, glib/gettext source downloads with pinned SHA-256 verification) has only been checked with `bash -n` and the missing-env run. Do one real run, then play a game set to `core=dynamic` from the exported app. That confirms Staging's `allow-jit` entitlement survives the re-sign. Also confirm the `VERSION` override reaches the built `Info.plist` (only the defaults were checked).
- **LGPL vcpkg patch review.** `release.sh` attaches upstream glib and gettext tarballs verified against `scripts/staging.lock` (`GLIB_VERSION` / `GLIB_SOURCE_SHA256`, `GETTEXT_VERSION` / `GETTEXT_SOURCE_SHA256`). Staging builds these with vcpkg, which may patch them; if so the patches may also be "corresponding source". Needs a legal or owner look.
- **Credentials and identifiers.** Developer ID certificate, notarytool profile, Sparkle appcast host and EdDSA key (`DOSCRATE_APPCAST_URL`, `DOSCRATE_SPARKLE_KEY` are empty by default; the release script refuses empty values), and the final bundle id (`com.songer522.DOSCrate`).
- **LaunchBox terms.** Confirm the LaunchBox Games Database terms allow a third-party app to download `Metadata.zip` and its images, or get written permission (metadata crawler spec §7).
- **Manual test checklist** (`docs/manual-test-checklist.md`) has not been walked on a Mac. Several UI paths were never exercised by hand: right-click selection on macOS, the import and detail-view manual steps, drag-and-drop.

## Planned features

- **Controller support, later slices.** Slice A merged in PR #7 (`d16200f`: gamepad → keyboard keys, per-model layouts, Settings switch, library bar indicator; device test passed 2026-10-28). Still planned: PC-joystick emulation per game (slice C, trigger axes are recorded in the spec §2 table) and a per-game Controller tab. The Switch 2 Pro controller stays out of scope (Staging's SDL can't open it on macOS).
  **Testing:** simulator (layout and config tests); device test on the Mac with the controllers in the manual checklist's Controllers section.
- **Themes, later slices.** The theme system (`AppTheme`: Standard, DOS) restyles the library window, Settings (`PreferencesView`), import sheets (`ImportSheet`, `BatchImportSheet`, `ChooseProgramSheet`), metadata sheets (`FindMetadataSheet`, `UnmatchedMetadataSheet`), first-run setup (`FirstRunView`), the Licenses window (`LicensesView`), alerts (`RetroAlertModal`), and removal confirmation dialogs in DOS mode with the VGA palette, beveled panels, pixel-scaled SF Symbols and the bundled PxPlus IBM VGA 8x16 font. System file pickers (`NSOpenPanel`) and native popup menus remain macOS controls.
  **Testing:** simulator (ThemeTests, RetroLibraryTests); device test on the Mac (checklist Themes section).

## Known gaps

From the final review, deferred as non-blocking:

- Spec gaps: no extra folder mounts under Drives (§4.2).
- Adding media can leave an orphan file in `media/` if the selection changes during the async copy.
- The DMG has an Applications symlink and is stapled after notarization; the Staging and LGPL (`glib` / `gettext`) source tarballs are verified against pinned SHA-256 checksums in `scripts/staging.lock`.
- iCloud "Optimize Storage" can evict files from the default `~/Documents/DOSCrate Library`. iCloud is out of scope (spec §9); worth a release-notes caveat.
- Play now runs DOSBox verification, preflight, launch planning (`launch.conf`, `controller.map`) and session log setup off the main thread, shows "Starting…" while preparing, and times out after 20 s with an alert if the library volume doesn't respond. Still on the main thread: flushing pending inspector edits (`pendingWrites`, `game.json` / `override.conf`) before Play. Also, a hung kernel `open()` on an unresponsive volume cannot be cancelled, so a timed-out Play leaves one background thread stuck until the volume recovers. Until then the game stays "Starting…" and can't be played again or removed, so the stuck attempt can't race a retry or a removal; its late result is discarded.
  **Testing:** simulator (`AppModelTests` blocking-verifier and timeout tests); device probe: Play from an external drive and, if possible, a hung or very slow volume.
- The controller switch applies at Play; it doesn't change a game that's already running (Staging reads the mapper file once at startup). By design; the Settings caption doesn't say so.
  **Testing:** none (documented in the manual checklist).

From the PR #4 review (duplicate handling), deferred:

- Replacing a kept-in-place game with another kept-in-place folder doesn't carry its saves into the new folder, because DOSCrate never writes into a kept-in-place folder. The old folder still has them.

From PR #5 (multi-select and batch remove):

- Batch removal can't be cancelled once it starts.
- While a batch removal runs, Play is disabled for the games it will remove; double-clicking one (grid or list) does nothing, with no message.

## Deviations from the spec

- Broken `game.json` files are renamed `game.json.<timestamp>.broken`, not `game.json.broken`, so an earlier one is never overwritten. A `game.json` with `schemaVersion > 1`, or with values this version can't decode, is opened read-only and never renamed or rewritten.
- Managed games offer only "Move to Trash" (spec §4.1 asks for a choice that keeps the files). Referenced games' "Remove from Library" moves the crate to the Trash instead of deleting it.
- Staging is embedded as the universal upstream binary, not thinned to arm64, so it stays byte-identical to the upstream release.

## Deferred minors (low priority)

- **Library:** `cDriveURL` accepts `..`, unused `LibraryError.crateExists`, `LibraryStore.library` has no `didSet`, `FolderWatcher` is `@unchecked Sendable`; stale-bookmark refresh and `isDirectory` filter untested.
- **Sorting/filtering:** tag filter is case-sensitive; `titleKey` strips only an exact "The "; 30-day boundary, tie-break and filter+search combination untested.
- **Config:** `ConfigDocument.set` is case-sensitive on keys; global raw `[autoexec]` lines run before the generated `mount c`; empty DOS path components are dropped silently.
- **Importer:** no unzip size limit or cancel; `copyItem` blocks a cooperative thread; exists-check/move race throws instead of retrying; directory attributes and xattrs are lost on copy; backslash-to-slash in cue `FILE` names; symlinks dropped silently; case-only bin name variants on case-insensitive APFS; short-title reverse-prefix match is loose.
- **Launch:** duplicated `DOSPathError`-to-`LaunchError` mapping in Preflight and LaunchPlanner; some Preflight branches untested; `isSame` uses `as AnyObject`; the escalation task is never cancelled and doubles on repeated stop; `SessionResult` lacks a public init; per-start `DateFormatter`; test temp dirs leak.
- **UI:** the new game may be hidden by the active filter or search; ranking task reruns per keystroke; an external change during a pending save is lost (narrow); sidebar rename partial failure still switches the filter; cover mtime is read in `body` each render.
- **Build:** the checksum-mismatch path of `fetch-staging.sh` is untested.
