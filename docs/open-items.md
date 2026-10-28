# DOSCrate v1: open items

State as of the merge of PR #1 (`d07a896`, 2026-10-27). The code, tests (`make generate test`, 0 warnings) and review fixes are done; this lists what is not.

## Before a real release

- **Source-offer contact is a placeholder.** `LicensesView.sourceOfferContact` is `https://github.com/songer522/DOSCrate`. Confirm or replace it.
- **Release build never run.** `scripts/release.sh` (Developer ID signing, notarization, DMG, source tarball, glib/gettext source downloads) has only been checked with `bash -n` and the missing-env run. Do one real run, then play a game set to `core=dynamic` from the exported app. That confirms Staging's `allow-jit` entitlement survives the re-sign. Also confirm the `VERSION` override reaches the built `Info.plist` (only the defaults were checked).
- **LGPL source.** `release.sh` attaches plain upstream glib and gettext tarballs (versions read from the bundled dylibs). Staging builds these with vcpkg, which may patch them; if so the patches may also be "corresponding source". Needs a legal or owner look. The glib and gettext tarballs have no pinned checksums.
- **Credentials and identifiers.** Developer ID certificate, notarytool profile, Sparkle appcast host and EdDSA key (`DOSCRATE_APPCAST_URL`, `DOSCRATE_SPARKLE_KEY` are empty by default; the release script refuses empty values), and the final bundle id (placeholder `com.songer522.DOSCrate`).
- **Appcast generation and EdDSA signing** (spec §7) are not in `release.sh`.
- **Manual test checklist** (`docs/manual-test-checklist.md`) has not been walked on a Mac. Several UI paths were never exercised by hand: right-click selection on macOS, the import and detail-view manual steps, drag-and-drop.

## Planned features

- **Controller support.** Slice A (gamepad → keyboard keys with a default map, a per-model layout table, a Settings switch) is specified in `docs/superpowers/specs/2026-10-27-controller-support-design.md`, with the 2026-10-27 device probe results. Later slices: PC-joystick emulation per game (slice C) and a per-game Controller tab. The Switch 2 Pro controller is out of scope (Staging's SDL can't open it on macOS).
  **Testing:** simulator (unit tests for layout selection, map generation and `mapperfile` in the launch config); device test on the Mac with an Xbox (USB and Bluetooth), a PS5 DualSense (USB and Bluetooth) and the Steam Controller (puck), stick-up first.

## Known gaps

From the final review, deferred as non-blocking:

- Quitting DOSCrate does not end running DOSBox processes; their play time is lost. Changing the library mid-session loses stats the same way.
- The code-signature check on DOSBox (`SecStaticCodeCheckValidity`) runs on the main thread, at launch and on every Play.
- Import can fail on non-APFS or network libraries (`.itemReplacementDirectory`). Fall back to a hidden temp folder inside the library.
- Spec gaps: no "Edit" item in the context menu (§4.1), the placeholder cover doesn't show the year (§4.1), no extra folder mounts under Drives (§4.2).
- Adding media can leave an orphan file in `media/` if the selection changes during the async copy.
- The Updates toggle copies `automaticallyChecksForUpdates` into `@State` once and can go stale. "Check for Updates…" is hidden, not disabled, when `canCheckForUpdates` is false. Sparkle should also require a non-empty `SUPublicEDKey` (the release script already requires both variables).
- The DMG has an Applications symlink now, but only the DMG is stapled, and the Staging source tarball is verified by checksum while the LGPL tarballs are not.
- iCloud "Optimize Storage" can evict files from the default `~/Documents/DOSCrate Library`. iCloud is out of scope (spec §9); worth a release-notes caveat.

From the PR #4 review (duplicate handling), deferred:

- A game can be launched while a batch is replacing it. The "already running" check happens before the copy starts, so Play during a long copy lets `Importer.replace` swap the files under the running game. Fix: track the IDs being replaced in `ImportQueue` and refuse Play for them until the replace finishes.
- Replacing a kept-in-place game with another kept-in-place folder doesn't carry its saves into the new folder, because DOSCrate never writes into a kept-in-place folder. The old folder still has them.

From PR #5 (multi-select and batch remove):

- Grid ⌘-click, ⇧-click and ⌘A are covered by no automated test; only the removal logic is. ⌘A in the grid works only once the grid has focus, after a click on a game.
- Clicking empty space in the grid doesn't clear the selection.
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
- **Build:** the Makefile warning gate only checks `xcodebuild` output, not `swift test` library targets; `make test` does not depend on `generate`; the checksum-mismatch path of `fetch-staging.sh` is untested.
