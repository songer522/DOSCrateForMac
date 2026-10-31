import Foundation
import LibraryKit

public enum ImportKind: Sendable {
    case folder, zip, discImage, floppyImage
}

public enum ImportMode: Sendable {
    case copy, reference
}

public enum DuplicateAction: String, Sendable, Equatable, CaseIterable {
    case skip
    case replace
    case keepBoth
}

public struct DuplicateMatch: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sameSource
        case sameTitle
    }

    public var record: GameRecord
    public var kind: Kind

    public init(record: GameRecord, kind: Kind) {
        self.record = record
        self.kind = kind
    }
}

public struct DuplicateIndex: Sendable {
    private struct SourceEntry: Sendable {
        var record: GameRecord
        var isOrigin: Bool
        var fileSize: Int64?
        var modifiedAt: Date?
    }

    private var byPath: [String: [SourceEntry]] = [:]
    private var byTitle: [String: GameRecord] = [:]

    public init(_ records: [GameRecord]) {
        self.init(records: records)
    }

    public init(records: [GameRecord]) {
        let io = CrateIO()
        byPath.reserveCapacity(records.count * 2)
        byTitle.reserveCapacity(records.count)
        for record in records {
            if case .referenced(let path, let bookmark) = record.game.source {
                let canonical = ImportOrigin.canonicalPath(for: URL(filePath: path))
                byPath[canonical, default: []].append(SourceEntry(record: record, isOrigin: false))
                if !bookmark.isEmpty, let resolved = try? io.referencedFolderURL(for: record) {
                    let resolvedCanonical = ImportOrigin.canonicalPath(for: resolved)
                    if resolvedCanonical != canonical {
                        byPath[resolvedCanonical, default: []].append(SourceEntry(record: record, isOrigin: false))
                    }
                }
            }
            if let origin = record.game.origin {
                let canonical = ImportOrigin.canonicalPath(for: URL(filePath: origin.path))
                byPath[canonical, default: []].append(
                    SourceEntry(record: record, isOrigin: true, fileSize: origin.fileSize, modifiedAt: origin.modifiedAt)
                )
            }
            let titleKey = Self.normalizedTitle(record.game.title)
            if !titleKey.isEmpty, byTitle[titleKey] == nil {
                byTitle[titleKey] = record
            }
        }
    }

    public func match(for prepared: PreparedImport) -> DuplicateMatch? {
        match(for: prepared.source, title: prepared.suggestedTitle)
    }

