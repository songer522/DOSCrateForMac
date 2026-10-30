import LibraryKit
import SwiftUI

struct GameListView: View {
    @Bindable var model: AppModel
    let records: [GameRecord]
    let menu: (GameRecord) -> GameContextMenu
    let onRemove: (Set<UUID>) -> Void

    var body: some View {
        Table(records, selection: $model.selectedIDs) {
            TableColumn("Title") { record in
                HStack {
                    Text(record.game.title)
                    if model.sessions.running.contains(record.id) {
                        Image(systemName: "play.circle.fill").foregroundStyle(.green)
                    } else if model.startingIDs.contains(record.id) {
                        ProgressView().controlSize(.small)
                        Text("Starting…").font(.caption).foregroundStyle(.secondary)
                    } else if model.imports.importingIDs.contains(record.id) {
                        ProgressView().controlSize(.small)
                        Text("Importing…").font(.caption).foregroundStyle(.secondary)
                    } else if model.metadata.artLoading.contains(record.id) {
                        ProgressView().controlSize(.small)
                    }
                    switch record.status {
                    case .missingSource: Text("Missing").font(.caption).foregroundStyle(.orange)
                    case .needsRepair: Text("Needs repair").font(.caption).foregroundStyle(.red)
                    case .readOnly: Text("Read-only").font(.caption).foregroundStyle(.secondary)
                    case .ok: EmptyView()
                    }
                }
            }
            TableColumn("Year") { Text($0.game.year.map(String.init) ?? "") }
                .width(60)
            TableColumn("Developer") { Text($0.game.developer ?? "") }
            TableColumn("Last Played") { record in
                if let date = record.game.stats.lastPlayed {
                    Text(date, format: .dateTime.year().month().day())
                }
            }
            TableColumn("Play Time") { record in
                let seconds = record.game.stats.totalPlaySeconds
                if seconds > 0 {
                    Text(Duration.seconds(seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let record = model.store.record(id) {
                menu(record)
            } else if ids.count > 1 {
                Button("Remove \(ids.count) Games…", role: .destructive) { onRemove(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.play(id) }
        }
    }
}
