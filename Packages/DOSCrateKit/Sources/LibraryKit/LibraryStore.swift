import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var records: [GameRecord] = []
    public var library: URL

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

    private func scheduleReload() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
