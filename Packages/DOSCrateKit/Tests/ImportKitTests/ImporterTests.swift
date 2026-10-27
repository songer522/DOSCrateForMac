import Foundation
import Testing
import LibraryKit
@testable import ImportKit

private func zip(_ folder: URL, to name: String, in dir: URL) throws -> URL {
    let out = dir.appending(path: name, directoryHint: .notDirectory)
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", folder.path, out.path]
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    return out
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private final class WorkDirs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

struct ImporterTests {
    let importer = Importer()
    let io = CrateIO()

    @Test func folderCopyCreatesManagedCrate() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "keen", directoryHint: .isDirectory)
        try touch(src, "KEEN1.EXE"); try touch(src, "DATA/LEVEL.DAT")
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let p = try await importer.prepare(src)
        #expect(p.kind == .folder && p.allowsReference && p.stagingRoot == nil)
        #expect(p.candidates.map(\.relativePath) == ["KEEN1.EXE"])
        let rec = try await importer.commit(p, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: lib)
        #expect(exists(rec.crateURL.appending(path: "files/KEEN1.EXE")))
        #expect(exists(rec.crateURL.appending(path: "files/DATA/LEVEL.DAT")))
        #expect(rec.game.source == .managed)
        #expect(rec.game.launch.executable == "KEEN1.EXE")
        #expect(rec.crateURL.deletingLastPathComponent().standardizedFileURL == lib.standardizedFileURL)
        let loaded = io.loadRecord(at: rec.crateURL)
        #expect(loaded.game == rec.game && loaded.status == .ok)
        #expect(exists(src.appending(path: "KEEN1.EXE")))
    }

    @Test func duplicateTitlesGetUniqueCrates() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "g", directoryHint: .isDirectory)
        try touch(src, "G.EXE")
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src)
        let a = try await importer.commit(p, mode: .copy, title: "G", executable: "G.EXE", into: lib)
        let b = try await importer.commit(p, mode: .copy, title: "G", executable: "G.EXE", into: lib)
        #expect(a.crateURL.lastPathComponent == "G.doscrate")
        #expect(b.crateURL.lastPathComponent == "G 2.doscrate")
    }

    @Test func folderReferenceStoresBookmarkAndCopiesNothing() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "keen", directoryHint: .isDirectory)
        try touch(src, "KEEN1.EXE")
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let p = try await importer.prepare(src)
        let rec = try await importer.commit(p, mode: .reference, title: "Keen", executable: "KEEN1.EXE", into: lib)
        #expect(!exists(rec.crateURL.appending(path: "files")))
        guard case .referenced = rec.game.source else { Issue.record("not referenced"); return }
        let c = try io.cDriveURL(for: io.loadRecord(at: rec.crateURL))
        #expect(c.resolvingSymlinksInPath().path == src.resolvingSymlinksInPath().path)
    }

    @Test func zipWithSingleWrapperFolderIsFlattened() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let tree = tmp.appending(path: "tree", directoryHint: .isDirectory)
        try touch(tree, "Keen/KEEN1.EXE"); try touch(tree, "__MACOSX/Keen/._KEEN1.EXE"); try touch(tree, ".DS_Store")
        let z = try zip(tree, to: "keen.zip", in: tmp)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let p = try await importer.prepare(z)
        #expect(p.kind == .zip && !p.allowsReference)
        #expect(p.candidates.map(\.relativePath) == ["KEEN1.EXE"])
        let staging = try #require(p.stagingRoot)
        #expect(exists(staging))
        let rec = try await importer.commit(p, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: lib)
        #expect(exists(rec.crateURL.appending(path: "files/KEEN1.EXE")))
        #expect(!exists(rec.crateURL.appending(path: "files/__MACOSX")))
        #expect(!exists(rec.crateURL.appending(path: "files/.DS_Store")))
        importer.discard(p)
        #expect(!exists(staging))
    }

    @Test func referencingAZipIsRejected() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let tree = tmp.appending(path: "tree", directoryHint: .isDirectory)
        try touch(tree, "G.EXE")
        let z = try zip(tree, to: "g.zip", in: tmp)
        let p = try await importer.prepare(z)
        await #expect(throws: ImportError.referenceNotAllowed) {
            _ = try await importer.commit(p, mode: .reference, title: "G", executable: nil, into: tmp)
        }
        importer.discard(p)
    }

    @Test func folderWithoutExecutablesThrows() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "empty", directoryHint: .isDirectory)
        try touch(src, "README.TXT")
        await #expect(throws: ImportError.noExecutables) { _ = try await importer.prepare(src) }

        let z = try zip(src, to: "empty.zip", in: tmp)
        let stagingParent = tmp.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: true)
        let isolated = Importer(io: CrateIO(), stagingParent: stagingParent)
        await #expect(throws: ImportError.noExecutables) { _ = try await isolated.prepare(z) }
        // No staging directory is left behind by the failed zip prepare.
        #expect(try FileManager.default.contentsOfDirectory(atPath: stagingParent.path).isEmpty)
    }

    @Test func badZipThrowsUnzipFailed() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let z = tmp.appending(path: "bad.zip")
        try Data("not a zip".utf8).write(to: z)
        do {
            _ = try await importer.prepare(z)
            Issue.record("expected failure")
        } catch ImportError.unzipFailed {
        }
    }

    @Test func unsupportedTypeThrows() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let f = try touch(tmp, "x.rar")
        await #expect(throws: ImportError.unsupportedType("rar")) { _ = try await importer.prepare(f) }
    }

    @Test func isoImportCopiesIntoMediaAndCreatesEmptyFiles() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let iso = try touch(tmp, "game.iso", bytes: 64)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let p = try await importer.prepare(iso)
        #expect(p.kind == .discImage && !p.allowsReference && p.candidates.isEmpty)
        let rec = try await importer.commit(p, mode: .copy, title: "Game", executable: nil, into: lib)
        #expect(exists(rec.crateURL.appending(path: "media/game.iso")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rec.crateURL.appending(path: "files").path).isEmpty)
        #expect(rec.game.launch.executable == nil)
        #expect(rec.game.media == [MediaImage(relativePath: "media/game.iso", kind: .cdrom)])
    }

    @Test func floppyImageIsFloppyKind() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let img = try touch(tmp, "disk1.IMA", bytes: 64)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(img)
        #expect(p.kind == .floppyImage)
        let rec = try await importer.commit(p, mode: .copy, title: "Disk", executable: nil, into: lib)
        #expect(rec.game.media == [MediaImage(relativePath: "media/disk1.IMA", kind: .floppy)])
    }

    @Test func cueCopiesReferencedBins() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "disc", directoryHint: .isDirectory)
        try touch(src, "t1.bin"); try touch(src, "t2.bin"); try touch(src, "other.bin")
        let cue = """
        FILE "t1.bin" BINARY
          TRACK 01 MODE1/2352
            INDEX 01 00:00:00
        FILE "t2.bin" BINARY
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """
        try cue.write(to: src.appending(path: "game.cue"), atomically: true, encoding: .utf8)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let p = try await importer.prepare(src.appending(path: "game.cue"))
        #expect(p.kind == .discImage)
        let rec = try await importer.commit(p, mode: .copy, title: "Disc", executable: nil, into: lib)
        for f in ["game.cue", "t1.bin", "t2.bin"] { #expect(exists(rec.crateURL.appending(path: "media/\(f)"))) }
        #expect(!exists(rec.crateURL.appending(path: "media/other.bin")))
        #expect(rec.game.media == [MediaImage(relativePath: "media/game.cue", kind: .cdrom)])
    }

    @Test func cueInSubdirectoryIsRewrittenToFlatNames() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "disc", directoryHint: .isDirectory)
        try touch(src, "tracks/a.bin"); try touch(src, "tracks/b track.wav")
        let cue = "FILE \"tracks/a.bin\" BINARY\r\n  TRACK 01 MODE1/2352\r\nFILE \"tracks\\b track.wav\" WAVE\r\n"
        try cue.write(to: src.appending(path: "g.cue"), atomically: true, encoding: .utf8)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src.appending(path: "g.cue"))
        let rec = try await importer.commit(p, mode: .copy, title: "G", executable: nil, into: lib)
        #expect(exists(rec.crateURL.appending(path: "media/a.bin")))
        #expect(exists(rec.crateURL.appending(path: "media/b track.wav")))
        let text = try String(contentsOf: rec.crateURL.appending(path: "media/g.cue"), encoding: .utf8)
        #expect(text == "FILE \"a.bin\" BINARY\r\n  TRACK 01 MODE1/2352\r\nFILE \"b track.wav\" WAVE\r\n")
    }

    @Test func cueNameCollisionThrows() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "disc", directoryHint: .isDirectory)
        try touch(src, "one/a.bin"); try touch(src, "two/a.bin")
        try "FILE \"one/a.bin\" BINARY\nFILE \"two/a.bin\" BINARY\n"
            .write(to: src.appending(path: "g.cue"), atomically: true, encoding: .utf8)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src.appending(path: "g.cue"))
        await #expect(throws: ImportError.mediaNameCollision("a.bin")) {
            _ = try await importer.commit(p, mode: .copy, title: "G", executable: nil, into: lib)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.path).isEmpty)
    }

    @Test func latin1CueIsReadable() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appending(path: "disc", directoryHint: .isDirectory)
        try touch(src, "caf\u{E9}.bin")
        try "FILE \"caf\u{E9}.bin\" BINARY\n".data(using: .isoLatin1)!.write(to: src.appending(path: "g.cue"))
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src.appending(path: "g.cue"))
        let rec = try await importer.commit(p, mode: .copy, title: "G", executable: nil, into: lib)
        #expect(exists(rec.crateURL.appending(path: "media/caf\u{E9}.bin")))
    }

    @Test func symlinksAreNotCarriedIntoTheCrate() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let outside = try touch(tmp, "outside/secret.txt")
        let src = tmp.appending(path: "g", directoryHint: .isDirectory)
        try touch(src, "G.EXE"); try touch(src, "sub/X.DAT")
        try FileManager.default.createSymbolicLink(at: src.appending(path: "link"), withDestinationURL: outside.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: src.appending(path: "sub/file-link"), withDestinationURL: outside)
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src)
        let rec = try await importer.commit(p, mode: .copy, title: "G", executable: "G.EXE", into: lib)
        let files = rec.crateURL.appending(path: "files")
        #expect(exists(files.appending(path: "sub/X.DAT")))
        #expect(!FileManager.default.fileExists(atPath: files.appending(path: "link").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: files.appending(path: "link").path)) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: files.appending(path: "sub/file-link").path)) == nil)
    }

    @Test func failedCommitLeavesNoCrate() async throws {
        let tmp = try makeImportTempDir()
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path)
            try? FileManager.default.removeItem(at: tmp)
        }
        let src = tmp.appending(path: "g", directoryHint: .isDirectory)
        try touch(src, "G.EXE")
        let seen = WorkDirs()
        let observed = Importer(io: CrateIO(), stagingParent: tmp) { seen.add($0) }
        let p = try await observed.prepare(src)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lib.path)
        await #expect(throws: (any Error).self) {
            _ = try await observed.commit(p, mode: .copy, title: "G", executable: "G.EXE", into: lib)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.path).isEmpty)
        let dirs = seen.all
        #expect(dirs.count == 1)
        for d in dirs { #expect(!exists(d)) }
    }

    @Test func suggestedTitleFromName() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let tree = tmp.appending(path: "tree", directoryHint: .isDirectory)
        try touch(tree, "KEEN1.EXE")
        let z = try zip(tree, to: "commander_keen-1.zip", in: tmp)
        let p = try await importer.prepare(z)
        #expect(p.suggestedTitle == "Commander Keen 1")
        importer.discard(p)
    }
}
