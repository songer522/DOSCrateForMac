# Metadata and art from the LaunchBox Games Database

Date: 2026-10-28. Status: design approved in chat by the owner, spec awaiting review.

## 1. Goal

Fill each game's metadata and art from the LaunchBox Games Database instead of typing it by hand. A match brings in the year, developer, publisher, genre, a description, the front cover, the back cover, other box art (disc, clear logo) and screenshots. It runs automatically on import (filling only what's empty) and on demand from a per-game **Find Metadata…** sheet.

This replaces the "online metadata and cover scraping comes later" non-goal in `2026-10-27-doscrate-design.md`.

## 2. Owner decisions

| Question | Decision |
|---|---|
| Source | **LaunchBox Games Database**, through its downloadable `Metadata.zip` (it has no official API). Nothing from LaunchBox ships inside the app. |
| When | **Automatically on import** + a per-game **Find Metadata…** button. No library-wide batch in this slice. |
| Content | Year, developer, publisher, genre, **description**, front cover, **back cover**, **disc** and **clear logo** art, **screenshots**. |
| Architecture | Approach 1: download `Metadata.zip` once, build a local MS-DOS-only index, match offline, fetch images on demand. |
| Import policy | **Fill only empty fields and missing art**, and only above the confidence threshold. |

## 3. Behavior

### 3.1 Index

- The first time a match is needed (an import, or opening Find Metadata…), the app downloads `https://gamesdb.launchbox-app.com/Metadata.zip` in the background into `~/Library/Caches/DOSCrate/launchbox/`.
- It unzips with the existing `Importer` unzip helper, stream-parses `Metadata.xml` with `XMLParser`, and keeps only games with `Platform == "MS-DOS"`, along with their `GameAlternateName` and `GameImage` records. The result goes to `~/Library/Application Support/DOSCrate/launchbox-dos.json` as `{formatVersion, downloadedAt, games: [...]}`. The zip and the XML are then deleted.
- The index is loaded lazily and kept in memory while the app runs.
- **Refresh:** a Settings button "Refresh LaunchBox data". The index is also rebuilt automatically on the first use after it's more than 30 days old. A refresh replaces the file atomically; the old index stays in use until the new one is ready.
- **Status:** while downloading or building, the library window's status bar shows "Downloading LaunchBox data… NN%", then "Building LaunchBox index…", in both themes. On failure it shows "LaunchBox data unavailable", with a **Retry** button.
- Only one download or build runs at a time, and callers waiting on it share that one task.

### 3.2 Matching

- `TitleMatcher.normalize`:
  - lowercases;
  - folds diacritics;
  - turns `&` into "and";
  - strips punctuation;
  - collapses whitespace;
  - drops a leading "the";
  - maps roman numerals II–X to digits;
  - strips trailing version and disk tags (`v1.2`, `(disk 1)`, `[cd]`, `(1993)`, `(en)`);
  - splits a trailing digit from letters (`doom2` → `doom 2`).
- Score each candidate against its name and every alternate name, keeping the best. An exact normalized match is 1.0. Anything else is token-based similarity (Dice coefficient on word bigrams, plus a containment bonus), in 0…1. A year parsed from the input that equals the candidate's release year adds +0.05, capped at 1.0. Ties are broken by fewer words in the candidate.
- `matches(for title:, limit:)` returns candidates sorted by score.
- **Auto threshold:** apply automatically only when the best score is ≥ 0.9 **and** at least 0.1 above the runner-up. Otherwise the game is left untouched.

### 3.3 Applying a match

- `MetadataPatch` holds the chosen candidate's fields plus its image URLs, by kind: front, back, disc, logo, and up to 6 screenshots.
- **Fill-only-empty** (import): sets `year`, `developer`, `publisher`, `genre` and `description` only where they're nil or empty. It downloads an image only if that file is missing.
- **Replace** (manual sheet, after confirmation): overwrites those fields and every art file the match provides. Art kinds the match lacks are kept.
- Images are downloaded from LaunchBox's image host (the base URL is a constant in `MetadataKit`), at most 4 at a time, to temp files. They're checked to decode as an image and saved as PNG via `NSBitmapImageRep` or `CGImageDestination`, then moved into the crate atomically:
  - front → `cover.png` (the existing slot);
  - back → `art/back.png`;
  - disc → `art/disc.png`;
  - clear logo → `art/logo.png`;
  - screenshots → `art/screenshots/01.png` … `06.png`.
