import Foundation
import LibraryKit

public enum ImportKind: Sendable {
    case folder, zip, discImage, floppyImage
}

public enum ImportMode: Sendable {
    case copy, reference
}

public enum ImportError: Error, Equatable {
    case unsupportedType(String)
    case noExecutables
    case unzipFailed(String)
    case referenceNotAllowed
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

    public init(io: CrateIO = .init()) { self.init(io: io, stagingParent: FileManager.default.temporaryDirectory) }

    init(io: CrateIO, stagingParent: URL) {
        self.io = io
        self.stagingParent = stagingParent
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

        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: library, create: true)
        defer { try? fm.removeItem(at: work) }
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
                let root = p.stagingRoot ?? p.source
                for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                    try fm.copyItem(at: child, to: files.appending(path: child.lastPathComponent))
                }
            }
        case .discImage, .floppyImage:
            game = Game(title: title, source: .managed)
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            let media = crate.appending(path: "media", directoryHint: .isDirectory)
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            for file in try Self.imageFiles(p.source) {
                try fm.copyItem(at: file, to: media.appending(path: file.lastPathComponent))
            }
            game.media = [MediaImage(relativePath: "media/" + p.source.lastPathComponent,
                                     kind: p.kind == .discImage ? .cdrom : .floppy)]
        }
        game.launch.executable = executable
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

    // MARK: Helpers

    /// The image itself, plus every `FILE "…"` target when it is a cue sheet.
    private static func imageFiles(_ image: URL) throws -> [URL] {
        guard image.pathExtension.lowercased() == "cue" else { return [image] }
        let text = try String(contentsOf: image, encoding: .utf8)
        var files = [image]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("FILE ") else { continue }
            let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name: String
            if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
                name = String(rest[rest.index(after: rest.startIndex)..<close])
            } else {
                name = rest.split(separator: " ").first.map(String.init) ?? ""
            }
            guard !name.isEmpty else { continue }
            let file = image.deletingLastPathComponent().appending(path: name, directoryHint: .notDirectory)
            if !files.contains(file) { files.append(file) }
        }
        return files
    }

    /// Drops macOS archive litter and unwraps a single top-level folder.
    private static func tidy(_ root: URL) throws {
        let fm = FileManager.default
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
        let stderr: (status: Int32, text: String) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", zip.path, dir.path]
                let pipe = Pipe()
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard stderr.status == 0 else {
            throw ImportError.unzipFailed(stderr.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func suggestTitle(from name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return titled.isEmpty ? "Untitled" : titled
    }
}
