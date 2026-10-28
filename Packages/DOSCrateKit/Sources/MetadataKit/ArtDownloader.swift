import AppKit
import Foundation
import LibraryKit
import os

public struct ArtResult: Sendable, Equatable {
    public var written: Set<ArtKind>
    public var failed: Set<ArtKind>

    public init(written: Set<ArtKind> = [], failed: Set<ArtKind> = []) {
        self.written = written
        self.failed = failed
    }
}

public struct ArtDownloader: Sendable {
    private static let logger = Logger(subsystem: "com.songer522.DOSCrate", category: "ArtDownloader")

    public let session: URLSession
    public let maxConcurrent: Int

    public init(session: URLSession = .shared, maxConcurrent: Int = 4) {
        self.session = session
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode
    ) async -> ArtResult {
        let io = CrateIO()
        let fm = FileManager.default

        let pending: [(ArtKind, URL)] = art.compactMap { kind, url in
            if mode == .fillEmpty {
                let dest = kind.fileURL(in: crate, io: io)
                if fm.fileExists(atPath: dest.path) {
                    return nil
                }
            }
            return (kind, url)
        }

        guard !pending.isEmpty else {
            return ArtResult()
        }

        let limit = min(maxConcurrent, pending.count)
        let session = self.session

        return await withTaskGroup(of: (ArtKind, Bool)?.self) { group in
            var index = 0
            for _ in 0..<limit {
                let (kind, url) = pending[index]
                index += 1
                group.addTask {
                    await Self.downloadOne(kind: kind, url: url, into: crate, session: session)
                }
            }

            var written = Set<ArtKind>()
            var failed = Set<ArtKind>()

            while let outcome = await group.next() {
                if let (kind, ok) = outcome {
                    if ok {
                        written.insert(kind)
                    } else {
                        failed.insert(kind)
                    }
                }
                if index < pending.count, !Task.isCancelled {
                    let (kind, url) = pending[index]
                    index += 1
                    group.addTask {
                        await Self.downloadOne(kind: kind, url: url, into: crate, session: session)
                    }
                }
            }

            return ArtResult(written: written, failed: failed)
        }
    }

    private static func downloadOne(
        kind: ArtKind,
        url: URL,
        into crate: URL,
        session: URLSession
    ) async -> (ArtKind, Bool)? {
        if Task.isCancelled { return nil }
        let io = CrateIO()
        let destination = kind.fileURL(in: crate, io: io)
        let fm = FileManager.default

        do {
            // Verify crate parent directory is writable before/after downloading.
            let destDir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.warning("Art download HTTP failure for \(url.absoluteString, privacy: .public)")
                return (kind, false)
            }

            guard let rep = NSBitmapImageRep(data: data),
                  let pngData = rep.representation(using: .png, properties: [:])
            else {
                logger.warning("Art decode failure for \(url.absoluteString, privacy: .public)")
                return (kind, false)
            }

            try Task.checkCancellation()

            var replacementDir: URL?
            let tempFile: URL
            if let repDir = try? fm.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: crate,
                create: true
            ) {
                replacementDir = repDir
                tempFile = repDir.appending(path: "\(UUID().uuidString).png", directoryHint: .notDirectory)
            } else {
                let artDir = io.artURL(crate)
                try fm.createDirectory(at: artDir, withIntermediateDirectories: true)
                tempFile = artDir.appending(path: ".tmp-\(UUID().uuidString).png", directoryHint: .notDirectory)
            }

            defer {
                try? fm.removeItem(at: tempFile)
                if let replacementDir {
                    try? fm.removeItem(at: replacementDir)
                }
            }

            try pngData.write(to: tempFile)
            try Task.checkCancellation()

            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempFile)
            } else {
                try fm.moveItem(at: tempFile, to: destination)
            }
            return (kind, true)
        } catch is CancellationError {
            return nil
        } catch let urlError as URLError where urlError.code == .cancelled {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            logger.warning("Art write failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (kind, false)
        }
    }
}
