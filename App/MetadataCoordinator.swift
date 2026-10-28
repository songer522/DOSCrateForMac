import Foundation
import LibraryKit
import MetadataKit
import Observation

protocol MetadataProviding: Sendable {
    var downloadedAt: Date? { get async }
    func ensureReady(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord]
    func refresh(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord]
    func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult
}

struct LaunchBoxProvider: MetadataProviding {
    let store: LaunchBoxIndexStore
    let downloader: ArtDownloader

    init(
        session: URLSession = .shared,
        supportDir: URL? = nil,
        cacheDir: URL? = nil
    ) {
        let fm = FileManager.default
        let resolvedSupport = supportDir ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DOSCrate", directoryHint: .isDirectory)
        let resolvedCache = cacheDir ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "DOSCrate/launchbox", directoryHint: .isDirectory)
        self.store = LaunchBoxIndexStore(
            session: session,
            supportDir: resolvedSupport,
            cacheDir: resolvedCache
        )
        self.downloader = ArtDownloader(session: session)
    }

    var downloadedAt: Date? {
        get async { await store.downloadedAt }
    }

    func ensureReady(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        try await store.ensureReady(onPhase: onPhase)
    }

    func refresh(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        try await store.refresh(onPhase: onPhase)
    }

    func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult {
        await downloader.download(art, into: crate, mode: mode)
    }
}

struct NoOpMetadataProvider: MetadataProviding {
    var downloadedAt: Date? {
        get async { nil }
    }

    func ensureReady(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        []
    }

    func refresh(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord] {
        []
    }

    func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult {
        ArtResult()
    }
}

enum ApplyOutcome: Equatable, Sendable {
    case applied(artFailed: Bool)
    case artNotWritable
    case cancelled
    case gameMissing
}

@MainActor @Observable
final class MetadataCoordinator {
    let provider: any MetadataProviding
    let prefs: Preferences
    weak var model: AppModel?

    var phase: LaunchBoxIndexStore.Phase = .idle
    var lastUpdated: Date?
    private(set) var unmatched: [UUID] = []
    private(set) var findMissingProgress: (current: Int, total: Int)?
    var isFindingMissing: Bool { findMissingProgress != nil }

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedQueueIDs: Set<UUID> = []
    @ObservationIgnored private var findMissingTask: Task<Void, Never>?
    @ObservationIgnored private var findMissingCancelled = false

    init(provider: any MetadataProviding, prefs: Preferences) {
        self.provider = provider
        self.prefs = prefs
        Task { [weak self] in
            guard let self else { return }
            self.lastUpdated = await provider.downloadedAt
        }
    }

    static func unmatchedStatusText(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? "1 game without a LaunchBox match"
            : "\(count) games without a LaunchBox match"
    }

    var unmatchedStatusText: String? {
        guard findMissingProgress == nil else { return nil }
        switch phase {
        case .idle, .ready:
            return Self.unmatchedStatusText(count: unmatched.count)
        case .downloading, .building, .failed:
            return nil
        }
    }

    var showsUnmatchedReview: Bool {
        unmatchedStatusText != nil
    }

    var showsFindMissingCancel: Bool {
        guard findMissingProgress != nil else { return false }
        switch phase {
        case .idle, .ready:
            return true
        case .downloading, .building, .failed:
            return false
        }
    }

    var statusText: String? {
        switch phase {
        case .idle, .ready:
            if let progress = findMissingProgress {
                return "Finding metadata… \(progress.current) of \(progress.total)"
            }
            return unmatchedStatusText
        case .downloading(let fraction):
            return "Downloading LaunchBox data… \(Int((min(1.0, max(0.0, fraction)) * 100).rounded()))%"
        case .building:
            return "Building LaunchBox index…"
        case .failed:
            return "LaunchBox data unavailable"
        }
    }

    static func needsMissingMetadata(_ record: GameRecord, io: CrateIO = CrateIO()) -> Bool {
        let g = record.game
        guard g.metadataSource == nil else { return false }
        let missingYear = (g.year == nil)
        let missingDeveloper = (g.developer == nil || g.developer?.isEmpty == true)
        let missingPublisher = (g.publisher == nil || g.publisher?.isEmpty == true)
        let missingGenre = (g.genre == nil || g.genre?.isEmpty == true)
        let missingDescription = g.description.isEmpty
        let missingCover = !FileManager.default.fileExists(atPath: io.coverURL(record.crateURL).path)
        return missingYear || missingDeveloper || missingPublisher || missingGenre || missingDescription || missingCover
    }