- The new `Game` fields are `description: String` (default "", round-tripped) and `metadataSource: MetadataSource?` (`{provider: "launchbox", id: Int, fetchedAt: Date}`). Both go into `Game.knownKeys`. Older `game.json` files without them decode as before, and unknown-key preservation is unchanged.
- `game.json` is saved through `LibraryStore`'s existing write path.
- A failed image download → skip that image, log it, and apply the rest.
- A referenced game whose folder isn't writable → in the manual flow, an alert says the art couldn't be saved; in the automatic flow, it's skipped silently. Metadata fields are still saved, because `game.json` is in the crate.

### 3.4 On import

- After a game's crate is written, `ImportQueue` hands the game ID and title to a `MetadataCoordinator` (app side). Imports never wait on it.
- If the index isn't ready yet, the coordinator queues the ID and starts the download, then processes the queue once the index is ready.
- It's controlled by Settings › General › "Fetch metadata on import" (`Preferences.fetchMetadataOnImport`, default on).
- If the game is played or removed while its fetch is running, the fetch is cancelled and nothing is written. Each crate has at most one fetch in flight.

### 3.5 Find Metadata… sheet

- Opened from a **Find Metadata…** button in the inspector (Info tab) and a context-menu item. Native sheet, like the import sheets.
- A search field, pre-filled with the game's title, re-queries live. Up to 8 candidates are listed with title, year, developer and a front-cover thumbnail, which loads lazily. An empty list shows "No matches". While the index is loading, the sheet shows the progress state.
- **Use This Match:** if any field or art file the match would change already has a value, a confirmation says "Replace existing info and art?" with Replace or Cancel. Then it applies the match in replace mode and closes.
- A game with a `metadataSource` shows that entry first, marked "Current".

### 3.6 Inspector

- Info tab: the description goes below the metadata fields in a multi-line text field (editable, saved like `notes`). A small "From LaunchBox" caption with the fetch date shows when `metadataSource` is set.
- A new **Art** strip below the cover shows thumbnails of the back, disc and logo art and the screenshots that exist. Clicking one opens it in Quick Look (`QLPreviewPanel`). The strip is hidden when there's no extra art.
- Everything is styled for both themes, through the existing `Theme` building blocks in DOS. Every new view, including sheets (`FindMetadataSheet`, `UnmatchedMetadataSheet`, and in-sheet replace/error panels) and loading spinners (`RetroSpinner`), ships with a DOS version; the Settings window and system dialogs (file pickers, menu bar) stay native.
- Applying a match saves the text fields and `metadataSource` immediately and downloads art in a background task per game (writing `cover.png` first and skipping PNG re-encoding when source bytes are already PNG), showing a loading spinner on the cover and Art strip while art downloads.

### 3.7 Credit

- The Licenses window and the Find Metadata sheet's footer say "Game information and images from the LaunchBox Games Database".

### 3.8 Follow-up: fuzzy search, unmatched notice, library-wide fetch

