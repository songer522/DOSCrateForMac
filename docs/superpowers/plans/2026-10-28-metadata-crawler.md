# Metadata and Art from LaunchBox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill each game's metadata and art from the LaunchBox Games Database. It happens automatically on import (fill-only-empty) and from a per-game Find Metadata… sheet.

**Architecture:**
- A new `MetadataKit` package target (depends on `LibraryKit` only).
  - It downloads `Metadata.zip`, stream-parses it into a local MS-DOS-only JSON index, and matches titles offline.
  - It builds a `MetadataPatch` and downloads art into the crate.
- On the app side, `MetadataCoordinator`, owned by `AppModel`, queues the imported games, applies patches through `LibraryStore.save`, and publishes a status line for both status bars.
- The UI adds a Find Metadata… sheet, a description field, an art strip, Settings rows, and a credit line.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS 15), Swift Testing (`import Testing`), `XMLParser`, `URLSession` with a stub `URLProtocol` in tests, `/usr/bin/ditto`, XcodeGen (`make generate`).

**Spec:** `docs/superpowers/specs/2026-10-28-metadata-crawler-design.md` (read it first; this plan argues from it).

## Global Constraints

- **Source:** `https://gamesdb.launchbox-app.com/Metadata.zip`. Images: `https://images.launchbox-app.com/<FileName>`. Both URLs are constants in `MetadataKit/LaunchBoxEndpoints.swift`. Nothing from LaunchBox is committed or bundled; test fixtures are hand-written XML.
- **Index file:** `~/Library/Application Support/DOSCrate/launchbox-dos.json`, `{formatVersion: 1, downloadedAt, games}`, MS-DOS only. Download and unzip go to `~/Library/Caches/DOSCrate/launchbox/`; that folder is deleted after a build and on the next launch.
- **Refresh:** a Settings button; auto-rebuild on first use when the index is more than 30 days old. The old index is used until the new one is ready. Only one build is in flight; concurrent callers await the same task.
- **Auto-apply rule:** best score ≥ 0.9 **and** at least 0.1 above the runner-up. A year match adds +0.05, capped at 1.0.
- **Fill-only-empty on import:** only nil or empty fields, only missing art files.
- **Replace mode** (sheet, after confirmation): overwrites the fields and every art kind the match provides; art kinds the match lacks are kept.
- **Art paths in the crate:**
  - `cover.png`;
  - `art/back.png`, `art/disc.png`, `art/logo.png`;
  - `art/screenshots/01.png`…`06.png` (max 6).
  - All saved as PNG, at most 4 concurrent downloads, each written to a temp file and moved into place atomically.
- **New `game.json` keys:** `description` (String, default "") and `metadataSource` (`{provider: "launchbox", id: Int, fetchedAt: Date}`). Add both to `Game.knownKeys`. Old files decode as before, and unknown keys are still preserved.
- **Copy (exact):**
  - "Downloading LaunchBox data… NN%"
  - "Building LaunchBox index…"
  - "LaunchBox data unavailable" plus a "Retry" button
  - "Find Metadata…"
  - "No matches"
  - "Use This Match"
  - "Replace existing info and art?" with "Replace" / "Cancel"
  - "Current"
  - "From LaunchBox"
  - "Fetch metadata on import"
  - "Refresh LaunchBox data"
  - "Game information and images from the LaunchBox Games Database"
- **Settings:** `Preferences.fetchMetadataOnImport`, `UserDefaults` key `fetchMetadataOnImport`, default `true`.
- **No new third-party dependencies.** No real network in any test.
- **Both themes:** status line, inspector additions and art strip work in DOS (via `App/Theme` building blocks) and Standard. Sheets stay native.
- **Gate:** `make generate test` exits 0; `grep -c warning: build/test.log build/swift-test.log` both 0; `git diff --check origin/main...HEAD` clean.
- **Lock:** wrap every `make test`, `swift test` and `xcodebuild` in `until mkdir /tmp/DOSCrateForMac-tests.lock 2>/dev/null; do sleep 15; done; trap 'rmdir /tmp/DOSCrateForMac-tests.lock' EXIT; <command>`.
- **Iterating:**
  - package: `swift test --package-path Packages/DOSCrateKit --filter <Suite>`;
  - app: `xcodebuild -project DOSCrate.xcodeproj -scheme DOSCrate -destination 'platform=macOS,arch=arm64' test -only-testing:DOSCrateTests/<Suite>`.
  - Run the full gate once at the end of each task.

