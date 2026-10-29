# DOSCrate manual test checklist

Run before each release, on the release build.

- [ ] Import a redistributable shareware game as a folder.
- [ ] Import a redistributable shareware game as a zip.
- [ ] Play a game and quit; the play time in the library updates.
- [ ] Play a game whose library is on an external drive; the app stays responsive while it starts.
- [ ] While a game is starting, its cover, list row and Play button show Starting…
- [ ] Referenced game on an external drive: unplug the drive; the game shows the Missing state and the Locate fix works.
- [ ] A game in a long-named subfolder triggers the "Use folder as C:" fix.
- [ ] Multi-disc game: swap discs during play.
- [ ] Fullscreen toggle works.
- [ ] A bad `override.conf` shows the banner and the log opens.
- [ ] Licenses window opens and lists DOSCrate, Sparkle and DOSBox Staging licenses.
- [ ] Notarized DMG installs and launches on a clean user account with Gatekeeper on.

## Controllers

With Settings → "Use game controllers" on, connect one controller at a time and press Play on a keyboard game: Xbox (USB and Bluetooth), PS5 DualSense (USB and Bluetooth), Steam Controller (puck).

- [ ] Left stick up and down move the right way (check this first).
- [ ] D-pad and left stick send the arrow keys; A, B, X, Y and Start send Left Ctrl, Left Alt, Space, Enter and Esc.
- [ ] The keyboard still works alongside the controller.
- [ ] A game from a library path with a space (e.g. `/Volumes/MicroSD 1TB/dos`) launches with the controller working.
- [ ] With the switch off, the controller does nothing in a newly launched game. Changing the switch doesn't affect a game that's already running; it applies at the next Play.
- [ ] With a Switch 2 Pro (cable) and an Xbox both connected, the Xbox works and the Switch 2 Pro does nothing.
- [ ] The library's bottom bar shows the connected controller (the one Play maps, "+N" for more) and updates within a second on connect and disconnect. A wired Xbox shows as "Xbox Controller", a Switch 2 Pro alone as "Pro Controller — not supported", and the name is dimmed with "(off)" when the switch is off.

## Manual check

- [ ] Drop 3+ items at once with "When importing" set to Ask (default): one "Import N items" sheet appears (not per-item sheets), Cancel imports nothing, and confirming with "Keep in place" + "Remember my choice" imports folders in place, copies zips/disc images, updates the preference, shows toolbar progress ("Importing X of N…"), and selects the first imported game.
- [ ] Drop another batch once "When importing" is set to Copy into library or Keep in place: no sheet appears and the batch imports directly using that preference.
- [ ] First-run "Choose Existing Folder…": choosing a folder that already contains DOS game subfolders, zips, and disc images scans and imports game subfolders in place (referenced) and archives/images by copying (preferring `.cue` over a same-name `.iso`), without prompting for copy vs. keep or duplicating existing crates.
- [ ] First Play on a multi-candidate imported game shows the ranked "Choose program" sheet with the top candidate preselected.
- [ ] Cancel in the "Choose program" sheet changes nothing and does not launch the game.
- [ ] Confirming in the "Choose program" sheet saves the executable and launches; pressing Play a second time launches directly without prompting.
- [ ] Dropping a batch containing a failing item imports the rest and lists the failing item once in the summary alert at the end.

## Themes

- [ ] Fresh install: DOS theme by default; grid and list both readable; pixel font crisp (not blurry); selection outline; context menu actions; double-click Play; Delete key removal with the same dialog; drag-and-drop import and Import… with progress and Cancel in the status bar; collection rename/remove; inspector controls are retro in DOS (pickers, segmented controls, Info/Settings/Advanced tabs, Play/Stop button, flat beveled sections) while staying native in Standard and in the Settings window; inspector edits save.
- [ ] Switch to Standard in Settings: library window restyles immediately to native macOS UI; selection, filter, search, sort, grid/list and inspector state kept.
- [ ] Switch themes while a game runs and while an import runs: nothing interrupted.
- [ ] Light and dark mode: DOS palette unchanged.
- [ ] Licenses window lists the font license.
- [ ] Switch back to DOS: identical to step 1.

## Metadata (LaunchBox)

- [ ] Start with a fresh index (delete `~/Library/Application Support/DOSCrate/launchbox-dos.json` if present); verify the status bar shows "Downloading LaunchBox data…" then "Building game index…" and saves `launchbox-dos.json`.
- [ ] Import 3–5 games from `/Volumes/MicroSD 1TB/dos`; verify matched games auto-fill year, developer, publisher, genre, description, cover and extra art without blocking the import.
- [ ] Check covers, descriptions, "From LaunchBox · <date>" captions, screenshots and the Art strip (plus Quick Look on click) in both DOS and Standard themes.
- [ ] On a game that matched wrong (or didn't match), open "Find Metadata…" from the Info tab or context menu, search, confirm "Replace existing info and art?" when prompted, and verify the replacement metadata and art apply. Verify that clicking "Use This Match" saves the text fields and closes the sheet immediately while a loading spinner appears on the cover (inspector + grid/list) and Art strip until the cover and screenshots finish downloading.
- [ ] In DOS theme, verify both "Find Metadata…" (including the in-sheet "Replace existing info and art?" confirmation panel) and "Unmatched Games" render with the DOS retro panel, pixel font, sunken list with blue highlight selection, beveled buttons, and retro loading spinner (`[-]`, `[\]`, `[|]`, `[/]`).
- [ ] Turn Wi-Fi off and trigger a lookup or refresh on a missing index; verify the status bar and sheet show "LaunchBox data unavailable" with a working Retry button once Wi-Fi is back on.
- [ ] Quit and relaunch the app; verify the existing fresh `launchbox-dos.json` is reused with no new download.
- [ ] Run Library → "Find Missing Metadata" on the SD library; verify the status bar shows "Finding metadata… K of N" with a working Cancel button that stops after the current game.
- [ ] When "Find Missing Metadata" finishes, verify the status bar shows "N game(s) without a LaunchBox match" with a Review button; click Review, find "Aladin" in the unmatched list, click "Find Metadata…", select "Disney's Aladdin", and verify it applies and drops off the unmatched list.
