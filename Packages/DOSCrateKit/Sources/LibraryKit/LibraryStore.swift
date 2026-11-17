import Foundation
import Observation
import os

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var records: [GameRecord] = []
    public var library: URL
    /// Test hook called at the start of every `reload()`.
    @ObservationIgnored public var onReload: (@MainActor () -> Void)?
    /// Called at the end of `reload()` after `records` is updated.
    @ObservationIgnored public var afterReload: (@MainActor () -> Void)?
    /// Test hook called inside each batch removal chunk before trashing the record.
    @ObservationIgnored public var itemRemovalHook: (@Sendable (UUID) async -> Void)?
    /// While true, file-watcher events are ignored so a running batch import or removal controls reload timing.
    public var isWatcherSuppressed: Bool { watcherSuppressions > 0 }
    @ObservationIgnored private var watcherSuppressions = 0
    /// Set when a watcher event arrives (or a pending reload is dropped) while suppressed.
    @ObservationIgnored private var missedWatcherEvent = false
    /// Set when a health-watcher event arrives while suppressed.
    @ObservationIgnored private var missedHealthEvent = false

    @ObservationIgnored private let io: CrateIO
    @ObservationIgnored private let scan: @Sendable (URL) async -> [GameRecord]
    @ObservationIgnored private var isWatching = false
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var healthWatcher: FolderWatcher?
    @ObservationIgnored private var healthWatcherSetup: Task<Void, Never>?
    @ObservationIgnored private var watchedHealthScope: Set<String> = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var healthDebounce: Task<Void, Never>?
    /// Bumped by every reload and every local change, so a scan that started earlier can't overwrite newer state.
    @ObservationIgnored private var generation = 0
    /// Bumped by every `refreshAttention()` call so an earlier overlapping health scan can never overwrite a newer one.
    @ObservationIgnored private var healthGeneration = 0

    public convenience init(library: URL, io: CrateIO = .init()) {
        self.init(library: library, io: io, scan: { await io.scan(library: $0) })
    }

    /// `scan` is a test hook; it defaults to `CrateIO.scan`.
    init(library: URL, io: CrateIO, scan: @escaping @Sendable (URL) async -> [GameRecord]) {
        self.library = library
        self.io = io
        self.scan = scan
    }

    public func reload() async {
        onReload?()
        generation += 1
        let started = generation
        let scanned = await scan(library)
        guard started == generation else { return }
        records = scanned
        rebuildHealthWatcher()
        afterReload?()
    }

    /// Recomputes filesystem and launch-path health for every loaded record off the main actor
    /// without rescanning the library index, publishing any changed `status` or `needsAttention` values.
    public func refreshAttention() async {
        let snapshot = records
        guard !snapshot.isEmpty else { return }
        healthGeneration += 1
        let started = generation
        let startedHealth = healthGeneration
        let io = self.io
        let cancelled = OSAllocatedUnfairLock(initialState: Task.isCancelled)
        let updates = await withTaskCancellationHandler {
            await Task.detached { () -> [UUID: (status: RecordStatus, needsAttention: Bool, refreshedSource: GameSource?)] in
                var out: [UUID: (status: RecordStatus, needsAttention: Bool, refreshedSource: GameSource?)] = [:]
                for record in snapshot {
                    if cancelled.withLock({ $0 }) { return [:] }
                    if io.isIncompleteImport(record.crateURL) { continue }
                    var probe = record
                    var resolvedFolder: URL?
                    var refreshedSource: GameSource?
                    switch record.status {
                    case .ok, .missingSource:
                        if case .referenced(let path, let bookmark) = record.game.source {
                            if let resolved = try? CrateIO.resolve(path: path, bookmark: bookmark) {
                                resolvedFolder = resolved.url
                                probe.status = .ok
                                if resolved.stale {
                                    let updatedSource = GameSource.referenced(path: resolved.url.path, bookmark: resolved.bookmark)
                                    probe.game.source = updatedSource
                                    refreshedSource = updatedSource
                                }
                            } else {
                                probe.status = .missingSource
                            }
                        }
                    case .needsRepair, .readOnly:
                        break
                    }
                    let attention = LibraryQuery.needsAttention(
                        probe,
                        io: io,
                        resolvedReferencedFolder: resolvedFolder
                    )
                    if probe.status != record.status
                        || attention != record.needsAttention
                        || refreshedSource != nil {
                        out[record.id] = (probe.status, attention, refreshedSource)
                    }
                }
                return out
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        guard !Task.isCancelled, startedHealth == healthGeneration else { return }
        guard started == generation else {
            if !isWatcherSuppressed {
                scheduleHealthRefresh()
            }
            return
        }
        guard !updates.isEmpty else { return }
        for index in records.indices {
            if let update = updates[records[index].id] {
                if let refreshedSource = update.refreshedSource {
                    records[index].game.source = refreshedSource
                    let crate = records[index].crateURL
                    let extra = io.extraOnDisk(at: crate) ?? records[index].extra
                    try? io.save(records[index].game, extra: extra, to: crate)
                }
                records[index].status = update.status
                records[index].needsAttention = update.needsAttention
            }
        }
        rebuildHealthWatcher()
    }

    public func record(_ id: UUID) -> GameRecord? {
        records.first { $0.id == id }
    }

    /// Inserts or updates a single record in memory without rescanning the whole library folder,
    /// maintaining the store's title-sorted order.
    public func upsert(_ record: GameRecord) {
        generation += 1
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort {
            let order = $0.game.title.localizedStandardCompare($1.game.title)
            return order == .orderedSame ? $0.crateURL.path < $1.crateURL.path : order == .orderedAscending
        }
        rebuildHealthWatcher()
        afterReload?()
    }

    /// Drops an in-memory record (such as an optimistic crate whose background file copy failed) without touching the Trash.
    public func discard(_ id: UUID) {
        generation += 1
        records.removeAll { $0.id == id }
        rebuildHealthWatcher()
    }

    /// Writes the game into its crate, keeping any unknown keys currently on disk.
    public func save(_ game: Game) throws {
        guard let index = records.firstIndex(where: { $0.id == game.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if case .readOnly = records[index].status { throw LibraryError.readOnly }
        generation += 1
        let crate = records[index].crateURL
        let extra = io.extraOnDisk(at: crate) ?? records[index].extra
        try io.save(game, extra: extra, to: crate)
        let loaded = io.loadRecord(at: crate)
        records[index].game = game
        records[index].extra = extra
        records[index].status = loaded.status
        records[index].needsAttention = loaded.needsAttention
        rebuildHealthWatcher()
    }

    /// Removes a game by moving its crate to the Trash; nothing is ever deleted outright. With `trashFiles`,
    /// a referenced game's own folder goes to the Trash too (a managed game's files are inside its crate).
    public func remove(_ id: UUID, trashFiles: Bool) throws {
        guard let record = record(id) else { return }
        generation += 1
        let fm = FileManager.default
        if trashFiles, let folder = try? io.referencedFolderURL(for: record) {
            try fm.trashItem(at: folder, resultingItemURL: nil)
        }
        try fm.trashItem(at: record.crateURL, resultingItemURL: nil)
        records.removeAll { $0.id == id }
        rebuildHealthWatcher()
    }

    /// Removes several games, trashing off the main actor in small chunks so the library shrinks as it goes.
    /// `onProgress` gets (done, total) after each chunk. Returns a "Title: reason" line for each failure;
    /// a game whose folder can't be trashed keeps its crate. Honours task cancellation between items.
    public func remove(
        _ ids: [UUID], trashFiles: Bool, onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> [String] {
        let targets = ids.compactMap(record)
        guard !targets.isEmpty else { return [] }
        // Each trashed crate would otherwise trigger a full rescan of the library.
        suppressWatcher()
        defer { resumeWatcher() }
        let io = self.io
        let hook = self.itemRemovalHook
        let cancelled = OSAllocatedUnfairLock(initialState: Task.isCancelled)
        return await withTaskCancellationHandler {
            var failures: [String] = []
            var done = 0
            for start in stride(from: 0, to: targets.count, by: 20) {
                if Task.isCancelled || cancelled.withLock({ $0 }) { break }
                let chunk = Array(targets[start..<min(start + 20, targets.count)])
                generation += 1
                let (removed, chunkFailures, processed) = await Task.detached { () -> (Set<UUID>, [String], Int) in
                    let fm = FileManager.default
                    var removed = Set<UUID>()
                    var failures: [String] = []
                    var processed = 0
                    for record in chunk {
                        if cancelled.withLock({ $0 }) { break }
                        if let hook {
                            await hook(record.id)
                            if cancelled.withLock({ $0 }) { break }
                        }
                        processed += 1
                        do {
                            if trashFiles, let folder = try? io.referencedFolderURL(for: record) {
                                try fm.trashItem(at: folder, resultingItemURL: nil)
                            }
                            try fm.trashItem(at: record.crateURL, resultingItemURL: nil)
                            removed.insert(record.id)
                        } catch {
                            failures.append("\(record.game.title): \(error.localizedDescription)")
                        }
                    }
                    return (removed, failures, processed)
                }.value
                generation += 1
                records.removeAll { removed.contains($0.id) }
                rebuildHealthWatcher()
                failures += chunkFailures
                done += processed
                onProgress?(done, targets.count)
                if Task.isCancelled || cancelled.withLock({ $0 }) { break }
            }
            return failures
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    public func startWatching() {
        stopWatching()
        isWatching = true
        let library = self.library
        watcher = FolderWatcher(url: library, isRelevant: { Self.isRelevantChange($0, library: library) }) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        rebuildHealthWatcher(force: true)
    }

    public func stopWatching() {
        isWatching = false
        watcher?.stop()
        watcher = nil
        healthWatcherSetup?.cancel()
        healthWatcherSetup = nil
        healthWatcher?.stop()
        healthWatcher = nil
        watchedHealthScope = []
        debounce?.cancel()
        debounce = nil
        healthDebounce?.cancel()
        healthDebounce = nil
    }

    private func rebuildHealthWatcher(force: Bool = false) {
        guard isWatching else { return }
        let library = self.library
        var rawScope: Set<String> = [library.standardizedFileURL.path]
        var referencedURLs: [URL] = []
        for record in records {
            if case .referenced(let path, _) = record.game.source {
                let refURL = URL(filePath: path, directoryHint: .isDirectory)
                if rawScope.insert(refURL.standardizedFileURL.path).inserted {
                    referencedURLs.append(refURL)
                }
            }
        }
        if !force, rawScope == watchedHealthScope, (healthWatcher != nil || healthWatcherSetup != nil) {
            return
        }
        watchedHealthScope = rawScope
        healthWatcherSetup?.cancel()
        healthWatcher?.stop()
        healthWatcher = nil
        let expectedScope = rawScope
        healthWatcherSetup = Task.detached { [weak self] in
            var watchURLs: [URL] = [library]
            var seenWatchPaths: Set<String> = [library.standardizedFileURL.path]
            var referencedRoots: Set<String> = []
            for refURL in referencedURLs {
                for canonical in Self.canonicalPaths(for: refURL) {
                    referencedRoots.insert(canonical)
                }
                let parentURL = refURL.deletingLastPathComponent()
                for candidate in [parentURL, refURL] where candidate.path != "/" {
                    let std = candidate.standardizedFileURL.path
                    if seenWatchPaths.insert(std).inserted {
                        watchURLs.append(candidate)
                    }
                }
            }
            let libraryBases = Self.canonicalPaths(for: library)
            let roots = referencedRoots
            guard !Task.isCancelled else { return }
            let newWatcher = FolderWatcher(
                urls: watchURLs,
                isRelevant: { Self.isHealthRelevantChange($0, libraryBases: libraryBases, referencedRoots: roots) }
            ) { [weak self] in
                Task { @MainActor in self?.scheduleHealthRefresh() }
            }
            await MainActor.run { [weak self] in
                guard let self, self.isWatching, self.watchedHealthScope == expectedScope, !Task.isCancelled else {
                    newWatcher.stop()
                    return
                }
                self.healthWatcher = newWatcher
                self.healthWatcherSetup = nil
            }
        }
    }

    nonisolated static func canonicalPaths(for url: URL) -> [String] {
        let std = url.standardizedFileURL.path
        var out = [std]
        if let real = realpath(url.path, nil) {
            let resolved = String(cString: real)
            free(real)
            if !out.contains(resolved) { out.append(resolved) }
        } else {
            let parent = url.deletingLastPathComponent()
            if let realParent = realpath(parent.path, nil) {
                let resolvedParent = String(cString: realParent)
                free(realParent)
                let joined = resolvedParent.hasSuffix("/")
                    ? resolvedParent + url.lastPathComponent
                    : resolvedParent + "/" + url.lastPathComponent
                if !out.contains(joined) { out.append(joined) }
            }
        }
        return out
    }

    /// False for changes inside a crate's `.cache/` (logs, launch.conf) or `files/` (game saves), which
    /// never change the library index.
    nonisolated static func isRelevantChange(_ path: String, library: URL) -> Bool {
        for base in canonicalPaths(for: library) where path.hasPrefix(base + "/") {
            let components = path.dropFirst(base.count).split(separator: "/")
            if components.count >= 2, components[0].hasSuffix("." + CrateIO.crateExtension),
               components[1] == ".cache" || components[1] == "files" {
                return false
            }
            return true
        }
        return true
    }

    /// True for changes inside a crate's `files/` directory or a referenced game's external folder,
    /// which can change launch-path or source health without requiring a full library rescan.
    nonisolated static func isHealthRelevantChange(
        _ path: String,
        library: URL,
        referencedRoots: Set<String> = []
    ) -> Bool {
        isHealthRelevantChange(path, libraryBases: canonicalPaths(for: library), referencedRoots: referencedRoots)
    }

    nonisolated static func isHealthRelevantChange(
        _ path: String,
        libraryBases: [String],
        referencedRoots: Set<String> = []
    ) -> Bool {
        for base in libraryBases where path.hasPrefix(base + "/") {
            let components = path.dropFirst(base.count).split(separator: "/")
            if components.count >= 2,
               components[0].hasSuffix("." + CrateIO.crateExtension),
               components[1] == "files" {
                return true
            }
        }
        for refRoot in referencedRoots {
            if path == refRoot || path.hasPrefix(refRoot + "/") {
                return true
            }
        }
        return false
    }

    /// Ignores watcher events until a matching `resumeWatcher()`. Calls nest, so overlapping
    /// operations (an import and a removal) each keep the watcher off until the last one ends.
    public func suppressWatcher() {
        watcherSuppressions += 1
        if debounce != nil { missedWatcherEvent = true }
        debounce?.cancel()
        debounce = nil
        if healthDebounce != nil { missedHealthEvent = true }
        healthDebounce?.cancel()
        healthDebounce = nil
    }

    /// Ends one `suppressWatcher()`. When the last one ends, a reload is scheduled if any change
    /// was ignored meanwhile, so Finder edits made during a batch still show up.
    public func resumeWatcher() {
        watcherSuppressions = max(0, watcherSuppressions - 1)
        if watcherSuppressions == 0 {
            if missedWatcherEvent {
                missedWatcherEvent = false
                missedHealthEvent = false
                scheduleReload()
            } else if missedHealthEvent {
                missedHealthEvent = false
                scheduleHealthRefresh()
            }
        }
    }

    private func scheduleReload() {
        guard !isWatcherSuppressed else {
            missedWatcherEvent = true
            return
        }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.isWatcherSuppressed else { return }
            await self.reload()
        }
    }

    private func scheduleHealthRefresh() {
        guard !isWatcherSuppressed else {
            missedHealthEvent = true
            return
        }
        healthDebounce?.cancel()
        healthDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, !self.isWatcherSuppressed else { return }
            await self.refreshAttention()
        }
    }
}