## Review Focus

1. **Game played or removed while its fetch runs.** Nothing is written to a crate that's in use or gone. Task 7 test: `cancelsFetchOnPlay` and `cancelsFetchOnRemove`.
2. **The user edits a field while an auto-fetch is in flight.** The fetch re-reads the current record just before applying and fills only fields that are still empty, so the user's edit wins. Task 7 test: `autoFillDoesNotOverwriteEditMadeDuringFetch`.
3. **A referenced game whose folder is read-only or unplugged.** Fields are still saved, art is skipped, and the import doesn't fail. Task 5 test: `unwritableCrateSkipsArtWithoutThrowing`; Task 7 asserts the fields are saved.
4. **Import of many games before the index exists.** One download, every queued game processed after it, and imports never block. Task 6 test: `concurrentEnsureReadySharesOneBuild`; Task 7 test: `queuedImportsProcessedAfterIndexReady`.
5. **App quit or crash mid-download or mid-build.** A partial zip or temp index never becomes the live index, and the cache folder is cleared at launch. Task 6 test: `staleCacheFolderClearedOnInit`, plus a check that `launchbox-dos.json` is replaced only via an atomic write.

---

### Task 1: LibraryKit — new `Game` keys, art paths, shared unzip

**Files:**
- Modify: `Packages/DOSCrateKit/Sources/LibraryKit/Game.swift`
- Modify: `Packages/DOSCrateKit/Sources/LibraryKit/CrateIO.swift` (next to `coverURL`)
- Create: `Packages/DOSCrateKit/Sources/LibraryKit/Ditto.swift`
- Modify: `Packages/DOSCrateKit/Sources/ImportKit/Importer.swift:550` (private `unzip` → calls `Ditto.unzip`)
- Test: `Packages/DOSCrateKit/Tests/LibraryKitTests/GameFileCodecTests.swift`, `CrateIOTests.swift`

**Interfaces:**
- Produces:
  - `Game.description: String`, `Game.metadataSource: MetadataSource?`
  - `public struct MetadataSource: Sendable, Equatable, Codable { provider: String; id: Int; fetchedAt: Date }`
  - `CrateIO.artURL(_ crate: URL) -> URL` (`art/`)
  - `CrateIO.backURL(_:)`, `discURL(_:)`, `logoURL(_:)`
  - `CrateIO.screenshotURL(_ crate: URL, index: Int) -> URL` (1-based, `art/screenshots/%02d.png`)
  - `CrateIO.screenshotURLs(_ crate: URL) -> [URL]` (existing files, sorted)
  - `public enum Ditto { public static func unzip(_ zip: URL, into dir: URL) async throws }`; throws `DittoError.failed(String)`

- [ ] **Step 1: Write failing tests**
  - `roundTripsDescriptionAndMetadataSource`: encode, then decode, gives equal values.
  - `decodesOldFileWithoutNewKeys`: `description == ""`, `metadataSource == nil`.
  - `newKeysAreKnownNotExtra`: decoding a file with both keys leaves `extra` empty.
  - `artPathsLiveUnderArtFolder`: `screenshotURL(crate, index: 3)` ends with `art/screenshots/03.png`.
- [ ] **Step 2:** `swift test --filter LibraryKitTests` → FAIL (missing members).
- [ ] **Step 3: Implement.**
  - Follow the existing decode pattern: `decodeIfPresent` with defaults, plus the `knownKeys` entries.
  - Move the `ditto` process code from `Importer.unzip` into `Ditto.unzip`. Map its error to the existing `ImportError.unzipFailed` in `Importer`, so `ImporterTests` stay green unchanged.
- [ ] **Step 4:** `swift test --package-path Packages/DOSCrateKit` → all PASS.
- [ ] **Step 5:** Commit `feat(library): description, metadataSource, art paths, shared ditto unzip`.

