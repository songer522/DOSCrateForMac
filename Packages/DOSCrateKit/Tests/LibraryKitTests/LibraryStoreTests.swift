import Foundation
import Testing
@testable import LibraryKit

@MainActor
struct LibraryStoreTests {
    let io = CrateIO()

    func makeLibrary(titles: [String]) throws -> (URL, [URL]) {
        let lib = try makeTempDir()
        var crates: [URL] = []
        for title in titles {
            let crate = try io.makeCrate(title: title, in: lib)
            try io.save(Game(title: title, source: .managed), extra: [:], to: crate)
            crates.append(crate)
        }
        return (lib, crates)
    }

    func rewrite(_ crate: URL, _ edit: (inout [String: Any]) -> Void) throws {
        let file = crate.appending(path: "game.json")
        var obj = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        edit(&obj)
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
    }

    @Test func saveThenReload() async throws {
        let (lib, _) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        var game = try #require(store.records.first).game
        game.title = "Keen 2"
        game.isFavorite = true
        try store.save(game)
        #expect(store.record(game.id)?.game.title == "Keen 2")
        await store.reload()
        #expect(store.records.first?.game == game)
    }

    @Test func reloadPicksUpExternalEdit() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try rewrite(crates[0]) { $0["title"] = "Renamed" }
        await store.reload()
        #expect(store.records.first?.game.title == "Renamed")
    }

    @Test func saveKeepsExtraAfterExternalEdit() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Keen"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        try rewrite(crates[0]) { $0["futureField"] = ["a": 1] }
        var game = try #require(store.records.first).game
        game.notes = "edited"
        try store.save(game)
        let onDisk = try GameFileCodec.decode(Data(contentsOf: crates[0].appending(path: "game.json")))
        #expect(onDisk.extra["futureField"] == .object(["a": .number(1)]))
        #expect(onDisk.game.notes == "edited")
    }

    @Test func removedCrateDisappearsOnReload() async throws {
        let (lib, crates) = try makeLibrary(titles: ["A", "B"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        #expect(store.records.count == 2)
        try FileManager.default.removeItem(at: crates[0])
        await store.reload()
        #expect(store.records.map(\.game.title) == ["B"])
    }

    @Test func removeTrashesManagedFiles() async throws {
        let (lib, crates) = try makeLibrary(titles: ["Gone \(UUID().uuidString)"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        let id = try #require(store.records.first).id
        try store.remove(id, trashFiles: true)
        #expect(!FileManager.default.fileExists(atPath: crates[0].path))
        #expect(store.records.isEmpty)
    }

    @Test func watcherReloadsAfterExternalChange() async throws {
        let (lib, _) = try makeLibrary(titles: ["A"])
        defer { try? FileManager.default.removeItem(at: lib) }
        let store = LibraryStore(library: lib)
        await store.reload()
        store.startWatching()
        defer { store.stopWatching() }
        try await Task.sleep(for: .milliseconds(500))
        let crate = try io.makeCrate(title: "B", in: lib)
        try io.save(Game(title: "B", source: .managed), extra: [:], to: crate)
        for _ in 0..<50 where store.records.count < 2 {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.records.count == 2)
    }
}
