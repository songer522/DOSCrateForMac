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

- [ ] Fresh install: Standard theme, UI identical to before.
- [ ] Switch to DOS in Settings: library window restyles immediately; selection, filter, search, sort, grid/list and inspector state kept.
- [ ] In DOS: grid and list both readable; pixel font crisp (not blurry); selection outline; context menu actions; double-click Play; Delete key removal with the same dialog; drag-and-drop import and Import… with progress and Cancel in the status bar; collection rename/remove; inspector controls are retro in DOS (pickers, segmented controls, Info/Settings/Advanced tabs, Play/Stop button, flat beveled sections) while staying native in Standard and in the Settings window; inspector edits save.
- [ ] Switch themes while a game runs and while an import runs: nothing interrupted.
- [ ] Light and dark mode: DOS palette unchanged.
- [ ] Licenses window lists the font license.
- [ ] Switch back to Standard: identical to step 1.