### Task 2: MetadataKit target, index record, XML index builder

**Files:**
- Modify: `Packages/DOSCrateKit/Package.swift` (add `MetadataKit` library + target depending on `LibraryKit`, plus `MetadataKitTests` with `-warnings-as-errors` and `resources: [.copy("Fixtures")]`)
- Modify: `project.yml` (add the `MetadataKit` product to the app and test targets, like `ImportKit`)
- Create: `Sources/MetadataKit/LaunchBoxEndpoints.swift`, `LaunchBoxRecord.swift`, `LaunchBoxIndexBuilder.swift`
- Create: `Tests/MetadataKitTests/Fixtures/Metadata.xml`, `LaunchBoxIndexBuilderTests.swift`

**Interfaces:**
- Produces:
  - `public struct LaunchBoxImage: Sendable, Codable, Equatable { type: String; fileName: String; region: String? }`
  - `public struct LaunchBoxRecord: Sendable, Codable, Equatable, Identifiable { id: Int; name: String; alternateNames: [String]; releaseYear: Int?; developer: String?; publisher: String?; genres: [String]; overview: String?; images: [LaunchBoxImage] }`
  - `public struct LaunchBoxIndex: Sendable, Codable { formatVersion: Int; downloadedAt: Date; games: [LaunchBoxRecord] }`
  - `public enum LaunchBoxIndexBuilder { public static func build(xml: URL) throws -> [LaunchBoxRecord] }`

XML shape (verify against the real file once: download `Metadata.zip` to `/tmp`, check, then delete it; never commit it). Under the root `<LaunchBox>`:
- `<Game>`: `DatabaseID`, `Name`, `ReleaseYear` (or the year from `ReleaseDate`), `Overview`, `Platform`, `Developer`, `Publisher`, `Genres` (`;`-separated).
- `<GameAlternateName>`: `DatabaseID`, `AlternateName`.
- `<GameImage>`: `DatabaseID`, `FileName`, `Type`, `Region`.

Keep games with `Platform == "MS-DOS"`. Attach the alternate names and images by `DatabaseID` (they can appear before or after their `<Game>`, so collect them in dictionaries and join at the end).

- [ ] **Step 1:** Write the fixture: 3 MS-DOS games (one with 2 alternate names; one with images of types `Box - Front`, `Box - Back`, `Disc`, `Clear Logo`, `Screenshot - Gameplay` ×7, `Screenshot - Game Title`), 1 `Nintendo Entertainment System` game, and one alternate name placed before its game. Then write these tests:
  - `keepsOnlyMSDOS`: count is 3.
  - `attachesAlternateNamesRegardlessOfOrder`
  - `parsesGenresSplitOnSemicolon`
  - `fallsBackToReleaseDateYear`
  - `imagesAttachedWithTypeAndRegion`
  - `malformedXMLThrows`
- [ ] **Step 2:** `swift test --filter LaunchBoxIndexBuilderTests` → FAIL.
- [ ] **Step 3:** Implement with an `XMLParserDelegate` (streaming; never load the file into a `String`).
- [ ] **Step 4:** Tests PASS; `make generate` succeeds.
- [ ] **Step 5:** Commit `feat(metadata): MetadataKit and LaunchBox XML index builder`.

### Task 3: TitleMatcher

**Files:** Create `Sources/MetadataKit/TitleMatcher.swift`; Test `Tests/MetadataKitTests/TitleMatcherTests.swift`

**Interfaces:**
- Consumes: `LaunchBoxRecord`.
- Produces:
  - `public struct MatchCandidate: Sendable, Equatable { record: LaunchBoxRecord; score: Double }`
  - `public enum TitleMatcher`:
    - `static func normalize(_ s: String) -> String`
    - `static func parseYear(_ s: String) -> Int?` (a `(19xx)` or `(20xx)` tag)
    - `static func matches(for title: String, in records: [LaunchBoxRecord], limit: Int) -> [MatchCandidate]`
    - `static func autoMatch(for title: String, in records: [LaunchBoxRecord]) -> LaunchBoxRecord?`
    - `static let autoThreshold = 0.9`, `static let autoMargin = 0.1`

