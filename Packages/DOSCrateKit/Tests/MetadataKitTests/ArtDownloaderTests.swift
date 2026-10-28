import Foundation
import LibraryKit
import Testing
@testable import MetadataKit

private actor ConcurrencyTracker {
    var current = 0
    var peak = 0

    func enter() {
        current += 1
        if current > peak { peak = current }
    }

    func exit() {
        current -= 1
    }
}

struct ArtDownloaderTests {
    let io = CrateIO()

    private func makeTempCrate() throws -> (lib: URL, crate: URL) {
        let lib = FileManager.default.temporaryDirectory
            .appending(path: "art-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let crate = try io.makeCrate(title: "Doom", in: lib)
        return (lib, crate)
    }

    @Test func writesAllKindsToCratePaths() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: png)
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
            .disc: URL(string: "https://images.launchbox-app.com/disc.png")!,
            .logo: URL(string: "https://images.launchbox-app.com/logo.png")!,
            .screenshot(1): URL(string: "https://images.launchbox-app.com/s1.png")!,
            .screenshot(2): URL(string: "https://images.launchbox-app.com/s2.png")!,
        ]

        let result = await downloader.download(art, into: crate, mode: .replace)
        #expect(result.written == Set(art.keys))
        #expect(result.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: io.coverURL(crate).path))
        #expect(FileManager.default.fileExists(atPath: io.backURL(crate).path))
        #expect(FileManager.default.fileExists(atPath: io.discURL(crate).path))
        #expect(FileManager.default.fileExists(atPath: io.logoURL(crate).path))
        #expect(io.screenshotURLs(crate).map(\.lastPathComponent) == ["01.png", "02.png"])
    }

    @Test func notFoundAndNonImageAreFailedOthersWritten() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { req in
            switch req.url?.lastPathComponent {
            case "missing.png":
                return .init(statusCode: 404, data: Data("not found".utf8))
            case "html.png":
                return .init(statusCode: 200, data: Data("<html>nope</html>".utf8))
            default:
                return .init(statusCode: 200, data: png)
            }
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/good.png")!,
            .back: URL(string: "https://images.launchbox-app.com/missing.png")!,
            .logo: URL(string: "https://images.launchbox-app.com/html.png")!,
        ]

        let result = await downloader.download(art, into: crate, mode: .replace)
        #expect(result.written == [.front])
        #expect(result.failed == [.back, .logo])
        #expect(FileManager.default.fileExists(atPath: io.coverURL(crate).path))
        #expect(!FileManager.default.fileExists(atPath: io.backURL(crate).path))
        #expect(!FileManager.default.fileExists(atPath: io.logoURL(crate).path))
    }

    @Test func fillEmptySkipsExistingFiles() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let existingBytes = Data("existing-cover".utf8)
        try existingBytes.write(to: io.coverURL(crate))

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: png)
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
        ]

        let result = await downloader.download(art, into: crate, mode: .fillEmpty)
        #expect(result.written == [.back])
        #expect(result.failed.isEmpty)
        #expect(try Data(contentsOf: io.coverURL(crate)) == existingBytes)
        #expect(FileManager.default.fileExists(atPath: io.backURL(crate).path))
    }

    @Test func neverExceedsFourConcurrentRequests() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let tracker = ConcurrencyTracker()
        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { _ in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 40_000_000)
            await tracker.exit()
            return .init(statusCode: 200, data: png)
        }
        let downloader = ArtDownloader(session: session, maxConcurrent: 4)
        var art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
            .disc: URL(string: "https://images.launchbox-app.com/disc.png")!,
            .logo: URL(string: "https://images.launchbox-app.com/logo.png")!,
        ]
        for i in 1...6 {
            art[.screenshot(i)] = URL(string: "https://images.launchbox-app.com/s\(i).png")!
        }

        let result = await downloader.download(art, into: crate, mode: .replace)
        #expect(result.written.count == 10)
        let peak = await tracker.peak
        #expect(peak <= 4)
        #expect(peak >= 2)
    }

    @Test func unwritableCrateSkipsArtWithoutThrowing() async throws {
        let (lib, crate) = try makeTempCrate()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crate.path)
            try? FileManager.default.removeItem(at: lib)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: crate.path)

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: png)
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
        ]

        let result = await downloader.download(art, into: crate, mode: .replace)
        #expect(result.written.isEmpty)
        #expect(result.failed == [.front, .back])
    }

    @Test func cancellationLeavesNoTempFiles() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: png, delayNanoseconds: 500_000_000)
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
        ]

        let task = Task {
            await downloader.download(art, into: crate, mode: .replace)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        _ = await task.value

        let artDir = io.artURL(crate)
        if FileManager.default.fileExists(atPath: artDir.path) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: artDir, includingPropertiesForKeys: nil, options: []
            )
            #expect(entries.filter { $0.lastPathComponent.hasPrefix(".tmp-") }.isEmpty)
        }
    }

    @Test func pngBytesWrittenWithoutReencode() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        // Append a custom marker after a valid PNG so any re-encode through NSBitmapImageRep would strip it.
        let customPNG = StubURLProtocol.makeOnePixelPNG() + Data("DOSCRATE_RAW_PNG_MARKER".utf8)

        let session = StubURLProtocol.makeSession { _ in
            .init(statusCode: 200, data: customPNG)
        }
        let downloader = ArtDownloader(session: session)
        let art: [ArtKind: URL] = [
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
        ]

        let result = await downloader.download(art, into: crate, mode: .replace)
        #expect(result.written == [.front])
        let writtenBytes = try Data(contentsOf: io.coverURL(crate))
        #expect(writtenBytes == customPNG)
    }

    @Test func coverWrittenBeforeScreenshots() async throws {
        let (lib, crate) = try makeTempCrate()
        defer { try? FileManager.default.removeItem(at: lib) }

        let png = StubURLProtocol.makeOnePixelPNG()
        let session = StubURLProtocol.makeSession { req in
            if req.url?.lastPathComponent == "front.png" {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return .init(statusCode: 200, data: png)
        }
        let downloader = ArtDownloader(session: session, maxConcurrent: 4)
        let art: [ArtKind: URL] = [
            .screenshot(1): URL(string: "https://images.launchbox-app.com/s1.png")!,
            .screenshot(2): URL(string: "https://images.launchbox-app.com/s2.png")!,
            .back: URL(string: "https://images.launchbox-app.com/back.png")!,
            .front: URL(string: "https://images.launchbox-app.com/front.png")!,
        ]

        let recorder = OrderRecorder()
        let result = await downloader.download(art, into: crate, mode: .replace) { kind in
            recorder.append(kind)
        }
        #expect(result.written.count == 4)
        #expect(recorder.items.first == .front)
    }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArtKind] = []

    func append(_ kind: ArtKind) {
        lock.withLock { storage.append(kind) }
    }

    var items: [ArtKind] {
        lock.withLock { storage }
    }
}
