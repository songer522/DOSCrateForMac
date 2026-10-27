import LibraryKit
import SwiftUI

struct GameGridView: View {
    let model: AppModel
    let records: [GameRecord]
    let menu: (GameRecord) -> GameContextMenu

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(records) { record in
                    VStack(spacing: 6) {
                        CoverView(record: record, isRunning: model.sessions.running.contains(record.id))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: model.selection == record.id ? 3 : 0)
                            }
                        Text(record.game.title).lineLimit(2).multilineTextAlignment(.center)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.play(record.id) }
                    .onTapGesture { model.selection = record.id }
                    .contextMenu { menu(record) }
                }
            }
            .padding()
        }
    }
}
