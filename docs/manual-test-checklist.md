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
