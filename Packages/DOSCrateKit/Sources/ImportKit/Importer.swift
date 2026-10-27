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
    /// Two files of a disc image would land on the same name in `media/`.
    case mediaNameCollision(String)
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
    /// Test hook: told where each commit builds its scratch crate.
    private let workObserver: (@Sendable (URL) -> Void)?

    public init(io: CrateIO = .init()) { self.init(io: io, stagingParent: FileManager.default.temporaryDirectory) }

    init(io: CrateIO, stagingParent: URL, workObserver: (@Sendable (URL) -> Void)? = nil) {
        self.io = io
        self.stagingParent = stagingParent
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

        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: library, create: true)
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
                try Self.copyTree(from: p.stagingRoot ?? p.source, to: files)
            }
        case .discImage, .floppyImage:
            game = Game(title: title, source: .managed)
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            let media = crate.appending(path: "media", directoryHint: .isDirectory)
            try fm.createDirectory(at: media, withIntermediateDirectories: true)
            if p.source.pathExtension.lowercased() == "cue" {
                let sheet = try CueSheet(p.source)
                var seen: Set<String> = [p.source.lastPathComponent.lowercased()]
                for file in sheet.files {
                    guard seen.insert(file.lastPathComponent.lowercased()).inserted else {
                        throw ImportError.mediaNameCollision(file.lastPathComponent)
                    }
                    try fm.copyItem(at: file, to: media.appending(path: file.lastPathComponent))
                }
                try sheet.flattenedData.write(to: media.appending(path: p.source.lastPathComponent))
            } else {
                try fm.copyItem(at: p.source, to: media.appending(path: p.source.lastPathComponent))
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

    /// A cue sheet: its referenced files, and its text with every `FILE` entry reduced to a bare file name
    /// (the files are copied flat into `media/`).
    private struct CueSheet {
        var files: [URL] = []
        private var lines: [String] = []
        private var encoding: String.Encoding = .utf8

        init(_ cue: URL) throws {
            let data = try Data(contentsOf: cue)
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
            lines = text.components(separatedBy: "\n").map { line in
                let body = line.trimmingCharacters(in: .whitespaces)
                guard body.uppercased().hasPrefix("FILE ") else { return line }
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
                guard !name.isEmpty else { return line }
                let normalized = name.replacingOccurrences(of: "\\", with: "/")
                found.append(dir.appending(path: normalized, directoryHint: .notDirectory))
                let flat = (normalized as NSString).lastPathComponent
                let trailing = line.hasSuffix("\r") && !suffix.hasSuffix("\r") ? "\r" : ""
                return indent + "FILE " + (quoted ? "\"\(flat)\"" : flat) + suffix + trailing
            }
            files = found
        }

        var flattenedData: Data { lines.joined(separator: "\n").data(using: encoding) ?? Data() }
    }

    /// Copies a directory tree, dropping symlinks so a crate never points at host paths.
    private static func copyTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { continue }
            let target = destination.appending(path: child.lastPathComponent, directoryHint: values.isDirectory == true ? .isDirectory : .notDirectory)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try copyTree(from: child, to: target)
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
