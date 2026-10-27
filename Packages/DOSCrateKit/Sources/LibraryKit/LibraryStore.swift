import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var records: [GameRecord] = []
    public var library: URL
    /// Test hook called at the start of every `reload()`.
    @ObservationIgnored public var onReload: (@MainActor () -> Void)?
    /// While true, file-watcher events are ignored so a running batch import or removal controls reload timing.
    public var isWatcherSuppressed: Bool { watcherSuppressions > 0 }
    @ObservationIgnored private var watcherSuppressions = 0

    @ObservationIgnored private let io: CrateIO
    @ObservationIgnored private let scan: @Sendable (URL) async -> [GameRecord]
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Bumped by every reload and every local change, so a scan that started earlier can't overwrite newer state.
    @ObservationIgnored private var generation = 0

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
    }

    public func record(_ id: UUID) -> GameRecord? {
        records.first { $0.id == id }
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
        records[index].game = game
        records[index].extra = extra
        records[index].status = io.loadRecord(at: crate).status
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
    }

    /// Removes several games, trashing off the main actor in small chunks so the library shrinks as it goes.
    /// `onProgress` gets (done, total) after each chunk. Returns a "Title: reason" line for each failure;
    /// a game whose folder can't be trashed keeps its crate.
    public func remove(
        _ ids: [UUID], trashFiles: Bool, onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async -> [String] {
        let targets = ids.compactMap(record)
        guard !targets.isEmpty else { return [] }
        // Each trashed crate would otherwise trigger a full rescan of the library.
        suppressWatcher()
        defer { resumeWatcher() }
        let io = self.io
        var failures: [String] = []
        var done = 0
        for start in stride(from: 0, to: targets.count, by: 20) {
            let chunk = Array(targets[start..<min(start + 20, targets.count)])
            generation += 1
            let (removed, chunkFailures) = await Task.detached { () -> (Set<UUID>, [String]) in
                let fm = FileManager.default
                var removed = Set<UUID>()
                var failures: [String] = []
                for record in chunk {
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
                return (removed, failures)
            }.value
            generation += 1
            records.removeAll { removed.contains($0.id) }
            failures += chunkFailures
            done += chunk.count
            onProgress?(done, targets.count)
        }
        return failures
    }

    public func startWatching() {
        stopWatching()
        let library = self.library
        watcher = FolderWatcher(url: library, isRelevant: { Self.isRelevantChange($0, library: library) }) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        debounce?.cancel()
        debounce = nil
    }

    /// False for changes inside a crate's `.cache/` (logs, launch.conf) or `files/` (game saves), which
    /// never change the library index.
    nonisolated static func isRelevantChange(_ path: String, library: URL) -> Bool {
        var bases = [library.standardizedFileURL.path]
        if let real = realpath(library.path, nil) {
            bases.append(String(cString: real))
            free(real)
        }
        for base in bases where path.hasPrefix(base + "/") {
            let components = path.dropFirst(base.count).split(separator: "/")
            if components.count >= 2, components[0].hasSuffix("." + CrateIO.crateExtension),
               components[1] == ".cache" || components[1] == "files" {
                return false
            }
            return true
        }
        return true
    }

    /// Ignores watcher events until a matching `resumeWatcher()`. Calls nest, so overlapping
    /// operations (an import and a removal) each keep the watcher off until the last one ends.
    public func suppressWatcher() {
        watcherSuppressions += 1
        debounce?.cancel()
        debounce = nil
    }

    public func resumeWatcher() {
        watcherSuppressions = max(0, watcherSuppressions - 1)
    }

    private func scheduleReload() {
        guard !isWatcherSuppressed else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, !self.isWatcherSuppressed else { return }
            await self.reload()
        }
    }
}