    public func match(for source: URL, title: String? = nil) -> DuplicateMatch? {
        let origin = ImportOrigin.from(source)
        if let entries = byPath[origin.path] {
            for entry in entries {
                if !entry.isOrigin || (entry.fileSize == origin.fileSize && entry.modifiedAt == origin.modifiedAt) {
                    return DuplicateMatch(record: entry.record, kind: .sameSource)
                }
            }
        }
        let suggested = title ?? Importer.suggestTitle(from: source.deletingPathExtension().lastPathComponent)
        let titleKey = Self.normalizedTitle(suggested)
        if !titleKey.isEmpty, let record = byTitle[titleKey] {
            return DuplicateMatch(record: record, kind: .sameTitle)
        }
        return nil
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum DuplicateFinder {
    public static func match(for prepared: PreparedImport, in records: [GameRecord]) -> DuplicateMatch? {
        DuplicateIndex(records).match(for: prepared)
    }

    public static func match(for source: URL, title: String? = nil, in records: [GameRecord]) -> DuplicateMatch? {
        DuplicateIndex(records).match(for: source, title: title)
    }
}

public enum ImportError: Error, Equatable {
    case unsupportedType(String)
    case noExecutables
    case unzipFailed(String)
    case referenceNotAllowed
    /// Two files of a disc image would land on the same name in `media/`.
    case mediaNameCollision(String)
    case alreadyRunning
}

public struct PreparedImport: Sendable {
    public let kind: ImportKind
    public let source: URL
    /// Temp directory holding the unpacked zip contents; nil for everything else.
    public let stagingRoot: URL?
    public let candidates: [ExecutableCandidate]
    public let suggestedTitle: String
    /// Only a plain folder can stay where it is and be referenced by bookmark.
    public var allowsReference: Bool { kind == .folder }
}

public struct Importer: Sendable {
    private let io: CrateIO
    private let stagingParent: URL
    private let useItemReplacement: Bool
    /// Test hook: told where each commit builds its scratch crate.
    private let workObserver: (@Sendable (URL) -> Void)?

    public init(io: CrateIO = .init(), stagingParent: URL = FileManager.default.temporaryDirectory) {
        self.init(io: io, stagingParent: stagingParent, useItemReplacement: true, workObserver: nil)
    }

    init(
        io: CrateIO,
        stagingParent: URL,
        useItemReplacement: Bool = true,
        workObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.io = io
        self.stagingParent = stagingParent
        self.useItemReplacement = useItemReplacement
        self.workObserver = workObserver
    }

    // MARK: Prepare

    public func prepare(_ url: URL) async throws -> PreparedImport {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let title = Self.suggestTitle(from: url.deletingPathExtension().lastPathComponent)
        if isDirectory {
            let candidates = try ExecutableRanker.rank(root: url, title: title)
            guard !candidates.isEmpty else { throw ImportError.noExecutables }
            return PreparedImport(kind: .folder, source: url, stagingRoot: nil, candidates: candidates, suggestedTitle: title)
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip":
            let staging = stagingParent
                .appending(path: "doscrate-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try await Self.unzip(url, into: staging)
                try Self.tidy(staging)
                let candidates = try ExecutableRanker.rank(root: staging, title: title)
                guard !candidates.isEmpty else { throw ImportError.noExecutables }
                return PreparedImport(kind: .zip, source: url, stagingRoot: staging, candidates: candidates, suggestedTitle: title)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
        case "iso", "cue":
            return PreparedImport(kind: .discImage, source: url, stagingRoot: nil, candidates: [], suggestedTitle: title)
        case "img", "ima":
            return PreparedImport(kind: .floppyImage, source: url, stagingRoot: nil, candidates: [], suggestedTitle: title)
        default:
            throw ImportError.unsupportedType(ext)
        }
    }

    public func discard(_ p: PreparedImport) {
        if let staging = p.stagingRoot { try? FileManager.default.removeItem(at: staging) }
    }

    // MARK: Commit

    /// Builds the crate in a scratch directory on the library's volume and moves it into place, so a failure
    /// never leaves a half-made crate in the library. The staging directory of a zip is left for `discard`.
    public func commit(
        _ p: PreparedImport, mode: ImportMode, title: String, executable: String?, into library: URL
    ) async throws -> GameRecord {
        if mode == .reference, !p.allowsReference { throw ImportError.referenceNotAllowed }
        let fm = FileManager.default

        let work = try makeWorkDirectory(appropriateFor: library, fallbackParent: library)
        defer { try? fm.removeItem(at: work) }
        workObserver?(work)
        let crate = work.appending(path: "crate.\(CrateIO.crateExtension)", directoryHint: .isDirectory)
        try fm.createDirectory(at: crate, withIntermediateDirectories: true)

        var game: Game
        let files = crate.appending(path: "files", directoryHint: .isDirectory)
        switch p.kind {
        case .folder, .zip:
            if mode == .reference {
                let bookmark = try CrateIO.makeBookmark(for: p.source)
                game = Game(title: title, source: .referenced(path: p.source.path, bookmark: bookmark))
            } else {
                game = Game(title: title, source: .managed)
                try fm.createDirectory(at: files, withIntermediateDirectories: true)
                try Self.copyTree(from: p.stagingRoot ?? p.source, to: files, excluding: work)
            }
        case .discImage, .floppyImage:
            game = Game(title: title, source: .managed)
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            let media = crate.appending(path: "media", directoryHint: .isDirectory)
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            game.media = try Self.stageMedia(for: p, into: media)
        }
        game.origin = ImportOrigin.from(p.source)
        game.launch.executable = executable
        if game.launch.setupExecutable == nil {
            game.launch.setupExecutable = ExecutableRanker.bestSetupExecutable(
                in: p.candidates,
                excluding: game.launch.executable
            )
        }
        try io.save(game, extra: [:], to: crate)

        let base = String(CrateIO.crateName(for: title).dropLast(CrateIO.crateExtension.count + 1))
        var destination = library.appending(path: base + "." + CrateIO.crateExtension, directoryHint: .isDirectory)
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = library.appending(path: "\(base) \(n).\(CrateIO.crateExtension)", directoryHint: .isDirectory)
            n += 1
        }
        try fm.moveItem(at: crate, to: destination)
        return GameRecord(game: game, crateURL: destination)
    }

    /// Creates the crate directory in `library` and writes `game.json` immediately so the game can appear in the
    /// library right away, before `populateCrate(_:for:mode:)` copies or moves the game files in the background.
    public func createCratePlaceholder(
        _ p: PreparedImport, mode: ImportMode, title: String, executable: String?, into library: URL
    ) throws -> GameRecord {
        if mode == .reference, !p.allowsReference { throw ImportError.referenceNotAllowed }
        let fm = FileManager.default
        let destination = try io.makeCrate(title: title, in: library)
        do {
            var game: Game
            if mode == .reference {
                let bookmark = try CrateIO.makeBookmark(for: p.source)
                game = Game(title: title, source: .referenced(path: p.source.path, bookmark: bookmark))
            } else {
                game = Game(title: title, source: .managed)
                let files = destination.appending(path: "files", directoryHint: .isDirectory)
                try fm.createDirectory(at: files, withIntermediateDirectories: true)
                let marker = destination.appending(path: CrateIO.importingMarkerFileName, directoryHint: .notDirectory)
                try Data(CrateIO.processSessionID.utf8).write(to: marker, options: .atomic)
            }
            game.origin = ImportOrigin.from(p.source)
            game.launch.executable = executable
            if game.launch.setupExecutable == nil {
                game.launch.setupExecutable = ExecutableRanker.bestSetupExecutable(
                    in: p.candidates,
                    excluding: game.launch.executable
                )
            }
            try io.save(game, extra: [:], to: destination)
            return GameRecord(game: game, crateURL: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    /// Populates `crateURL` with the game's files or media images in the background after `createCratePlaceholder`.
    /// Returns any staged `MediaImage` entries for disc/floppy imports.
    public func populateCrate(
        at crateURL: URL, for p: PreparedImport, mode: ImportMode
    ) throws -> [MediaImage] {
        if mode == .reference { return [] }
        let fm = FileManager.default
        let work = try makeWorkDirectory(appropriateFor: crateURL, fallbackParent: crateURL.deletingLastPathComponent())
        defer { try? fm.removeItem(at: work) }
        workObserver?(work)

        switch p.kind {
        case .folder, .zip:
            let stagedFiles = work.appending(path: "files", directoryHint: .isDirectory)
            try fm.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
            try Self.copyTree(from: p.stagingRoot ?? p.source, to: stagedFiles, excluding: work)
            let destFiles = crateURL.appending(path: "files", directoryHint: .isDirectory)
            let tempFiles = crateURL.appending(path: ".files-new-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.moveItem(at: stagedFiles, to: tempFiles)
            if fm.fileExists(atPath: destFiles.path) {
                try? fm.removeItem(at: destFiles)
            }
            try fm.moveItem(at: tempFiles, to: destFiles)
            let loaded = io.loadRecord(at: crateURL)
            if case .ok = loaded.status, loaded.game.launch.setupExecutable == nil {
                let candidates = !p.candidates.isEmpty
                    ? p.candidates
                    : ((try? ExecutableRanker.rank(root: destFiles, title: loaded.game.title)) ?? [])
                if let setup = ExecutableRanker.bestSetupExecutable(
                    in: candidates,
                    excluding: loaded.game.launch.executable
                ) {
                    var updatedGame = loaded.game
                    updatedGame.launch.setupExecutable = setup
                    try io.save(updatedGame, extra: loaded.extra, to: crateURL)
                }
            }
            try? fm.removeItem(at: crateURL.appending(path: CrateIO.importingMarkerFileName, directoryHint: .notDirectory))
            return []
        case .discImage, .floppyImage:
            let stagedMedia = work.appending(path: "media", directoryHint: .isDirectory)
            try fm.createDirectory(at: stagedMedia, withIntermediateDirectories: true)
            let images = try Self.stageMedia(for: p, into: stagedMedia)
            let destMedia = crateURL.appending(path: "media", directoryHint: .isDirectory)
            let tempMedia = crateURL.appending(path: ".media-new-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.moveItem(at: stagedMedia, to: tempMedia)
            if fm.fileExists(atPath: destMedia.path) {
                try? fm.removeItem(at: destMedia)
            }
            try fm.moveItem(at: tempMedia, to: destMedia)
            let loaded = io.loadRecord(at: crateURL)
            if case .ok = loaded.status {
                var updatedGame = loaded.game
                updatedGame.media = images
                try io.save(updatedGame, extra: loaded.extra, to: crateURL)
            }
            try? fm.removeItem(at: crateURL.appending(path: CrateIO.importingMarkerFileName, directoryHint: .notDirectory))
            return images
        }
    }

    /// Updates `existing` in place, keeping its id, title, metadata, play stats, settings, `override.conf`,
    /// `cover.png`, unknown `game.json` keys, and any save/config files that exist only in the old `files/`.
    /// A managed game is always replaced with a copy, whatever `mode` asks for, so those files can be kept.
    public func replace(
        _ existing: GameRecord, with p: PreparedImport, mode: ImportMode
    ) async throws -> GameRecord {
        let mode = existing.game.source == .managed ? .copy : mode
        if mode == .reference, !p.allowsReference { throw ImportError.referenceNotAllowed }
        if case .readOnly = existing.status { throw LibraryError.readOnly }
        let fm = FileManager.default
        let crate = existing.crateURL
        let extra = io.extraOnDisk(at: crate) ?? existing.extra
        var game = existing.game
        game.origin = ImportOrigin.from(p.source)

        if mode == .reference {
            let bookmark = try CrateIO.makeBookmark(for: p.source)
            game.source = .referenced(path: p.source.path, bookmark: bookmark)
            game.media = []
            game.launch = Self.updatedLaunch(game.launch, newRoot: p.source, candidates: p.candidates)
            try io.save(game, extra: extra, to: crate)
            let oldFiles = crate.appending(path: "files", directoryHint: .isDirectory)
            if fm.fileExists(atPath: oldFiles.path) {
                try? fm.trashItem(at: oldFiles, resultingItemURL: nil)
            }
            let oldMedia = crate.appending(path: "media", directoryHint: .isDirectory)
            if fm.fileExists(atPath: oldMedia.path) {
                try? fm.trashItem(at: oldMedia, resultingItemURL: nil)
            }
            return GameRecord(game: game, crateURL: crate, extra: extra, status: .ok)
        }

        let work = try makeWorkDirectory(appropriateFor: crate, fallbackParent: crate.deletingLastPathComponent())
        defer { try? fm.removeItem(at: work) }
        workObserver?(work)

        let stagedFiles = work.appending(path: "files", directoryHint: .isDirectory)
        try fm.createDirectory(at: stagedFiles, withIntermediateDirectories: true)
        let crateFiles = crate.appending(path: "files", directoryHint: .isDirectory)
        let crateMedia = crate.appending(path: "media", directoryHint: .isDirectory)
        // Old-only files (saves) come from the crate's copy, or from the folder a referenced game used;
        // that folder itself is left as it is.
        let oldFiles: URL? = existing.game.source == .managed
            ? crateFiles : (try? io.referencedFolderURL(for: existing)) ?? nil
        let carrySource = oldFiles.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }

        var stagedMedia: URL?
        switch p.kind {
        case .folder, .zip:
            let newRoot = p.stagingRoot ?? p.source
            try Self.copyTree(from: newRoot, to: stagedFiles, excluding: work)
            if let carrySource { try Self.carryOver(from: carrySource, to: stagedFiles, excluding: work) }
            game.media = []
            game.launch = Self.updatedLaunch(game.launch, newRoot: newRoot, candidates: p.candidates)
        case .discImage, .floppyImage:
            if let carrySource { try Self.carryOver(from: carrySource, to: stagedFiles, excluding: work) }
            let mediaDir = work.appending(path: "media", directoryHint: .isDirectory)
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            game.media = try Self.stageMedia(for: p, into: mediaDir)
            stagedMedia = mediaDir
            game.launch = Self.updatedLaunch(game.launch, newRoot: stagedFiles, candidates: p.candidates)
        }
        game.source = .managed

        let nextFiles = crate.appending(path: ".files-new-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.moveItem(at: stagedFiles, to: nextFiles)
        var nextMedia: URL?
        if let stagedMedia {
            let target = crate.appending(path: ".media-new-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try fm.moveItem(at: stagedMedia, to: target)
                nextMedia = target
            } catch {
                try? fm.removeItem(at: nextFiles)
                throw error
            }
        }

        let oldFilesBackup = crate.appending(path: ".files-old-\(UUID().uuidString)", directoryHint: .isDirectory)
        let hadOldFiles = fm.fileExists(atPath: crateFiles.path)
        let oldMediaBackup = crate.appending(path: ".media-old-\(UUID().uuidString)", directoryHint: .isDirectory)
        let hadOldMedia = fm.fileExists(atPath: crateMedia.path)

        let latestExtra = io.extraOnDisk(at: crate) ?? extra
        let latestOnDisk = io.loadRecord(at: crate)
        if case .ok = latestOnDisk.status, latestOnDisk.id == existing.id {
            var merged = latestOnDisk.game
            merged.origin = game.origin
            merged.source = game.source
            merged.media = game.media
            let rootForLaunch: URL = switch p.kind {
            case .folder, .zip: p.stagingRoot ?? p.source
            case .discImage, .floppyImage: nextFiles
            }
            merged.launch = Self.updatedLaunch(merged.launch, newRoot: rootForLaunch, candidates: p.candidates)
            game = merged
        }

        do {
            if hadOldFiles { try fm.moveItem(at: crateFiles, to: oldFilesBackup) }
            try fm.moveItem(at: nextFiles, to: crateFiles)
            if hadOldMedia { try fm.moveItem(at: crateMedia, to: oldMediaBackup) }
            if let nextMedia { try fm.moveItem(at: nextMedia, to: crateMedia) }
            try io.save(game, extra: latestExtra, to: crate)
        } catch {
            try? fm.removeItem(at: nextFiles)
            if let nextMedia { try? fm.removeItem(at: nextMedia) }
            if hadOldFiles, fm.fileExists(atPath: oldFilesBackup.path) {
                try? fm.removeItem(at: crateFiles)
                try? fm.moveItem(at: oldFilesBackup, to: crateFiles)
            }
            if hadOldMedia, fm.fileExists(atPath: oldMediaBackup.path) {
                try? fm.removeItem(at: crateMedia)
                try? fm.moveItem(at: oldMediaBackup, to: crateMedia)
            }
            throw error
        }

        if hadOldFiles { try? fm.trashItem(at: oldFilesBackup, resultingItemURL: nil) }
        if hadOldMedia { try? fm.trashItem(at: oldMediaBackup, resultingItemURL: nil) }
        return GameRecord(game: game, crateURL: crate, extra: latestExtra, status: .ok)
    }

    // MARK: Helpers

    private func makeWorkDirectory(appropriateFor url: URL, fallbackParent: URL) throws -> URL {
        let fm = FileManager.default
        if useItemReplacement,
           let work = try? fm.url(
               for: .itemReplacementDirectory,
               in: .userDomainMask,
               appropriateFor: url,
               create: true
           ) {
            return work
        }
        let fallback = fallbackParent.appending(
            path: ".doscrate-tmp-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private static func stageMedia(for p: PreparedImport, into media: URL) throws -> [MediaImage] {
        let fm = FileManager.default
        if p.source.pathExtension.lowercased() == "cue" {
            let sheet = try CueSheet(p.source)
            var seen: [String: (path: String, resourceID: NSObject?)] = [
                p.source.lastPathComponent.lowercased(): (
                    p.source.standardizedFileURL.path,
                    (try? p.source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject
                )
            ]
            for file in sheet.files {
                let key = file.lastPathComponent.lowercased()
                let path = file.standardizedFileURL.path
                let resourceID = (try? file.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject
                if let existing = seen[key] {
                    // The same bin listed twice (including case-only variants on a case-insensitive volume) is fine;
                    // two different files with one name are not.
                    if existing.path == path || (resourceID != nil && existing.resourceID == resourceID) {
                        continue
                    }
                    throw ImportError.mediaNameCollision(file.lastPathComponent)
                }
                seen[key] = (path, resourceID)
                try fm.copyItem(at: file, to: media.appending(path: file.lastPathComponent))
            }
            try sheet.flattenedData.write(to: media.appending(path: p.source.lastPathComponent))
        } else {
            try fm.copyItem(at: p.source, to: media.appending(path: p.source.lastPathComponent))
        }
        return [MediaImage(relativePath: "media/" + p.source.lastPathComponent,
                           kind: p.kind == .discImage ? .cdrom : .floppy)]
    }

    private static func updatedLaunch(
        _ launch: LaunchSpec, newRoot: URL?, candidates: [ExecutableCandidate]
    ) -> LaunchSpec {
        var launch = launch
        guard let newRoot else {
            launch.driveCRoot = ""
            launch.executable = candidates.count == 1 ? candidates[0].relativePath : nil
            if launch.setupExecutable == nil {
                launch.setupExecutable = ExecutableRanker.bestSetupExecutable(
                    in: candidates,
                    excluding: launch.executable
                )
            }
            return launch
        }
        let fm = FileManager.default
        var cRoot = newRoot
        if !launch.driveCRoot.isEmpty {
            let sub = newRoot.appending(path: launch.driveCRoot, directoryHint: .isDirectory)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                cRoot = sub
            } else {
                launch.driveCRoot = ""
            }
        }
        var keptExistingExecutable = false
        if let exe = launch.executable, !exe.isEmpty {
            let exeURL = cRoot.appending(path: exe, directoryHint: .notDirectory)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: exeURL.path, isDirectory: &isDir), !isDir.boolValue {
                keptExistingExecutable = true
            }
        }
        if !keptExistingExecutable {
            if candidates.count == 1 {
                // Candidates are relative to the whole folder; make the path relative to the kept C: root,
                // or use the whole folder as C: when the program is outside it.
                let path = candidates[0].relativePath
                let prefix = launch.driveCRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                if prefix != "/", path.lowercased().hasPrefix(prefix.lowercased()) {
                    launch.executable = String(path.dropFirst(prefix.count))
                } else {
                    launch.driveCRoot = ""
                    cRoot = newRoot
                    launch.executable = path
                }
            } else {
                launch.executable = nil
            }
        }
        if let setup = launch.setupExecutable, !setup.isEmpty {
            let setupURL = cRoot.appending(path: setup, directoryHint: .notDirectory)
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: setupURL.path, isDirectory: &isDir) || isDir.boolValue
                || setup.caseInsensitiveCompare(launch.executable ?? "") == .orderedSame {
                launch.setupExecutable = nil
            }
        }
        if launch.setupExecutable == nil {
            let prefix = launch.driveCRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            let cRootCandidates: [ExecutableCandidate] = if prefix == "/" {
                candidates
            } else {
                candidates.compactMap { candidate in
                    guard candidate.relativePath.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
                    return ExecutableCandidate(
                        relativePath: String(candidate.relativePath.dropFirst(prefix.count)),
                        score: candidate.score
                    )
                }
            }
            launch.setupExecutable = ExecutableRanker.bestSetupExecutable(
                in: cRootCandidates,
                excluding: launch.executable
            )
        }
        return launch
    }

    /// Copies files that exist only in `oldDir` into `newDir`; files already present in `newDir` win.
    private static func carryOver(from oldDir: URL, to newDir: URL, excluding excluded: URL? = nil) throws {
        let fm = FileManager.default
        let excludedURL = excluded?.resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = newDir.resolvingSymlinksInPath().standardizedFileURL
        let newEntries = (try? fm.contentsOfDirectory(at: newDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var byLowerName: [String: URL] = [:]
        for entry in newEntries {
            byLowerName[entry.lastPathComponent.lowercased()] = entry
        }
        for child in try fm.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { continue }
            if child.lastPathComponent.hasPrefix(".doscrate-tmp-") { continue }
            let standardizedChild = child.resolvingSymlinksInPath().standardizedFileURL
            if standardizedChild == excludedURL || standardizedChild == destinationURL { continue }
            let key = child.lastPathComponent.lowercased()
            if let existing = byLowerName[key] {
                let existingIsDir = (try? existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if values.isDirectory == true, existingIsDir {
                    try carryOver(from: child, to: existing, excluding: excluded)
                }
                continue
            }
            let target = newDir.appending(
                path: child.lastPathComponent,
                directoryHint: values.isDirectory == true ? .isDirectory : .notDirectory
            )
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: child, to: target, excluding: excluded)
            } else {
                try fm.copyItem(at: child, to: target)
            }
        }
    }

    /// A cue sheet: its referenced files, and its text with every `FILE` entry reduced to a bare file name
    /// (the files are copied flat into `media/`).
    private struct CueSheet {
        var files: [URL] = []
        private var lines: [String] = []
        private var encoding: String.Encoding = .utf8
        private var hasBOM = false

        init(_ cue: URL) throws {
            var data = try Data(contentsOf: cue)
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                hasBOM = true
                data = data.dropFirst(3)
            }
            let text: String
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else {
                text = String(data: data, encoding: .isoLatin1) ?? ""
                encoding = .isoLatin1
            }
            let dir = cue.deletingLastPathComponent()
            // Splitting on "\n" only keeps any "\r" attached to its line, so line endings survive.
            var found: [URL] = []
            lines = try text.components(separatedBy: "\n").map { raw in
                let hasCR = raw.hasSuffix("\r")
                let line = hasCR ? String(raw.dropLast()) : raw
                let cr = hasCR ? "\r" : ""
                let body = line.trimmingCharacters(in: .whitespaces)
                guard body.uppercased().hasPrefix("FILE ") else { return raw }
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let rest = body.dropFirst(5).drop { $0 == " " }
                let name: String, suffix: String, quoted: Bool
                if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
                    name = String(rest[rest.index(after: rest.startIndex)..<close])
                    suffix = String(rest[rest.index(after: close)...])
                    quoted = true
                } else {
                    let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    name = parts.first.map(String.init) ?? ""
                    suffix = parts.count > 1 ? " " + parts[1] : ""
                    quoted = false
                }
                guard !name.isEmpty else { return raw }
                let normalized = name.replacingOccurrences(of: "\\", with: "/")
                guard !normalized.hasPrefix("/") else {
                    throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: name])
                }
                var stack: [Substring] = []
                for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
                    if component == "." { continue }
                    if component == ".." {
                        guard !stack.isEmpty else {
                            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSFilePathErrorKey: name])
                        }
                        stack.removeLast()
                    } else {
                        stack.append(component)
                    }
                }
                guard let lastPart = stack.last else { return raw }
                let resolved = stack.reduce(dir) { $0.appending(path: String($1), directoryHint: .notDirectory) }
                found.append(resolved)
                let flat = String(lastPart)
                return indent + "FILE " + (quoted ? "\"\(flat)\"" : flat) + suffix + cr
            }
            files = found
        }

        var flattenedData: Data {
            let body = lines.joined(separator: "\n").data(using: encoding) ?? Data()
            return hasBOM ? Data([0xEF, 0xBB, 0xBF]) + body : body
        }
    }

