import LibraryKit
import SwiftUI

/// Pure tag rewrites behind renaming and removing a collection.
enum CollectionTags {
    static func renamed(_ tags: [String], from old: String, to new: String) -> [String] {
        var result: [String] = []
        for tag in tags {
            let mapped = tag == old ? new : tag
            if !result.contains(mapped) { result.append(mapped) }
        }
        return result
    }

    static func removed(_ tags: [String], tag: String) -> [String] {
        tags.filter { $0 != tag }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var renaming: String?
    @State private var newName = ""
    @State private var removing: String?

    var body: some View {
        List(selection: $model.query.filter) {
            Section("Library") {
                Label("All Games", systemImage: "square.grid.2x2").tag(SidebarFilter.all)
                Label("Recently Played", systemImage: "clock").tag(SidebarFilter.recent)
                Label("Favorites", systemImage: "star").tag(SidebarFilter.favorites)
            }
            let tags = allTags(in: model.store.records)
            if !tags.isEmpty {
                Section("Collections") {
                    ForEach(tags, id: \.self) { tag in
                        Label(tag, systemImage: "folder").tag(SidebarFilter.tag(tag))
                            .contextMenu {
                                Button("Rename…") { newName = tag; renaming = tag }
                                Button("Remove Collection", role: .destructive) { removing = tag }
                            }
                    }
                }
            }
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let old = renaming { rename(old, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove this collection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Collection", role: .destructive) { if let tag = removing { remove(tag) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The games stay in your library.")
        }
    }

    private func rename(_ old: String, to name: String) {
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old else { return }
        rewrite(old) { CollectionTags.renamed($0, from: old, to: new) }
        if model.query.filter == .tag(old) { model.query.filter = .tag(new) }
    }

    private func remove(_ tag: String) {
        rewrite(tag) { CollectionTags.removed($0, tag: tag) }
        if model.query.filter == .tag(tag) { model.query.filter = .all }
    }

    private func rewrite(_ tag: String, _ transform: ([String]) -> [String]) {
        for record in model.store.records where record.game.tags.contains(tag) {
            var game = record.game
            game.tags = transform(game.tags)
            do {
                try model.store.save(game)
            } catch {
                model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
                return
            }
        }
    }
}
