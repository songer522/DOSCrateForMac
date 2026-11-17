import LibraryKit
import SwiftUI

struct RetroSidebar: View {
    @Bindable var model: AppModel
    @Binding var renaming: String?
    @Binding var newName: String
    @Binding var removing: String?

    init(
        model: AppModel,
        renaming: Binding<String?> = .constant(nil),
        newName: Binding<String> = .constant(""),
        removing: Binding<String?> = .constant(nil)
    ) {
        self.model = model
        self._renaming = renaming
        self._newName = newName
        self._removing = removing
    }

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
