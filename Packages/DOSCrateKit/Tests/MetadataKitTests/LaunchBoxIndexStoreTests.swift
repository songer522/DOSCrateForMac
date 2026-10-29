import Foundation
import Testing
@testable import MetadataKit

private actor RequestCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor PhaseCollector {
    var phases: [LaunchBoxIndexStore.Phase] = []
    func append(_ phase: LaunchBoxIndexStore.Phase) {
        phases.append(phase)
    }
}

struct LaunchBoxIndexStoreTests {
    private func makeFixtureZip(in dir: URL, extraGameName: String? = nil) throws -> Data {
        let work = dir.appending(path: "zip-src-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let fixtureURL = Bundle.module.url(forResource: "Metadata", withExtension: "xml", subdirectory: "Fixtures")!
        var xmlText = try String(contentsOf: fixtureURL, encoding: .utf8)
        if let extraGameName {
            let extra = """
              <Game>
                <DatabaseID>999</DatabaseID>
                <Name>\(extraGameName)</Name>
                <ReleaseYear>1995</ReleaseYear>
                <Platform>MS-DOS</Platform>
              </Game>
            </LaunchBox>
            """
            xmlText = xmlText.replacingOccurrences(of: "</LaunchBox>", with: extra)
        }
        let xmlFile = work.appending(path: "Metadata.xml")
        try Data(xmlText.utf8).write(to: xmlFile)

        let zipFile = dir.appending(path: "fixture-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zipFile) }

        let proc = Process()
        proc.executableURL = URL(filePath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", xmlFile.path, zipFile.path]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        return try Data(contentsOf: zipFile)
    }

    private func makeTempDirs() throws -> (root: URL, support: URL, cache: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "index-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let support = root.appending(path: "Support", directoryHint: .isDirectory)
        let cache = root.appending(path: "Cache", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, support, cache)
    }

    @Test func firstUseDownloadsBuildsAndWritesIndex() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipData = try makeFixtureZip(in: root)
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: zipData)
        }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { fixedNow }
        )

        let records = try await store.ensureReady()
        #expect(records.count == 3)
        #expect(await store.downloadedAt == fixedNow)
        let indexFile = support.appending(path: "launchbox-dos.json")
        #expect(FileManager.default.fileExists(atPath: indexFile.path))
        let cacheEntries = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        #expect(cacheEntries.isEmpty)
    }

    @Test func secondUseLoadsFileWithoutNetwork() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipData = try makeFixtureZip(in: root)
        let counter = RequestCounter()
        let session = StubURLProtocol.makeSession { _ in
            await counter.increment()
            return .init(statusCode: 200, data: zipData)
        }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        let firstStore = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { fixedNow }
        )
        _ = try await firstStore.ensureReady()
        #expect(await counter.count == 1)

        let secondStore = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { fixedNow.addingTimeInterval(3600) }
        )
        let records = try await secondStore.ensureReady()
        #expect(records.count == 3)
        #expect(await counter.count == 1)
    }

    @Test func staleIndexReturnsOldThenRebuilds() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipV1 = try makeFixtureZip(in: root)
        let zipV2 = try makeFixtureZip(in: root, extraGameName: "Quake")
        let counter = RequestCounter()
        let session = StubURLProtocol.makeSession { _ in
            await counter.increment()
            let c = await counter.count
            return .init(statusCode: 200, data: c == 1 ? zipV1 : zipV2)
        }

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let store1 = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { t0 }
        )
        let initial = try await store1.ensureReady()
        #expect(initial.count == 3)

        // 31 days later: stale index returns the old 3 records immediately and triggers background refresh.
        let t1 = t0.addingTimeInterval(31 * 86400)
        let store2 = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { t1 }
        )
        let immediate = try await store2.ensureReady()
        #expect(immediate.count == 3)

        // Wait for background rebuild to finish.
        for _ in 0..<50 {
            if await store2.downloadedAt == t1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await store2.downloadedAt == t1)
        let updated = try await store2.ensureReady()
        #expect(updated.count == 4)
        #expect(await counter.count == 2)
    }

    @Test func concurrentEnsureReadySharesOneBuild() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipData = try makeFixtureZip(in: root)
        let counter = RequestCounter()
        let session = StubURLProtocol.makeSession { _ in
            await counter.increment()
            return .init(statusCode: 200, data: zipData, delayNanoseconds: 40_000_000)
        }
        let store = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache
        )

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await store.ensureReady().count
                }
            }
            for try await count in group {
                #expect(count == 3)
            }
        }
        #expect(await counter.count == 1)
    }

    @Test func downloadFailureKeepsOldIndexAndThrows() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipData = try makeFixtureZip(in: root)
        let counter = RequestCounter()
        let session = StubURLProtocol.makeSession { _ in
            await counter.increment()
            let c = await counter.count
            if c == 1 {
                return .init(statusCode: 200, data: zipData)
            } else {
                return .init(statusCode: 500, data: Data("server error".utf8))
            }
        }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache,
            now: { t0 }
        )
        _ = try await store.ensureReady()

        await #expect(throws: LaunchBoxError.self) {
            _ = try await store.refresh()
        }

        // Old index file and records remain intact.
        let reloaded = try await store.ensureReady()
        #expect(reloaded.count == 3)
        #expect(await store.downloadedAt == t0)
    }

    @Test func staleCacheFolderClearedOnInit() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let leftover = cache.appending(path: "partial.zip")
        try Data("leftover".utf8).write(to: leftover)
        #expect(FileManager.default.fileExists(atPath: leftover.path))

        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 500, data: Data())
        }
        _ = LaunchBoxIndexStore(session: session, supportDir: support, cacheDir: cache)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func reportsDownloadingThenBuildingThenReady() async throws {
        let (root, support, cache) = try makeTempDirs()
        defer { try? FileManager.default.removeItem(at: root) }

        let zipData = try makeFixtureZip(in: root)
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: zipData)
        }
        let store = LaunchBoxIndexStore(
            session: session,
            supportDir: support,
            cacheDir: cache
        )
        let collector = PhaseCollector()
        _ = try await store.ensureReady { phase in
            Task { await collector.append(phase) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let phases = await collector.phases

        let hasDownloading = phases.contains {
            if case .downloading = $0 { return true }
            return false
        }
        #expect(hasDownloading)
        #expect(phases.contains(.building))
        #expect(phases.last == .ready)
    }
}
