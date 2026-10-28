import LibraryKit
import SwiftUI

struct RetroSidebar: View {
    @Bindable var model: AppModel
    @State private var renaming: String?
    @State private var newName = ""
    @State private var removing: String?

    var body: some View {
        RetroPanel(title: "Library") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    filterRow("All Games", symbol: "square.grid.2x2", filter: .all)
                    filterRow("Recently Played", symbol: "clock", filter: .recent)
                    filterRow("Favorites", symbol: "star", filter: .favorites)

                    let tags = allTags(in: model.store.records)
                    if !tags.isEmpty {
                        Text("Collections")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.bevelDark)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(tags, id: \.self) { tag in
                            filterRow(tag, symbol: "folder", filter: .tag(tag))
                                .contextMenu {
                                    Button("Rename…") { newName = tag; renaming = tag }
                                    Button("Remove Collection", role: .destructive) { removing = tag }
                                }
                        }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .alert("Rename Collection", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let old = renaming { CollectionTags.rename(old, to: newName, in: model) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove this collection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove Collection", role: .destructive) { if let tag = removing { CollectionTags.remove(tag, in: model) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("The games stay in your library.")
        }
    }

    private func filterRow(_ title: String, symbol: String, filter: SidebarFilter) -> some View {
        let selected = model.query.filter == filter
        return Button {
            model.query.filter = filter
        } label: {
            HStack(spacing: 6) {
                PixelSymbol(symbol, color: selected ? RetroPalette.highlightText : RetroPalette.desktop, pointSize: 16, scale: 1)
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(selected ? RetroPalette.highlightText : RetroPalette.shadow)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(selected ? RetroPalette.highlight : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