Scoring (from spec §3.2):
- An exact normalized match scores 1.0.
- Otherwise `max(dice(wordBigrams), containment)`, where containment = 0.85 × (shared words / words in the shorter title) when every word of the shorter title appears in the longer one; else 0.
- For a single-word title, the bigram set is the word itself.
- Take the best score over the name and all alternate names; add +0.05 if `parseYear(title) == releaseYear`; cap at 1.0.
- Sort by score descending, then fewer words in the name, then name.

- [ ] **Step 1: Failing tests.**
  - `normalize`:
    - `"The Secret of Monkey Island v1.1"` → `"secret of monkey island"`
    - `"DOOM2"` → `"doom 2"`
    - `"Ultima VII (Disk 1)"` → `"ultima 7"`
    - `"Lemmings [CD] (1991)"` → `"lemmings"`
    - `"Ça & Là"` → `"ca and la"`
  - Matching (inline records):
    - `"Commander Keen 4"` auto-matches the record named "Commander Keen in Goodbye, Galaxy!" through the alternate name "Commander Keen 4";
    - `"DOOM2"` → "Doom II";
    - `"The Secret of Monkey Island v1.1"` → "The Secret of Monkey Island";
    - `"Ultima"` with records "Ultima", "Ultima II", "Ultima III" → `autoMatch` is "Ultima" (an exact match scores 1.0 vs ≤ 0.85);
    - `"Gold Box"` with "Gold Box Companion" and "Gold Box Collection" → `autoMatch == nil` (the margin is under 0.1);
    - the year bonus breaks a tie between two equal names with different years;
    - `limit` is respected.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(metadata): title normalization and matching`.

### Task 4: MetadataPatch and MetadataApplier (pure)

**Files:** Create `Sources/MetadataKit/MetadataPatch.swift`; Test `Tests/MetadataKitTests/MetadataApplierTests.swift`

**Interfaces:**
- Consumes: `LaunchBoxRecord`, `Game`, `MetadataSource`.
- Produces:
  - `public enum ArtKind: Sendable, Hashable { case front, back, disc, logo, screenshot(Int) }`
  - `public struct MetadataPatch: Sendable, Equatable { sourceID: Int; year: Int?; developer: String?; publisher: String?; genre: String?; description: String?; art: [ArtKind: URL] }`
  - `public enum ApplyMode: Sendable { case fillEmpty, replace }`
  - `public enum MetadataApplier`:
    - `static func patch(from record: LaunchBoxRecord) -> MetadataPatch`
    - `static func apply(_ patch: MetadataPatch, to game: Game, mode: ApplyMode, now: Date) -> Game`
    - `static func wouldReplace(_ patch: MetadataPatch, game: Game, existingArt: Set<ArtKind>) -> Bool`

Rules:
- `genre` is the first of `genres`.
- Image picking per kind: prefer region nil, then "North America", then "United States", then the first.
  - front = `Box - Front`; back = `Box - Back`; disc = `Disc`; logo = `Clear Logo`.
  - Screenshots: `Screenshot - Gameplay` first, then `Screenshot - Game Title`, numbered 1…6.
- `apply` always sets `metadataSource`.
- `fillEmpty` sets a field only when it's nil (or `""` for String / `description`).

- [ ] **Step 1: Failing tests.**
  - `patchPicksArtByRegionPreference`
  - `patchCapsScreenshotsAtSix`
  - `fillEmptyKeepsExistingValues`
  - `fillEmptyTreatsEmptyStringAsEmpty`
  - `replaceOverwritesProvidedFieldsOnly` (a nil patch field keeps the old value)
  - `applySetsMetadataSource`
  - `wouldReplaceTrueWhenAnyFieldOrArtExists`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(metadata): metadata patch and apply rules`.

### Task 5: ArtDownloader

**Files:** Create `Sources/MetadataKit/ArtDownloader.swift`; Test `Tests/MetadataKitTests/ArtDownloaderTests.swift` (+ `StubURLProtocol.swift` test helper)

