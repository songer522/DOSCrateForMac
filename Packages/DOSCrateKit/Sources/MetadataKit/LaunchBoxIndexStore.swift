import Foundation
import LibraryKit
import os

public actor LaunchBoxIndexStore {
    private static let logger = Logger(subsystem: "com.songer522.DOSCrate", category: "metadata")
    public enum Phase: Sendable, Equatable {
        case idle
        case downloading(Double)
        case building
        case ready
        case failed(String)
    }

    public static let indexFileName = "launchbox-dos.json"

    private let session: URLSession
    private let supportDir: URL
    private let cacheDir: URL
    private let now: @Sendable () -> Date
    private let maxAge: TimeInterval

    private var cachedIndex: LaunchBoxIndex?
    private var inFlightTask: Task<[LaunchBoxRecord], Error>?
    private var phaseCallbacks: [UUID: @Sendable (Phase) -> Void] = [:]

    public init(
        session: URLSession = .shared,
        supportDir: URL,
        cacheDir: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        maxAge: TimeInterval = 30 * 86400
    ) {
        self.session = session
        self.supportDir = supportDir
        self.cacheDir = cacheDir
        self.now = now
        self.maxAge = maxAge
        try? FileManager.default.removeItem(at: cacheDir)
    }

    public var downloadedAt: Date? {
        if let cachedIndex {
            return cachedIndex.downloadedAt
        }
        if let disk = loadFromDisk() {
            cachedIndex = disk
            return disk.downloadedAt
        }
        return nil
    }

    public func ensureReady(
        onPhase: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> [LaunchBoxRecord] {
        let clock = ContinuousClock()
        if cachedIndex == nil {
            let loadStart = clock.now
            cachedIndex = loadFromDisk()
            Self.logger.debug("index disk load took \(clock.now - loadStart, privacy: .public)")
        }
        if let existing = cachedIndex {
            let age = now().timeIntervalSince(existing.downloadedAt)
            if age <= maxAge {
                onPhase(.ready)
                Self.logger.debug("ensureReady served \(existing.games.count) records from in-memory cache")
                return existing.games
            }
            // Stale index: return old records immediately and refresh in the background.
            startBackgroundRefresh(onPhase: onPhase)
            return existing.games
        }
        return try await runOrJoinBuild(onPhase: onPhase)
    }

    public func refresh(
        onPhase: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> [LaunchBoxRecord] {
        try await runOrJoinBuild(onPhase: onPhase)
    }

    private func startBackgroundRefresh(onPhase: @escaping @Sendable (Phase) -> Void) {
        Task {
            _ = try? await self.runOrJoinBuild(onPhase: onPhase)
        }
    }

    private func runOrJoinBuild(
        onPhase: @escaping @Sendable (Phase) -> Void
    ) async throws -> [LaunchBoxRecord] {
        let callbackID = UUID()
        phaseCallbacks[callbackID] = onPhase
        defer { phaseCallbacks.removeValue(forKey: callbackID) }

        if let existingTask = inFlightTask {
            return try await existingTask.value
        }

        let task = Task<[LaunchBoxRecord], Error> {
            try await self.performBuild()
        }
        inFlightTask = task
        do {
            let result = try await task.value
            inFlightTask = nil
            return result
        } catch {
            inFlightTask = nil
            throw error
        }
    }

    private func notify(_ phase: Phase) {
        for cb in phaseCallbacks.values {
            cb(phase)
        }
    }

    private func performBuild() async throws -> [LaunchBoxRecord] {
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: cacheDir)
        }

        do {
            try? fm.removeItem(at: cacheDir)
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            notify(.downloading(0.0))
            let delegate = DownloadProgressDelegate { [weak self] fraction in
                guard let self else { return }
                Task { await self.notify(.downloading(fraction)) }
            }

            let (tempFileURL, response): (URL, URLResponse)
            do {
                (tempFileURL, response) = try await session.download(
                    from: LaunchBoxEndpoints.metadataZipURL,
                    delegate: delegate
                )
            } catch {
                throw LaunchBoxError.download(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw LaunchBoxError.download("HTTP \(code)")
            }

            let zipURL = cacheDir.appending(path: "Metadata.zip", directoryHint: .notDirectory)
            if fm.fileExists(atPath: zipURL.path) {
                try? fm.removeItem(at: zipURL)
            }
            do {
                try fm.moveItem(at: tempFileURL, to: zipURL)
            } catch {
                throw LaunchBoxError.download(error.localizedDescription)
            }

            notify(.building)

            let extractDir = cacheDir.appending(path: "extracted", directoryHint: .isDirectory)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            do {
                try await Ditto.unzip(zipURL, into: extractDir)
            } catch DittoError.failed(let msg) {
                throw LaunchBoxError.unzip(msg)
            } catch {
                throw LaunchBoxError.unzip(error.localizedDescription)
            }

            let xmlURL = extractDir.appending(path: "Metadata.xml", directoryHint: .notDirectory)
            guard fm.fileExists(atPath: xmlURL.path) else {
                throw LaunchBoxError.parse("Metadata.xml missing from archive")
            }

            let records = try LaunchBoxIndexBuilder.build(xml: xmlURL)
            let newIndex = LaunchBoxIndex(
                formatVersion: LaunchBoxIndex.currentFormatVersion,
                downloadedAt: now(),
                games: records
            )

            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(newIndex)
            let indexFile = supportDir.appending(path: Self.indexFileName, directoryHint: .notDirectory)
            try data.write(to: indexFile, options: .atomic)

            cachedIndex = newIndex
            notify(.ready)
            return records
        } catch let lbError as LaunchBoxError {
            notify(.failed(Self.describe(lbError)))
            throw lbError
        } catch {
            let wrapped = LaunchBoxError.parse(error.localizedDescription)
            notify(.failed(error.localizedDescription))
            throw wrapped
        }
    }

    private static func describe(_ error: LaunchBoxError) -> String {
        switch error {
        case .download(let s), .unzip(let s), .parse(let s):
            s
        }
    }

    private func loadFromDisk() -> LaunchBoxIndex? {
        let indexFile = supportDir.appending(path: Self.indexFileName, directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: indexFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(LaunchBoxIndex.self, from: data),
              decoded.formatVersion == LaunchBoxIndex.currentFormatVersion
        else { return nil }
        return decoded
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
