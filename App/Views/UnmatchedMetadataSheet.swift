import LibraryKit
import SwiftUI

struct UnmatchedMetadataSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.retroTheme) private var retroTheme

    static func layout(for theme: AppTheme) -> LibraryLayout {
        LibraryLayout(theme: theme)
    }

    private var isRetro: Bool {
        retroTheme || Self.layout(for: model.prefs.appTheme) == .retro
    }

    private var unmatchedRecords: [GameRecord] {
        model.metadata.unmatched.compactMap { model.store.record($0) }
    }

    var body: some View {
        Group {
            if isRetro {
                retroBody
            } else {
                standardBody
            }
        }
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

    // MARK: - Standard Layout

    private var standardBody: some View {
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
    }

    // MARK: - Retro (DOS) Layout

    private var retroBody: some View {
        RetroPanel(title: "Unmatched Games") {
            VStack(alignment: .leading, spacing: 10) {
                if unmatchedRecords.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        PixelSymbol("checkmark.circle", color: RetroPalette.green, pointSize: 16, scale: 2)
                        Text("All Games Matched")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.highlightText)
                        Text("No games are waiting for a LaunchBox match.")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.cyan)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RetroPalette.desktop)
                    .retroBevel(.sunken)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(unmatchedRecords) { record in
                                HStack(spacing: 8) {
                                    Text(record.game.title)
                                        .font(RetroFont.font())
                                        .foregroundStyle(RetroPalette.highlightText)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Find Metadata…") {
                                        model.findMetadataFor = record.id
                                    }
                                    .buttonStyle(RetroButtonStyle(kind: .text))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(RetroPalette.desktop)
                            }
                        }
                    }
                    .background(RetroPalette.desktop)
                    .retroBevel(.sunken)
                }

                HStack(spacing: 8) {
                    Button("Dismiss All") {
                        model.metadata.dismissUnmatched()
                        dismiss()
                    }
                    .buttonStyle(RetroButtonStyle(kind: .text))
                    .disabled(unmatchedRecords.isEmpty)

                    Spacer()

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(RetroButtonStyle(kind: .text))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 460, height: 360)
    }
}
