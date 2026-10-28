import Foundation
import LibraryKit
import MetadataKit
import Observation
import os

protocol MetadataProviding: Sendable {
    var downloadedAt: Date? { get async }
    func ensureReady(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord]
    func refresh(onPhase: @escaping @Sendable (LaunchBoxIndexStore.Phase) -> Void) async throws -> [LaunchBoxRecord]
    func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode,
        onWrite: @escaping @Sendable (ArtKind) -> Void
    ) async -> ArtResult
}

extension MetadataProviding {
    func download(_ art: [ArtKind: URL], into crate: URL, mode: ApplyMode) async -> ArtResult {
        await download(art, into: crate, mode: mode, onWrite: { _ in })
    }
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

    func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode,
        onWrite: @escaping @Sendable (ArtKind) -> Void
    ) async -> ArtResult {
        await downloader.download(art, into: crate, mode: mode, onWrite: onWrite)
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

    func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode,
        onWrite: @escaping @Sendable (ArtKind) -> Void
    ) async -> ArtResult {
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
    private static let logger = Logger(subsystem: "com.songer522.DOSCrate", category: "metadata")

    let provider: any MetadataProviding
    let prefs: Preferences
    weak var model: AppModel?

    var phase: LaunchBoxIndexStore.Phase = .idle
    var lastUpdated: Date?
    var unmatched: [UUID] = []
    private(set) var findMissingProgress: (current: Int, total: Int)?
    var isFindingMissing: Bool { findMissingProgress != nil }
    private(set) var artLoading: Set<UUID> = []
    private(set) var artRevision: [UUID: Int] = [:]
    private(set) var applyingIDs: Set<UUID> = []
    private(set) var lastOutcome: [UUID: ApplyOutcome] = [:]
    var artErrorMessage: String?

    private struct ArtTaskEntry {
        let token: UUID
        let task: Task<Void, Never>
    }

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var artTasks: [UUID: ArtTaskEntry] = [:]
    @ObservationIgnored private var pendingStoreIDs: [UUID] = []
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

    func isApplying(_ id: UUID) -> Bool {
        applyingIDs.contains(id)
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
                await self.enqueueAutoFetch(id)?.value
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
        enqueueAutoFetch(id)
    }

    @discardableResult
    func enqueueAutoFetch(_ id: UUID) -> Task<Void, Never>? {
        tasks[id]?.cancel()
        failedQueueIDs.remove(id)
        if model?.store.record(id) == nil {
            if !pendingStoreIDs.contains(id) {
                pendingStoreIDs.append(id)
            }
            return nil
        }
        pendingStoreIDs.removeAll { $0 == id }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAutoFetch(for: id)
        }
        tasks[id] = task
        return task
    }

    func storeDidReload() {
        guard let model, !pendingStoreIDs.isEmpty else { return }
        let readyIDs = pendingStoreIDs.filter { model.store.record($0) != nil }
        for id in readyIDs {
            enqueueAutoFetch(id)
        }
    }

    func cancel(_ id: UUID) {
        pendingStoreIDs.removeAll { $0 == id }
        tasks[id]?.cancel()
        tasks[id] = nil
        artTasks[id]?.task.cancel()
        artTasks[id] = nil
        artLoading.remove(id)
        applyingIDs.remove(id)
        failedQueueIDs.remove(id)
    }

    func retry() {
        let retryIDs = failedQueueIDs
        failedQueueIDs.removeAll()
        if !retryIDs.isEmpty {
            for id in retryIDs {
                enqueueAutoFetch(id)
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
        let clock = ContinuousClock()
        do {
            let start = clock.now
            let records = try await provider.ensureReady { [weak self] newPhase in
                Task { @MainActor in self?.phase = newPhase }
            }
            Self.logger.debug("ensureReady in candidates took \(clock.now - start, privacy: .public)")
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
        let clock = ContinuousClock()
        guard !Task.isCancelled else { return .cancelled }
        let readStart = clock.now
        guard let model, !model.isActive(id), !model.pendingRemovalIDs.contains(id) else {
            return Task.isCancelled ? .cancelled : .gameMissing
        }
        model.flushPendingWrites(for: id)
        guard let latestRecord = model.store.record(id) else {
            return Task.isCancelled ? .cancelled : .gameMissing
        }
        Self.logger.debug("record read in apply took \(clock.now - readStart, privacy: .public)")

        applyingIDs.insert(id)
        defer { applyingIDs.remove(id) }

        artTasks[id]?.task.cancel()
        artTasks[id] = nil
        artLoading.remove(id)

        let patch = MetadataApplier.patch(from: record)
        let crateURL = latestRecord.crateURL
        let io = CrateIO()

        // 1. Save metadata fields and metadataSource immediately.
        let updatedGame = MetadataApplier.apply(patch, to: latestRecord.game, mode: mode, now: Date())
        let saveStart = clock.now
        do {
            try model.store.save(updatedGame)
            removeUnmatched(id)
        } catch {
            return .cancelled
        }
        Self.logger.debug("store.save in apply took \(clock.now - saveStart, privacy: .public)")

        // 2. Check if referenced game folder is unwritable.
        var referencedUnwritable = false
        if case .referenced = latestRecord.game.source {
            if let folder = try? io.referencedFolderURL(for: latestRecord) {
                if !FileManager.default.isWritableFile(atPath: folder.path) {
                    referencedUnwritable = true
                }
            } else {
                referencedUnwritable = true
            }
        }

        if referencedUnwritable {
            lastOutcome[id] = .artNotWritable
            if mode == .replace {
                reportArtFailure()
            }
            return .artNotWritable
        }

        let fm = FileManager.default
        let pendingArt = patch.art.filter { kind, _ in
            guard mode == .fillEmpty else { return true }
            return !fm.fileExists(atPath: kind.fileURL(in: crateURL, io: io).path)
        }

        guard !pendingArt.isEmpty else {
            lastOutcome[id] = .applied(artFailed: false)
            return .applied(artFailed: false)
        }

        let token = UUID()
        lastOutcome[id] = nil
        artLoading.insert(id)
        let artTask = Task { [weak self] in
            guard let self else { return }
            await self.runBackgroundArt(pendingArt, for: id, token: token, crateURL: crateURL, mode: mode)
        }
        artTasks[id] = ArtTaskEntry(token: token, task: artTask)
        return .applied(artFailed: false)
    }

    private func runBackgroundArt(
        _ art: [ArtKind: URL],
        for id: UUID,
        token: UUID,
        crateURL: URL,
        mode: ApplyMode
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        let result = await provider.download(art, into: crateURL, mode: mode) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.artTasks[id]?.token == token else { return }
                self.artRevision[id, default: 0] += 1
            }
        }
        Self.logger.debug("background art download for \(id, privacy: .public) took \(clock.now - start, privacy: .public)")

        guard artTasks[id]?.token == token else { return }
        artTasks[id] = nil
        artLoading.remove(id)
        guard !Task.isCancelled else {
            lastOutcome[id] = .cancelled
            return
        }
        artRevision[id, default: 0] += 1

        if !art.isEmpty && result.written.isEmpty && !result.failed.isEmpty {
            lastOutcome[id] = .artNotWritable
            if mode == .replace {
                reportArtFailure()
            }
        } else {
            lastOutcome[id] = .applied(artFailed: !result.failed.isEmpty)
        }
    }

    private func reportArtFailure() {
        let message = "The game information was saved, but the art files couldn't be written."
        artErrorMessage = message
        if let model, model.prefs.appTheme != .dos || model.findMetadataFor == nil {
            model.alert = AppAlert(title: "Couldn't save art", message: message)
        }
    }

    private func runAutoFetch(for id: UUID) async {
        let clock = ContinuousClock()
        defer { tasks[id] = nil }
        guard !Task.isCancelled else { return }
        guard let model, !model.isActive(id), !model.pendingRemovalIDs.contains(id),
              model.store.record(id) != nil
        else { return }

        let records: [LaunchBoxRecord]
        do {
            let start = clock.now
            records = try await provider.ensureReady { [weak self] newPhase in
                Task { @MainActor in self?.phase = newPhase }
            }
            Self.logger.debug("ensureReady in runAutoFetch took \(clock.now - start, privacy: .public)")
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
        guard !model.isActive(id), !model.pendingRemovalIDs.contains(id) else { return }
        model.flushPendingWrites(for: id)
        guard let currentRecord = model.store.record(id) else { return }

        guard let matched = TitleMatcher.autoMatch(for: currentRecord.game.title, in: records) else {
            addUnmatched(id)
            return
        }

        _ = await apply(matched, to: id, mode: .fillEmpty)
        await artTasks[id]?.task.value
    }
}
