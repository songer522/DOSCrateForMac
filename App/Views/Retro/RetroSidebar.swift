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

    static func showsNeedsAttention(attentionCount: Int, filter: SidebarFilter) -> Bool {
        attentionCount > 0 || filter == .needsAttention
    }

    var body: some View {
        let records = model.store.records
        let attentionCount = LibraryQuery.count(for: .needsAttention, in: records)
        RetroPanel(title: "Library") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    filterRow(
                        "All Games",
                        symbol: "square.grid.2x2",
                        filter: .all,
                        count: LibraryQuery.count(for: .all, in: records)
                    )
                    filterRow(
                        "Recently Played",
                        symbol: "clock",
                        filter: .recent,
                        count: LibraryQuery.count(for: .recent, in: records)
                    )
                    filterRow(
                        "Favorites",
                        symbol: "star",
                        filter: .favorites,
                        count: LibraryQuery.count(for: .favorites, in: records)
                    )
                    if Self.showsNeedsAttention(attentionCount: attentionCount, filter: model.query.filter) {
                        filterRow(
                            "Needs Attention",
                            symbol: "exclamationmark.triangle.fill",
                            filter: .needsAttention,
                            count: attentionCount
                        )
                    }

                    let tags = allTags(in: records)
                    if !tags.isEmpty {
                        Text("Collections")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.bevelDark)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(tags, id: \.self) { tag in
                            filterRow(
                                tag,
                                symbol: "folder",
                                filter: .tag(tag),
                                count: LibraryQuery.count(for: .tag(tag), in: records)
                            )
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
        .task(id: model.query.filter) {
            await model.store.refreshAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.store.refreshAttention() }
        }
    }

    private func filterRow(_ title: String, symbol: String, filter: SidebarFilter, count: Int) -> some View {
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
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(RetroFont.font())
                    .foregroundStyle(selected ? RetroPalette.highlightText : RetroPalette.secondaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(selected ? RetroPalette.highlight : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