- **Letter-level fuzzy search (Find Metadata… sheet only):** `TitleMatcher.searchScore(_ query:, _ record:)` takes `max(wordScore, trigramDice)` over the record's name and alternate names—where `trigramDice` is the Dice coefficient on character trigrams of the normalized strings with spaces removed and padded with `"  "` at both ends—plus the +0.05 year bonus (capped at 1.0). `TitleMatcher.search(for:in:limit:)` ranks by `searchScore` and drops candidates below 0.3; `MetadataCoordinator.candidates(for:)` uses `search`. `autoMatch` and its 0.9 / 0.1 rule stay word-level only.
- **Unmatched notice:** `MetadataCoordinator` keeps `private(set) var unmatched: [UUID]` (ordered, no duplicates). A game is appended when an automatic lookup (import or library-wide) finds no confident match, and removed when a match is applied to it, when the game is removed from the library, or when `dismissUnmatched()` is called. When `unmatched` is non-empty and no download, build, or batch metadata run is active, the status bar in both themes shows `"1 game without a LaunchBox match"` / `"N games without a LaunchBox match"` with a **Review** button that opens `UnmatchedMetadataSheet` (listing each game's title with **Find Metadata…**, **Dismiss All**, and **Done**).
- **Library-wide "Find Missing Metadata":** A menu command **Find Missing Metadata** (disabled while a run is active or when the library is empty) calls `MetadataCoordinator.findMissingMetadata()`, which targets every non-running game with `metadataSource == nil` that is missing at least one of `year`, `developer`, `publisher`, `genre`, `description`, or `cover.png`. It processes them one at a time through the `fillEmpty` auto-match path (independent of the "Fetch metadata on import" toggle), shows `"Finding metadata… K of N"` with a **Cancel** button (`cancelFindMissing()`) in the status bar, and records games without a confident match in `unmatched`.

## 4. Architecture

- **New `MetadataKit` target** in `Packages/DOSCrateKit`. It depends on `LibraryKit` only and has no UI or AppKit apart from image encoding.
  - `LaunchBoxRecord` (Codable index entry: `id`, `name`, `alternateNames`, `releaseYear`, `developer`, `publisher`, `genres`, `overview`, `images: [{type, fileName}]`).
  - `LaunchBoxIndexBuilder` (XML stream → `[LaunchBoxRecord]`; pure, works on a fixture file).
  - `LaunchBoxIndexStore` (download, build, atomic save and load, 30-day staleness, a single shared in-flight task). It takes a `URLSession` and directories through its initializer, so tests can inject them.
  - `TitleMatcher` (normalize + score; pure).
  - `MetadataPatch` + `MetadataApplier` (fill-only-empty and replace into a `Game` value; pure).
  - `ArtDownloader` (bounded-concurrency download, image validation, PNG write, atomic move; `URLSession` injected).
- `LibraryKit`: `Game.description`, `Game.metadataSource`, and crate path helpers for `art/…`.
- App: `MetadataCoordinator` (`@MainActor`, owned by `AppModel`: the queue, cancellation on Play or Remove, status for the status bar), `FindMetadataSheet`, the Info tab additions, `ArtStripView`, the Settings rows and the Licenses text.
- No new third-party dependencies. The app isn't sandboxed, so no new entitlement is needed; confirm this when building the plan.

## 5. Errors

| Case | Behavior |
|---|---|
| Offline, download or HTTP failure | Status bar shows "LaunchBox data unavailable – Retry"; imports succeed without metadata; the sheet shows the same with Retry |
| Malformed XML / parse error | Same as a download failure; the old index (if any) is kept |
| No candidate above the threshold on import | Nothing changes |
| An image download or decode fails | That image is skipped and logged; the rest are applied |
| Referenced game's folder read-only or unplugged | Art is skipped (alert in the manual flow); fields are still saved |
| Play or Remove during a fetch | That fetch is cancelled; nothing is written |
| App quits mid-download | Partial temp files are deleted on the next launch; the index is rebuilt on the next use |

## 6. Testing

**Testing:** simulator (unit and app tests on the Mac test host) + device test on the owner's Mac (the SD-card library at `/Volumes/MicroSD 1TB/dos`).

- **MetadataKit unit tests:**
  - the index builder on a small fixture `Metadata.xml` (DOS and non-DOS games, alternate names, several image types);
  - normalization cases;
  - matcher cases: `Commander Keen 4` finds "Commander Keen in Goodbye, Galaxy!" through an alternate name, `DOOM2` → "Doom II", `The Secret of Monkey Island v1.1`, an ambiguous title stays below the threshold;
  - fill-only-empty versus replace;
  - `ArtDownloader` through a stub `URLProtocol`, covering success, a 404, a non-image body and the concurrency cap;
  - staleness and the single in-flight build in the index store;
  - `Game` round-trip with and without the new keys.
- **App tests:** import → auto-fill with a stub index; Play or Remove cancels a fetch; the sheet's apply path with and without the replace confirmation.
- No real network in any test.
- **Device test (owner):** import 3–5 games from the SD card on a fresh index. Check the covers, descriptions, screenshots and art strip in DOS and Standard. Use Find Metadata… on a game that matched wrong. Try offline (Wi-Fi off) for the error state and Retry. Restart the app and check that the index is reused, not downloaded again.

## 7. Release gate

Before any public release, confirm that LaunchBox's terms allow a third-party app to download `Metadata.zip` and its images, or get written permission. This is tracked in `docs/open-items.md` under Release prep.

## 8. Out of scope

Other providers (IGDB, MobyGames); manuals and videos; editing or uploading to LaunchBox; matching by file hash.
