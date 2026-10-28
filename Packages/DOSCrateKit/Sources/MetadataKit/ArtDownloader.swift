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
    private static let logger = Logger(subsystem: "com.songer522.DOSCrate", category: "metadata")
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    public let session: URLSession
    public let maxConcurrent: Int

    public init(session: URLSession = .shared, maxConcurrent: Int = 4) {
        self.session = session
        self.maxConcurrent = max(1, maxConcurrent)
    }

    public func download(
        _ art: [ArtKind: URL],
        into crate: URL,
        mode: ApplyMode,
        onWrite: @escaping @Sendable (ArtKind) -> Void = { _ in }
    ) async -> ArtResult {
        let io = CrateIO()
        let fm = FileManager.default

        var pending: [(ArtKind, URL)] = art.compactMap { kind, url in
            if mode == .fillEmpty {
                let dest = kind.fileURL(in: crate, io: io)
                if fm.fileExists(atPath: dest.path) {
                    return nil
                }
            }
            return (kind, url)
        }
        pending.sort { $0.0.sortRank < $1.0.sortRank }

        guard !pending.isEmpty else {
            return ArtResult()
        }

        var written = Set<ArtKind>()
        var failed = Set<ArtKind>()
        let session = self.session

        // Start and write the front cover first so the cover appears immediately.
        if pending.first?.0 == .front {
            let (frontKind, frontURL) = pending.removeFirst()
            if let (_, ok) = await Self.downloadOne(
                kind: frontKind,
                url: frontURL,
                into: crate,
                session: session,
                onWrite: onWrite
            ) {
                if ok {
                    written.insert(frontKind)
                } else {
                    failed.insert(frontKind)
                }
            }
            if pending.isEmpty || Task.isCancelled {
                return ArtResult(written: written, failed: failed)
            }
        }

        let limit = min(maxConcurrent, pending.count)

        return await withTaskGroup(of: (ArtKind, Bool)?.self) { group in
            var index = 0
            for _ in 0..<limit {
                let (kind, url) = pending[index]
                index += 1
                group.addTask {
                    await Self.downloadOne(
                        kind: kind,
                        url: url,
                        into: crate,
                        session: session,
                        onWrite: onWrite
                    )
                }
            }

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
                        await Self.downloadOne(
                            kind: kind,
                            url: url,
                            into: crate,
                            session: session,
                            onWrite: onWrite
                        )
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
        session: URLSession,
        onWrite: @Sendable (ArtKind) -> Void
    ) async -> (ArtKind, Bool)? {
        if Task.isCancelled { return nil }
        let io = CrateIO()
        let destination = kind.fileURL(in: crate, io: io)
        let fm = FileManager.default
        let clock = ContinuousClock()

        do {
            let destDir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

            let downloadStart = clock.now
            let (data, response) = try await session.data(from: url)
            let downloadElapsed = clock.now - downloadStart
            logger.debug("Art download (\(String(describing: kind), privacy: .public)) took \(downloadElapsed, privacy: .public)")
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                logger.warning("Art download HTTP failure for \(url.absoluteString, privacy: .public)")
                return (kind, false)
            }

            let encodeStart = clock.now
            guard let rep = NSBitmapImageRep(data: data) else {
                logger.warning("Art decode failure for \(url.absoluteString, privacy: .public)")
                return (kind, false)
            }

            let pngData: Data
            if data.starts(with: pngSignature) {
                pngData = data
            } else {
                guard let converted = rep.representation(using: .png, properties: [:]) else {
                    logger.warning("Art PNG encode failure for \(url.absoluteString, privacy: .public)")
                    return (kind, false)
                }
                pngData = converted
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
            let writeElapsed = clock.now - encodeStart
            logger.debug("Art encode+write (\(String(describing: kind), privacy: .public)) took \(writeElapsed, privacy: .public)")
            onWrite(kind)
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