    /// Copies a directory tree, dropping symlinks so a crate never points at host paths.
    private static func copyTree(from source: URL, to destination: URL, excluding excluded: URL? = nil) throws {
        let fm = FileManager.default
        let excludedURL = excluded?.resolvingSymlinksInPath().standardizedFileURL
        let destinationURL = destination.resolvingSymlinksInPath().standardizedFileURL
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { continue }
            if child.lastPathComponent.hasPrefix(".doscrate-tmp-") { continue }
            let standardizedChild = child.resolvingSymlinksInPath().standardizedFileURL
            if standardizedChild == excludedURL || standardizedChild == destinationURL { continue }
            let target = destination.appending(path: child.lastPathComponent, directoryHint: values.isDirectory == true ? .isDirectory : .notDirectory)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: child, to: target, excluding: excluded)
            } else {
                try fm.copyItem(at: child, to: target)
            }
        }
    }

    private static func removeSymlinks(in root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try? fm.removeItem(at: url)
        }
    }

    /// Drops macOS archive litter and unwraps a single top-level folder.
    private static func tidy(_ root: URL) throws {
        let fm = FileManager.default
        removeSymlinks(in: root)
        for junk in ["__MACOSX", ".DS_Store"] {
            try? fm.removeItem(at: root.appending(path: junk))
        }
        let top = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        guard top.count == 1, (try top[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { return }
        let wrapper = top[0]
        // Rename first so a child with the wrapper's own name cannot collide on the way up.
        let holding = root.appending(path: ".unwrap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.moveItem(at: wrapper, to: holding)
        for child in try fm.contentsOfDirectory(at: holding, includingPropertiesForKeys: nil, options: []) {
            try fm.moveItem(at: child, to: root.appending(path: child.lastPathComponent))
        }
        try fm.removeItem(at: holding)
    }

    private static func unzip(_ zip: URL, into dir: URL) async throws {
        do {
            try await Ditto.unzip(zip, into: dir)
        } catch DittoError.failed(let message) {
            throw ImportError.unzipFailed(message)
        }
    }

    static func suggestTitle(from name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return titled.isEmpty ? "Untitled" : titled
    }
}