**Interfaces:**
- Consumes: `ArtKind`, `CrateIO` art URLs.
- Produces:
  - `public struct ArtDownloader: Sendable { init(session: URLSession, maxConcurrent: Int = 4) }`
  - `func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult`
  - `public struct ArtResult: Sendable, Equatable { written: Set<ArtKind>; failed: Set<ArtKind> }`

Behavior:
- In `fillEmpty`, skip kinds whose file already exists.
- Download to a temp file in the crate's own volume (`FileManager.url(for: .itemReplacementDirectory, …)`); fall back to `art/.tmp-<uuid>` when that's unavailable.
- Decode with `NSBitmapImageRep(data:)`; if it fails, mark the kind failed. Write PNG.
- Create `art/` and `art/screenshots/` as needed, then `replaceItemAt` or move into place.
- A cancelled task leaves no temp files.
- Never throws: an unwritable crate marks all kinds failed.

- [ ] **Step 1: Failing tests** (stub `URLProtocol` serves a 1×1 PNG, a 404, and an HTML body):
  - `writesAllKindsToCratePaths`
  - `notFoundAndNonImageAreFailedOthersWritten`
  - `fillEmptySkipsExistingFiles`
  - `neverExceedsFourConcurrentRequests` (the stub records peak in-flight requests)
  - `unwritableCrateSkipsArtWithoutThrowing` (crate dir `chmod 0500`)
  - `cancellationLeavesNoTempFiles`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(metadata): art downloader`.

### Task 6: LaunchBoxIndexStore

**Files:** Create `Sources/MetadataKit/LaunchBoxIndexStore.swift`; Test `Tests/MetadataKitTests/LaunchBoxIndexStoreTests.swift`

**Interfaces:**
- Consumes: `LaunchBoxIndexBuilder`, `LaunchBoxIndex`, `Ditto.unzip`, `LaunchBoxEndpoints`.
- Produces:
  - `public actor LaunchBoxIndexStore`
  - `init(session: URLSession, supportDir: URL, cacheDir: URL, now: @Sendable () -> Date = Date.init, maxAge: TimeInterval = 30 * 86400)`
  - `enum Phase: Sendable, Equatable { case idle, downloading(Double), building, ready, failed(String) }`
  - `func ensureReady(onPhase: @Sendable (Phase) -> Void) async throws -> [LaunchBoxRecord]` (loads the file if fresh; otherwise downloads and builds; concurrent callers share one task)
  - `func refresh(onPhase:) async throws -> [LaunchBoxRecord]` (forces a rebuild)
  - `var downloadedAt: Date? { get }`

Behavior:
- Download with `URLSession.download` plus a progress delegate for the percentage. Unzip into `cacheDir`, build, and write JSON with `.atomic`, then delete `cacheDir`'s contents.
- When stale but an old index exists, return the old records immediately and refresh in the background. When there's no index, wait for the build.
- On failure, keep the old file, and throw `LaunchBoxError.download/unzip/parse(String)`.
- `init` deletes leftovers in `cacheDir`.

- [ ] **Step 1: Failing tests.** The stub serves a zip of the fixture `Metadata.xml`, created in the test with `ditto -c -k`.
  - `firstUseDownloadsBuildsAndWritesIndex`
  - `secondUseLoadsFileWithoutNetwork` (the stub counts requests)
  - `staleIndexReturnsOldThenRebuilds`
  - `concurrentEnsureReadySharesOneBuild` (5 callers → 1 request)
  - `downloadFailureKeepsOldIndexAndThrows`
  - `staleCacheFolderClearedOnInit`
  - `reportsDownloadingThenBuildingThenReady`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(metadata): LaunchBox index store with single-flight refresh`.

### Task 7: App — MetadataCoordinator, import hook, Preferences toggle

**Files:**
- Create: `App/MetadataCoordinator.swift`
- Modify: `App/AppModel.swift` (own `let metadata: MetadataCoordinator`; init parameter for injection; call `metadata.cancel(id)` in `play(_:)`, `removeGame`, `removeGames`)
- Modify: `App/Views/ImportSheet.swift` (`finishSingleImport` replace + keepBoth paths and `runBatch`: after each committed or replaced record, `model.metadata.importedGame(record.id)`)
- Modify: `App/Preferences.swift` (`fetchMetadataOnImport`)
- Test: `AppTests/MetadataCoordinatorTests.swift`

