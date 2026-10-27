# DOSCrate manual test checklist

Run before each release, on the release build.

- [ ] Import a redistributable shareware game as a folder.
- [ ] Import a redistributable shareware game as a zip.
- [ ] Play a game and quit; the play time in the library updates.
- [ ] Referenced game on an external drive: unplug the drive; the game shows the Missing state and the Locate fix works.
- [ ] A game in a long-named subfolder triggers the "Use folder as C:" fix.
- [ ] Multi-disc game: swap discs during play.
- [ ] Fullscreen toggle works.
- [ ] A bad `override.conf` shows the banner and the log opens.
- [ ] Licenses window opens and lists DOSCrate, Sparkle and DOSBox Staging licenses.
- [ ] Notarized DMG installs and launches on a clean user account with Gatekeeper on.

## Manual check

- [ ] Drop 3+ items at once with "When importing" set to Ask (default): one "Import N items" sheet appears (not per-item sheets), Cancel imports nothing, and confirming with "Keep in place" + "Remember my choice" imports folders in place, copies zips/disc images, updates the preference, shows toolbar progress ("Importing X of N…"), and selects the first imported game.
- [ ] Drop another batch once "When importing" is set to Copy into library or Keep in place: no sheet appears and the batch imports directly using that preference.
- [ ] First-run "Choose Existing Folder…": choosing a folder that already contains DOS game subfolders, zips, and disc images scans and imports game subfolders in place (referenced) and archives/images by copying (preferring `.cue` over a same-name `.iso`), without prompting for copy vs. keep or duplicating existing crates.
- [ ] First Play on a multi-candidate imported game shows the ranked "Choose program" sheet with the top candidate preselected.
- [ ] Cancel in the "Choose program" sheet changes nothing and does not launch the game.
- [ ] Confirming in the "Choose program" sheet saves the executable and launches; pressing Play a second time launches directly without prompting.
- [ ] Dropping a batch containing a failing item imports the rest and lists the failing item once in the summary alert at the end.