    func findMissingMetadata() {
        guard findMissingTask == nil, let model else { return }
        let io = CrateIO()
        let targets = model.store.records
            .filter { !model.isActive($0.id) && !model.pendingRemovalIDs.contains($0.id) && Self.needsMissingMetadata($0, io: io) }
            .map(\.id)
        guard !targets.isEmpty else { return }

        findMissingCancelled = false
        findMissingProgress = (current: 1, total: targets.count)
        findMissingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.findMissingTask = nil
                self.findMissingProgress = nil
                self.findMissingCancelled = false
            }
            for (index, id) in targets.enumerated() {
                if Task.isCancelled || self.findMissingCancelled { break }
                self.findMissingProgress = (current: index + 1, total: targets.count)
                self.tasks[id]?.cancel()
                self.failedQueueIDs.remove(id)
                let itemTask = Task { [weak self] in
                    guard let self else { return }
                    await self.runAutoFetch(for: id)
                }
                self.tasks[id] = itemTask
                await itemTask.value
            }
        }
    }

    func cancelFindMissing() {
        findMissingCancelled = true
    }

    func dismissUnmatched() {
        unmatched.removeAll()
    }

    func removeUnmatched(_ id: UUID) {
        unmatched.removeAll { $0 == id }
    }

    private func addUnmatched(_ id: UUID) {
        if !unmatched.contains(id) {
            unmatched.append(id)
        }
    }

    func importedGame(_ id: UUID) {
        guard prefs.fetchMetadataOnImport else { return }
        tasks[id]?.cancel()
        failedQueueIDs.remove(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.runAutoFetch(for: id)
        }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        failedQueueIDs.remove(id)
    }

    func retry() {
        let retryIDs = failedQueueIDs
        failedQueueIDs.removeAll()
        if !retryIDs.isEmpty {
            for id in retryIDs {
                importedGame(id)
            }
        } else {
            refreshIndex()
        }
    }

    func refreshIndex() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.provider.refresh { [weak self] newPhase in
                    Task { @MainActor in self?.phase = newPhase }
                }
                self.phase = .ready
                self.lastUpdated = await self.provider.downloadedAt
            } catch {
                if case .failed = self.phase {} else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func candidates(for title: String) async throws -> [MatchCandidate] {
        do {
            let records = try await provider.ensureReady { [weak self] newPhase in
                Task { @MainActor in self?.phase = newPhase }
            }
            phase = .ready
            lastUpdated = await provider.downloadedAt
            return TitleMatcher.search(for: title, in: records, limit: 8)
        } catch {
            if case .failed = phase {} else {
                phase = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func apply(_ record: LaunchBoxRecord, to id: UUID, mode: ApplyMode) async -> ApplyOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let model, !model.isActive(id), !model.pendingRemovalIDs.contains(id),
              let initialRecord = await resolveRecord(id, in: model)
        else {
            return Task.isCancelled ? .cancelled : .gameMissing
        }

        let patch = MetadataApplier.patch(from: record)
        let crateURL = initialRecord.crateURL
        let io = CrateIO()

        var referencedUnwritable = false
        if case .referenced = initialRecord.game.source {
            if let folder = try? io.referencedFolderURL(for: initialRecord) {
                if !FileManager.default.isWritableFile(atPath: folder.path) {
                    referencedUnwritable = true
                }
            } else {
                referencedUnwritable = true
            }
        }

        let artResult: ArtResult
        if referencedUnwritable {
            artResult = ArtResult(written: [], failed: Set(patch.art.keys))
        } else {
            artResult = await provider.download(patch.art, into: crateURL, mode: mode)
        }

        guard !Task.isCancelled else { return .cancelled }
        guard !model.isActive(id), !model.pendingRemovalIDs.contains(id),
              let latestRecord = model.store.record(id)
        else {
            return .cancelled
        }

        let updatedGame = MetadataApplier.apply(patch, to: latestRecord.game, mode: mode, now: Date())
        do {
            try model.store.save(updatedGame)
            removeUnmatched(id)
        } catch {
            return .cancelled
        }

        if referencedUnwritable || (!patch.art.isEmpty && artResult.written.isEmpty && !artResult.failed.isEmpty) {
            return .artNotWritable
        }
        return .applied(artFailed: !artResult.failed.isEmpty)
    }

    private func runAutoFetch(for id: UUID) async {
        defer { tasks[id] = nil }
        guard !Task.isCancelled else { return }
        guard let model, !model.isActive(id), !model.pendingRemovalIDs.contains(id),
              let initialRecord = await resolveRecord(id, in: model)
        else { return }

        let records: [LaunchBoxRecord]
        do {
            records = try await provider.ensureReady { [weak self] newPhase in
                Task { @MainActor in self?.phase = newPhase }
            }
            phase = .ready
            lastUpdated = await provider.downloadedAt
        } catch {
            if case .failed = phase {} else {
                phase = .failed(error.localizedDescription)
            }
            failedQueueIDs.insert(id)
            return
        }

        guard !Task.isCancelled else { return }
        guard !model.isActive(id), !model.pendingRemovalIDs.contains(id),
              let currentRecord = model.store.record(id) ?? initialRecord as GameRecord?
        else { return }

        guard let matched = TitleMatcher.autoMatch(for: currentRecord.game.title, in: records) else {
            addUnmatched(id)
            return
        }

        _ = await apply(matched, to: id, mode: .fillEmpty)
    }

    private func resolveRecord(_ id: UUID, in model: AppModel) async -> GameRecord? {
        if let rec = model.store.record(id) {
            return rec
        }
        for _ in 0..<150 {
            if Task.isCancelled { return nil }
            if let rec = model.store.record(id) { return rec }
            if model.imports.progress == nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model.store.record(id)
    }
}