**Interfaces:**
- Consumes: `LaunchBoxIndexStore`, `TitleMatcher`, `MetadataApplier`, `ArtDownloader`, `LibraryStore.save`/`record`, `CrateIO`.
- Produces:
  - `protocol MetadataProviding: Sendable` with `ensureReady`, `refresh`, `downloadedAt`, `download` (so tests inject a stub without network). `LaunchBoxIndexStore` + `ArtDownloader` conform through `LaunchBoxProvider`.
  - `@MainActor @Observable final class MetadataCoordinator`:
    - `init(provider: any MetadataProviding, prefs: Preferences)`
    - `var phase: LaunchBoxIndexStore.Phase`
    - `var statusText: String?` (nil when idle or ready; exact copy from Global Constraints)
    - `func importedGame(_ id: UUID)` (no-op when the pref is off)
    - `func candidates(for title: String) async throws -> [MatchCandidate]` (limit 8)
    - `func apply(_ record: LaunchBoxRecord, to id: UUID, mode: ApplyMode) async -> ApplyOutcome`
    - `func cancel(_ id: UUID)`, `func retry()`, `func refreshIndex()`
    - `weak var model: AppModel?` (set by `AppModel`, which it uses for `store`)
  - `enum ApplyOutcome: Equatable { case applied(artFailed: Bool), artNotWritable, cancelled, gameMissing }`

Behavior:
- Use one `Task` per game ID; a second request for the same ID replaces the first.
- `apply` re-reads `store.record(id)` immediately before `MetadataApplier.apply` and saves through `store.save`, so edits made during the fetch win under `fillEmpty`.
- Skip the save if the game is gone or `model.isActive(id)`, or if the task was cancelled.
- Art is written first, then the fields are saved even when every art kind failed.

