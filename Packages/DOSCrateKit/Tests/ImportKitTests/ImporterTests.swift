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

    private func cueImport(_ cue: Data, bins: [String], in tmp: URL) async throws -> (GameRecord, String) {
        let src = tmp.appending(path: "disc", directoryHint: .isDirectory)
        for b in bins { try touch(src, b) }
        try cue.write(to: src.appending(path: "g.cue"))
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let p = try await importer.prepare(src.appending(path: "g.cue"))
        let rec = try await importer.commit(p, mode: .copy, title: "G", executable: nil, into: lib)
        let text = String(decoding: try Data(contentsOf: rec.crateURL.appending(path: "media/g.cue")), as: UTF8.self)
        return (rec, text)
    }

    @Test func duplicateCueEntryForSameBinIsNotACollision() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cue = Data("FILE \"a.bin\" BINARY\nFILE \"./a.bin\" BINARY\n".utf8)
        let (rec, text) = try await cueImport(cue, bins: ["a.bin"], in: tmp)
        #expect(exists(rec.crateURL.appending(path: "media/a.bin")))
        #expect(text == "FILE \"a.bin\" BINARY\nFILE \"a.bin\" BINARY\n")
    }

    @Test func unquotedTypelessFileLineOnCRLFCue() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let (rec, text) = try await cueImport(Data("FILE sub/a.bin\r\n".utf8), bins: ["sub/a.bin"], in: tmp)
        #expect(exists(rec.crateURL.appending(path: "media/a.bin")))
        #expect(text == "FILE a.bin\r\n")
    }

    @Test func utf8BOMIsToleratedAndPreserved() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let cue = Data([0xEF, 0xBB, 0xBF]) + Data("FILE \"sub/a.bin\" BINARY\n".utf8)
        let (rec, _) = try await cueImport(cue, bins: ["sub/a.bin"], in: tmp)
        #expect(exists(rec.crateURL.appending(path: "media/a.bin")))
        let written = try Data(contentsOf: rec.crateURL.appending(path: "media/g.cue"))
        #expect(written == Data([0xEF, 0xBB, 0xBF]) + Data("FILE \"a.bin\" BINARY\n".utf8))
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

    @Test func duplicateFinderMatchesReferencedOriginZipAndTitle() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        // 1. Referenced same-folder match (including via symlink).
        let refFolder = tmp.appending(path: "ref_keen", directoryHint: .isDirectory)
        try touch(refFolder, "KEEN1.EXE")
        let pRef = try await importer.prepare(refFolder)
        let recRef = try await importer.commit(pRef, mode: .reference, title: "Commander Keen", executable: "KEEN1.EXE", into: lib)

        let symlinkToRef = tmp.appending(path: "keen_link")
        try FileManager.default.createSymbolicLink(at: symlinkToRef, withDestinationURL: refFolder)
        let matchRef = DuplicateFinder.match(for: symlinkToRef, in: [recRef])
        #expect(matchRef?.kind == .sameSource)
        #expect(matchRef?.record.id == recRef.id)

        // 2. Origin-path match for a copied folder.
        let copyFolder = tmp.appending(path: "doom_folder", directoryHint: .isDirectory)
        try touch(copyFolder, "DOOM.EXE")
        let pCopy = try await importer.prepare(copyFolder)
        let recCopy = try await importer.commit(pCopy, mode: .copy, title: "Custom Doom Title", executable: "DOOM.EXE", into: lib)
        #expect(recCopy.game.origin == ImportOrigin.from(copyFolder))

        let matchFolderOrigin = DuplicateFinder.match(for: copyFolder, in: [recCopy])
        #expect(matchFolderOrigin?.kind == .sameSource)
        #expect(matchFolderOrigin?.record.id == recCopy.id)

        // 3. Zip with same path, size, and date is .sameSource; different size or date is not .sameSource.
        let zipTree = tmp.appending(path: "wolf_tree", directoryHint: .isDirectory)
        try touch(zipTree, "WOLF3D.EXE")
        let wolfZip = try zip(zipTree, to: "wolf_archive.zip", in: tmp)
        let pZip = try await importer.prepare(wolfZip)
        let recZip = try await importer.commit(pZip, mode: .copy, title: "Wolfenstein 3D", executable: "WOLF3D.EXE", into: lib)
        importer.discard(pZip)

        #expect(DuplicateFinder.match(for: wolfZip, in: [recZip])?.kind == .sameSource)

        // Modify modification date -> no longer .sameSource.
        let originalMtime = try FileManager.default.attributesOfItem(atPath: wolfZip.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: wolfZip.path
        )
        #expect(DuplicateFinder.match(for: wolfZip, in: [recZip])?.kind != .sameSource)

        // Restore date, change size -> no longer .sameSource.
        if let originalMtime {
            try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: wolfZip.path)
        }
        try Data("different-size-bytes".utf8).write(to: wolfZip)
        if let originalMtime {
            try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: wolfZip.path)
        }
        #expect(DuplicateFinder.match(for: wolfZip, in: [recZip])?.kind != .sameSource)

        // 4. Title-only match (case- and diacritic-insensitive and trimmed) is .sameTitle.
        var pokemonGame = Game(title: "  Pokémon  ", source: .managed)
        pokemonGame.origin = ImportOrigin(path: "/elsewhere/pokemon")
        let recPokemon = GameRecord(game: pokemonGame, crateURL: lib.appending(path: "Pokemon.doscrate"))
        let otherPokemon = tmp.appending(path: "pokemon", directoryHint: .isDirectory)
        try touch(otherPokemon, "POKE.EXE")
        let matchTitle = DuplicateFinder.match(for: otherPokemon, in: [recPokemon])
        #expect(matchTitle?.kind == .sameTitle)
        #expect(matchTitle?.record.id == recPokemon.id)

        // 5. No match.
        let unrelated = tmp.appending(path: "heretic", directoryHint: .isDirectory)
        try touch(unrelated, "HERETIC.EXE")
        let index = DuplicateIndex([recRef, recCopy, recZip, recPokemon])
        #expect(index.match(for: unrelated) == nil)
    }

    @Test func duplicateIndexScalesTo2000RecordsAnd100Lookups() throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let refRoot = tmp.appending(path: "refs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: refRoot, withIntermediateDirectories: true)

        // Create a real folder and bookmark so the 1,000 referenced records carry real bookmark data.
        let sampleFolder = refRoot.appending(path: "sample", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sampleFolder, withIntermediateDirectories: true)
        let sampleBookmark = try CrateIO.makeBookmark(for: sampleFolder)

        var records: [GameRecord] = []
        records.reserveCapacity(2000)
        for i in 0..<1000 {
            let folder = refRoot.appending(path: "ref_\(i)", directoryHint: .isDirectory)
            var refGame = Game(
                title: "Referenced Game \(i)",
                source: .referenced(path: folder.path, bookmark: sampleBookmark),
                origin: ImportOrigin(path: folder.path)
            )
            refGame.id = UUID()
            records.append(GameRecord(game: refGame, crateURL: tmp.appending(path: "Ref\(i).doscrate")))

            let zipPath = tmp.appending(path: "archives/managed_\(i).zip").path
            var managedGame = Game(
                title: "Managed Game \(i)",
                source: .managed,
                origin: ImportOrigin(
                    path: zipPath,
                    fileSize: Int64(1000 + i),
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
            managedGame.id = UUID()
            records.append(GameRecord(game: managedGame, crateURL: tmp.appending(path: "Managed\(i).doscrate")))
        }

        var lookupURLs: [URL] = []
        lookupURLs.reserveCapacity(100)
        for i in 0..<40 {
            lookupURLs.append(refRoot.appending(path: "ref_\(i * 20)", directoryHint: .isDirectory))
        }
        for i in 0..<30 {
            lookupURLs.append(tmp.appending(path: "elsewhere/managed_game_\(i * 30)", directoryHint: .isDirectory))
        }
        for i in 0..<30 {
            lookupURLs.append(tmp.appending(path: "brand_new_game_\(i)", directoryHint: .isDirectory))
        }

        let start = ContinuousClock.now
        let index = DuplicateIndex(records)
        var sameSourceCount = 0
        var sameTitleCount = 0
        var nilCount = 0
        for url in lookupURLs {
            switch index.match(for: url)?.kind {
            case .sameSource: sameSourceCount += 1
            case .sameTitle: sameTitleCount += 1
            case nil: nilCount += 1
            }
        }
        let elapsed = ContinuousClock.now - start

        #expect(sameSourceCount == 40)
        #expect(sameTitleCount == 30)
        #expect(nilCount == 30)
        #expect(elapsed < .seconds(1))
    }

    @Test func replaceManagedGameKeepsSavesSettingsAndResetsMissingExecutable() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let v1 = tmp.appending(path: "keen_v1", directoryHint: .isDirectory)
        try touch(v1, "OLD.EXE")
        try Data("v1-data".utf8).write(to: v1.appending(path: "DATA.DAT"))

        let p1 = try await importer.prepare(v1)
        var rec = try await importer.commit(p1, mode: .copy, title: "Commander Keen", executable: "OLD.EXE", into: lib)

        // Populate metadata, settings, play stats, unknown collection key, override.conf, cover.png, and a save file.
        rec.game.year = 1990
        rec.game.developer = "id Software"
        rec.game.publisher = "Apogee"
        rec.game.genre = "Platformer"
        rec.game.tags = ["dos", "classic"]
        rec.game.notes = "My notes"
        rec.game.isFavorite = true
        rec.game.settings.cycles = .fixed(12000)
        rec.game.stats = PlayStats(totalPlaySeconds: 3600, lastPlayed: Date(timeIntervalSince1970: 1_700_000_000), launchCount: 9)
        let extra: [String: JSONValue] = ["collections": .array([.string("Favorites")])]
        try io.save(rec.game, extra: extra, to: rec.crateURL)
        try Data("[sdl]\nfullscreen = true\n".utf8).write(to: io.overrideURL(rec.crateURL))
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: io.coverURL(rec.crateURL))
        let saveFile = rec.crateURL.appending(path: "files/SAVES/GAME1.SAV")
        try FileManager.default.createDirectory(at: saveFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved-progress".utf8).write(to: saveFile)
        rec = io.loadRecord(at: rec.crateURL)

        // v2 replaces DATA.DAT and replaces OLD.EXE with two candidates (KEEN1.EXE, SETUP.EXE).
        let v2 = tmp.appending(path: "keen_v2", directoryHint: .isDirectory)
        try touch(v2, "KEEN1.EXE")
        try touch(v2, "SETUP.EXE")
        try Data("v2-data".utf8).write(to: v2.appending(path: "DATA.DAT"))

        let p2 = try await importer.prepare(v2)
        let replaced = try await importer.replace(rec, with: p2, mode: .copy)
        let reloaded = io.loadRecord(at: replaced.crateURL)

        #expect(reloaded.id == rec.id)
        #expect(reloaded.crateURL == rec.crateURL)
        #expect(reloaded.game.title == "Commander Keen")
        #expect(reloaded.game.year == 1990)
        #expect(reloaded.game.developer == "id Software")
        #expect(reloaded.game.publisher == "Apogee")
        #expect(reloaded.game.genre == "Platformer")
        #expect(reloaded.game.tags == ["dos", "classic"])
        #expect(reloaded.game.notes == "My notes")
        #expect(reloaded.game.isFavorite == true)
        #expect(reloaded.game.settings.cycles == .fixed(12000))
        #expect(reloaded.game.stats == rec.game.stats)
        #expect(reloaded.extra["collections"] == .array([.string("Favorites")]))
        #expect(reloaded.game.origin == ImportOrigin.from(v2))
        // OLD.EXE no longer exists in v2 and v2 has 2 candidates -> executable is reset to nil.
        #expect(reloaded.game.launch.executable == nil)

        // New file content wins; old-only save file survives; override.conf and cover.png survive.
        #expect(try String(contentsOf: reloaded.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "v2-data")
        #expect(try String(contentsOf: reloaded.crateURL.appending(path: "files/SAVES/GAME1.SAV"), encoding: .utf8) == "saved-progress")
        #expect(try String(contentsOf: io.overrideURL(reloaded.crateURL), encoding: .utf8) == "[sdl]\nfullscreen = true\n")
        #expect(try Data(contentsOf: io.coverURL(reloaded.crateURL)) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func replaceManagedGameFailureLeavesOldCrateUnchanged() async throws {
        let tmp = try makeImportTempDir()
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let v1 = tmp.appending(path: "keen_v1", directoryHint: .isDirectory)
        try touch(v1, "KEEN1.EXE")
        try Data("original".utf8).write(to: v1.appending(path: "DATA.DAT"))
        let p1 = try await importer.prepare(v1)
        let rec = try await importer.commit(p1, mode: .copy, title: "Keen", executable: "KEEN1.EXE", into: lib)
        try Data("save".utf8).write(to: rec.crateURL.appending(path: "files/SAVE.GAM"))

        let v2 = tmp.appending(path: "keen_v2", directoryHint: .isDirectory)
        try touch(v2, "KEEN2.EXE")
        try Data("updated".utf8).write(to: v2.appending(path: "DATA.DAT"))
        let p2 = try await importer.prepare(v2)

        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rec.crateURL.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        // Force failure by making a file in the new source unreadable so copyTree fails partway through staging.
        let badFile = v2.appending(path: "UNREADABLE.DAT")
        try Data("secret".utf8).write(to: badFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: badFile.path)
        await #expect(throws: (any Error).self) {
            _ = try await importer.replace(rec, with: p2, mode: .copy)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: badFile.path)
        try FileManager.default.removeItem(at: badFile)

        // Also force failure by making the crate directory read-only during swap.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rec.crateURL.path)
        await #expect(throws: (any Error).self) {
            _ = try await importer.replace(rec, with: p2, mode: .copy)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rec.crateURL.path)

        let after = io.loadRecord(at: rec.crateURL)
        #expect(after.game == rec.game)
        #expect(try String(contentsOf: rec.crateURL.appending(path: "files/DATA.DAT"), encoding: .utf8) == "original")
        #expect(try String(contentsOf: rec.crateURL.appending(path: "files/SAVE.GAM"), encoding: .utf8) == "save")
        #expect(!exists(rec.crateURL.appending(path: "files/KEEN2.EXE")))
    }

    @Test func replaceReferencedGameUpdatesPathAndBookmarkAndKeepsID() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let folder1 = tmp.appending(path: "keen_a", directoryHint: .isDirectory)
        try touch(folder1, "KEEN1.EXE")
        let p1 = try await importer.prepare(folder1)
        let rec = try await importer.commit(p1, mode: .reference, title: "Keen", executable: "KEEN1.EXE", into: lib)

        let folder2 = tmp.appending(path: "keen_b", directoryHint: .isDirectory)
        try touch(folder2, "KEEN1.EXE")
        let p2 = try await importer.prepare(folder2)
        let replaced = try await importer.replace(rec, with: p2, mode: .reference)

        #expect(replaced.id == rec.id)
        #expect(replaced.crateURL == rec.crateURL)
        #expect(replaced.game.origin == ImportOrigin.from(folder2))
        let resolved = try io.cDriveURL(for: io.loadRecord(at: replaced.crateURL))
        #expect(resolved.resolvingSymlinksInPath().path == folder2.resolvingSymlinksInPath().path)
        #expect(exists(folder1.appending(path: "KEEN1.EXE")))
        #expect(exists(folder2.appending(path: "KEEN1.EXE")))

        // Mixed mode: referenced -> copy converts crate to managed.
        let toManaged = try await importer.replace(replaced, with: p2, mode: .copy)
        #expect(toManaged.id == rec.id)
        #expect(toManaged.game.source == .managed)
        #expect(exists(toManaged.crateURL.appending(path: "files/KEEN1.EXE")))

        // A managed game asked to become referenced stays managed, so its saves are carried over.
        try Data("saved".utf8).write(to: toManaged.crateURL.appending(path: "files/GAME.SAV"))
        let stillManaged = try await importer.replace(toManaged, with: p1, mode: .reference)
        #expect(stillManaged.id == rec.id)
        #expect(stillManaged.game.source == .managed)
        #expect(io.loadRecord(at: stillManaged.crateURL).game.source == .managed)
        #expect(try String(contentsOf: stillManaged.crateURL.appending(path: "files/GAME.SAV"), encoding: .utf8) == "saved")
        #expect(!exists(folder1.appending(path: "GAME.SAV")))
    }

    @Test func replaceRebasesSoleCandidateOntoKeptCRoot() async throws {
        let tmp = try makeImportTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let lib = tmp.appending(path: "lib", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)

        let v1 = tmp.appending(path: "v1", directoryHint: .isDirectory)
        try touch(v1, "GAME/OLD.EXE")
        let p1 = try await importer.prepare(v1)
        var rec = try await importer.commit(p1, mode: .copy, title: "Game", executable: nil, into: lib)
        rec.game.launch.driveCRoot = "GAME"
        rec.game.launch.executable = "OLD.EXE"
        try io.save(rec.game, extra: rec.extra, to: rec.crateURL)

        // The C: root still exists but OLD.EXE is gone; the sole candidate is GAME/NEW.EXE.
        let v2 = tmp.appending(path: "v2", directoryHint: .isDirectory)
        try touch(v2, "GAME/NEW.EXE")
        let p2 = try await importer.prepare(v2)
        let inRoot = try await importer.replace(io.loadRecord(at: rec.crateURL), with: p2, mode: .copy)
        #expect(inRoot.game.launch.driveCRoot == "GAME")
        #expect(inRoot.game.launch.executable == "NEW.EXE")

        // The sole candidate is outside the kept C: root, so the whole folder becomes C:.
        let v3 = tmp.appending(path: "v3", directoryHint: .isDirectory)
        try touch(v3, "GAME/README.TXT")
        try touch(v3, "RUN.EXE")
        let p3 = try await importer.prepare(v3)
        let outside = try await importer.replace(io.loadRecord(at: rec.crateURL), with: p3, mode: .copy)
        #expect(outside.game.launch.driveCRoot == "")
        #expect(outside.game.launch.executable == "RUN.EXE")
    }
}
