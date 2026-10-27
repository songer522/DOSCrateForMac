import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public private(set) var records: [GameRecord] = []
    public var library: URL

    @ObservationIgnored private let io: CrateIO
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    public init(library: URL, io: CrateIO = .init()) {
        self.library = library
        self.io = io
    }

    public func reload() async {
        records = await io.scan(library: library)
    }

    public func record(_ id: UUID) -> GameRecord? {
        records.first { $0.id == id }
    }

    /// Writes the game into its crate, keeping any unknown keys currently on disk.
    public func save(_ game: Game) throws {
        guard let index = records.firstIndex(where: { $0.id == game.id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let crate = records[index].crateURL
        let extra = io.extraOnDisk(at: crate) ?? records[index].extra
        try io.save(game, extra: extra, to: crate)
        records[index].game = game
        records[index].extra = extra
        records[index].status = io.loadRecord(at: crate).status
    }

    /// Removes a game. Crates are always moved to the Trash rather than deleted outright, except that a
    /// referenced game's crate holds only metadata, so it is deleted directly when `trashFiles` is false.
    public func remove(_ id: UUID, trashFiles: Bool) throws {
        guard let record = record(id) else { return }
        let fm = FileManager.default
        var isReferenced = false
        if case .referenced = record.game.source { isReferenced = true }
        if trashFiles || !isReferenced {
            try fm.trashItem(at: record.crateURL, resultingItemURL: nil)
        } else {
            try fm.removeItem(at: record.crateURL)
        }
        records.removeAll { $0.id == id }
    }

    public func startWatching() {
        stopWatching()
        watcher = FolderWatcher(url: library) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
        debounce?.cancel()
        debounce = nil
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