- [ ] **Step 1: Failing tests** (a stub provider with an inline record set; a temp library like the existing `AppModelTests` helpers):
  - `importedGameAutoFillsAboveThreshold`
  - `importedGameBelowThresholdUnchanged`
  - `prefOffDoesNothing`
  - `queuedImportsProcessedAfterIndexReady` (the stub's `ensureReady` waits on a continuation)
  - `cancelsFetchOnPlay`
  - `cancelsFetchOnRemove`
  - `autoFillDoesNotOverwriteEditMadeDuringFetch`
  - `fieldsSavedWhenArtNotWritable`
  - `statusTextForEachPhase` (exact copy)
  - `fetchMetadataOnImportDefaultsTrue` (in `SettingsBindingTests`)
- [ ] **Steps 2–4:** FAIL → implement → PASS (`-only-testing:DOSCrateTests/MetadataCoordinatorTests`, then also `ImportQueueTests`, `AppModelTests`).
- [ ] **Step 5:** Run the full gate. Commit `feat(app): metadata coordinator and auto-fill on import`.

### Task 8: Status bars, Settings rows, credit line

**Files:**
- Modify: `App/Views/LibraryView.swift` (Standard status area near line 97) and `App/Views/Retro/RetroStatusBar.swift` (DOS): show `model.metadata.statusText`, with a "Retry" button when `phase` is `.failed`. Priority: under the import progress and scan states, above the idle state.
- Modify: `App/Views/PreferencesView.swift` (General): a "Fetch metadata on import" toggle; a "Refresh LaunchBox data" button with "Last updated <date>" or "Never".
- Modify: `App/Views/LicensesView.swift`: the credit line "Game information and images from the LaunchBox Games Database".
- Test: `AppTests/RetroLibraryTests.swift`, `LicensesTests.swift`, `SettingsBindingTests.swift`

- [ ] **Step 1: Failing tests.**
  - `statusBarShowsMetadataStatusWhenIdleOtherwise` (both layouts, via the existing status-bar text helpers)
  - `licensesIncludeLaunchBoxCredit`
  - `refreshButtonCallsCoordinator`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Run the full gate. Commit `feat(app): metadata status, settings and credit`.

### Task 9: Find Metadata… sheet

**Files:**
- Create: `App/Views/FindMetadataSheet.swift`
- Modify: `App/AppModel.swift` (`var findMetadataFor: UUID?`)
- Modify: `App/Views/LibraryView.swift` (the shared modifier that already hosts the sheets) to present it; the context menu (next to "Recreate Game Info") gets "Find Metadata…"
- Modify: `App/Views/InfoTab.swift`: a "Find Metadata…" button
- Test: `AppTests/FindMetadataSheetTests.swift`

**Interfaces:**
- Consumes: `MetadataCoordinator.candidates`, `.apply`, `MetadataApplier.wouldReplace`, `CrateIO` art URLs.
- Produces: `struct FindMetadataSheet: View { let gameID: UUID }` and a testable `@MainActor @Observable final class FindMetadataModel` (`query`, `results`, `isLoading`, `errorText`, `needsReplaceConfirmation(for:) -> Bool`, `use(_ record:) async -> ApplyOutcome`).

Behavior:
- The search field is pre-filled with the game title and re-queries after 250 ms debounce.
- Each row shows the front-cover thumbnail (`AsyncImage` from the image URL), the title, and the year · developer.
- The current `metadataSource` entry comes first, tagged "Current".
- An empty list shows "No matches". While the index loads, show the coordinator's status text; on failure, show "Retry".
- "Use This Match" → if `wouldReplace`, show the confirmation "Replace existing info and art?" (Replace / Cancel). Apply `.replace`; if the outcome is `.artNotWritable`, show an alert that the art couldn't be saved.
- The footer shows the credit line.

- [ ] **Step 1: Failing tests** on `FindMetadataModel`:
  - `prefillsQueryWithTitle`
  - `currentSourceListedFirst`
  - `emptyResultsShowNoMatches`
  - `confirmationRequiredOnlyWhenSomethingExists`
  - `useAppliesReplaceMode`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Run the full gate. Commit `feat(app): Find Metadata sheet`.

### Task 10: Inspector — description and art strip

**Files:**
- Modify: `App/Views/InfoTab.swift` (a multi-line `description` editor below the metadata fields, saved like `notes` through `setPendingWrite`; a "From LaunchBox · <date>" caption when `metadataSource != nil`)
- Create: `App/Views/ArtStripView.swift` (a horizontal row of thumbnails for back, disc, logo and screenshots that exist; hidden when there are none; click → Quick Look via `QLPreviewPanel` over the list of URLs; DOS styling through `RetroPanel` / `RetroBevel` when `prefs.appTheme == .dos`)
- Modify: `App/Views/GameDetailView.swift` (place `ArtStripView` below the cover) and the DOS inspector equivalent under `App/Views/Retro/`
- Test: `AppTests/ArtStripTests.swift`

- [ ] **Step 1: Failing tests.**
  - `artItemsOrderBackDiscLogoThenScreenshots` (pure helper `ArtStripView.items(in crate:) -> [URL]`)
  - `noArtMeansHidden`
  - `descriptionEditSavesThroughPendingWrite`
- [ ] **Steps 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Run the full gate. Commit `feat(app): description field and art strip`.

### Task 11: Docs

**Files:** `docs/manual-test-checklist.md`, `docs/superpowers/specs/2026-10-27-doscrate-design.md` (non-goals line), `docs/open-items.md` (move anything deferred here)

- [ ] **Step 1:** Add a "Metadata (LaunchBox)" section to the checklist with the spec §6 device-test steps:
  - a fresh index (delete `launchbox-dos.json`);
  - import 3–5 games from `/Volumes/MicroSD 1TB/dos`;
  - check both themes;
  - fix a wrong match with Find Metadata…;
  - Wi-Fi off → "LaunchBox data unavailable" + Retry;
  - relaunch → no new download.
- [ ] **Step 2:** In `2026-10-27-doscrate-design.md`, change "Online metadata and cover scraping (planned next)" to point at the new spec.
- [ ] **Step 3:** Run the full gate. Commit `docs: metadata crawler checklist and notes`.
