import LibraryKit
import SwiftUI

struct UnmatchedMetadataSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var unmatchedRecords: [GameRecord] {
        model.metadata.unmatched.compactMap { model.store.record($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unmatched Games")
                .font(.headline)

            if unmatchedRecords.isEmpty {
                ContentUnavailableView(
                    "All Games Matched",
                    systemImage: "checkmark.circle",
                    description: Text("No games are waiting for a LaunchBox match.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(unmatchedRecords) { record in
                    HStack {
                        Text(record.game.title)
                            .lineLimit(1)
                        Spacer()
                        Button("Find Metadata…") {
                            model.findMetadataFor = record.id
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered)
            }

            HStack {
                Button("Dismiss All") {
                    model.metadata.dismissUnmatched()
                    dismiss()
                }
                .disabled(unmatchedRecords.isEmpty)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .sheet(
            isPresented: Binding(
                get: { model.findMetadataFor != nil },
                set: { if !$0 { model.findMetadataFor = nil } }
            )
        ) {
            if let id = model.findMetadataFor {
                FindMetadataSheet(model: model, gameID: id)
                    .id(id)
            }
        }
    }
}
