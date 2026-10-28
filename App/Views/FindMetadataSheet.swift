import Foundation
import LibraryKit
import MetadataKit
import Observation
import SwiftUI

@MainActor @Observable
final class FindMetadataModel {
    let model: AppModel
    let gameID: UUID

    var query: String
    var results: [MatchCandidate] = []
    var isLoading = false
    var errorText: String?
    var isApplying = false

    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(model: AppModel, gameID: UUID) {
        self.model = model
        self.gameID = gameID
        self.query = model.store.record(gameID)?.game.title ?? ""
    }

    var emptyStateText: String? {
        guard !isLoading, errorText == nil, results.isEmpty else { return nil }
        return "No matches"
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.searchNow()
        }
    }

    func searchNow() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorText = nil
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        do {
            var matched = try await model.metadata.candidates(for: trimmed)
            if let currentID = model.store.record(gameID)?.game.metadataSource?.id {
                if let idx = matched.firstIndex(where: { $0.record.id == currentID }) {
                    let current = matched.remove(at: idx)
                    matched.insert(current, at: 0)
                }
            }
            results = matched
            isLoading = false
        } catch {
            results = []
            errorText = model.metadata.statusText ?? "LaunchBox data unavailable"
            isLoading = false
        }
    }

    func isCurrent(_ record: LaunchBoxRecord) -> Bool {
        model.store.record(gameID)?.game.metadataSource?.id == record.id
    }

    func badgeText(for record: LaunchBoxRecord) -> String? {
        isCurrent(record) ? "Current" : nil
    }

    func needsReplaceConfirmation(for record: LaunchBoxRecord) -> Bool {
        guard let gameRecord = model.store.record(gameID) else { return false }
        let patch = MetadataApplier.patch(from: record)
        let existingArt = MetadataApplier.existingArtKinds(in: gameRecord.crateURL)
        return MetadataApplier.wouldReplace(patch, game: gameRecord.game, existingArt: existingArt)
    }

    func use(_ record: LaunchBoxRecord) async -> ApplyOutcome {
        isApplying = true
        defer { isApplying = false }
        return await model.metadata.apply(record, to: gameID, mode: .replace)
    }
}

struct FindMetadataSheet: View {
    let model: AppModel
    let gameID: UUID

    @State private var viewModel: FindMetadataModel
    @State private var selectedID: Int?
    @State private var confirmingRecord: LaunchBoxRecord?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, gameID: UUID) {
        self.model = model
        self.gameID = gameID
        self._viewModel = State(initialValue: FindMetadataModel(model: model, gameID: gameID))
    }

    init(gameID: UUID, model: AppModel) {
        self.init(model: model, gameID: gameID)
    }

    private var selectedRecord: LaunchBoxRecord? {
        guard let selectedID else { return nil }
        return viewModel.results.first { $0.record.id == selectedID }?.record
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Metadata…").font(.headline)

            TextField("Search", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isApplying)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.scheduleSearch()
                }

            contentArea
                .frame(height: 280)
                .disabled(viewModel.isApplying)

            Text(LicensesView.launchBoxCredit)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.isApplying)

                Button {
                    guard let chosen = selectedRecord else { return }
                    if viewModel.needsReplaceConfirmation(for: chosen) {
                        confirmingRecord = chosen
                    } else {
                        applyAndClose(chosen)
                    }
                } label: {
                    if viewModel.isApplying {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 100)
                    } else {
                        Text("Use This Match")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRecord == nil || viewModel.isApplying)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await viewModel.searchNow()
            if selectedID == nil {
                selectedID = viewModel.results.first?.record.id
            }
        }
        .onChange(of: viewModel.results) { _, newResults in
            if let selectedID, newResults.contains(where: { $0.record.id == selectedID }) {
                return
            }
            selectedID = newResults.first?.record.id
        }
        .confirmationDialog(
            "Replace existing info and art?",
            isPresented: Binding(get: { confirmingRecord != nil }, set: { if !$0 { confirmingRecord = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRecord
        ) { record in
            Button("Replace", role: .destructive) {
                confirmingRecord = nil
                applyAndClose(record)
            }
            Button("Cancel", role: .cancel) {
                confirmingRecord = nil
            }
        }
    }

    @ViewBuilder private var contentArea: some View {
        if let errorText = viewModel.errorText {
            VStack(spacing: 8) {
                Spacer()
                Text(errorText).foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await viewModel.searchNow() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.isLoading, let status = model.metadata.statusText {
            VStack(spacing: 8) {
                Spacer()
                ProgressView().controlSize(.small)
                Text(status).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let empty = viewModel.emptyStateText {
            VStack {
                Spacer()
                Text(empty).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(viewModel.results, id: \.record.id, selection: $selectedID) { candidate in
                candidateRow(candidate.record)
                    .tag(candidate.record.id)
            }
            .border(Color.secondary.opacity(0.3))
        }
    }

    private func candidateRow(_ record: LaunchBoxRecord) -> some View {
        let patch = MetadataApplier.patch(from: record)
        let frontURL = patch.art[.front]
        let subtitleParts = [
            record.releaseYear.map(String.init),
            record.developer,
        ].compactMap { $0 }.filter { !$0.isEmpty }

        return HStack(spacing: 10) {
            Group {
                if let frontURL {
                    AsyncImage(url: frontURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 36, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name).font(.body.weight(.medium)).lineLimit(1)
                    if let badge = viewModel.badgeText(for: record) {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                if !subtitleParts.isEmpty {
                    Text(subtitleParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func applyAndClose(_ record: LaunchBoxRecord) {
        Task {
            let outcome = await viewModel.use(record)
            if outcome == .artNotWritable {
                model.alert = AppAlert(
                    title: "Couldn't save art",
                    message: "The game information was saved, but the art files couldn't be written."
                )
            }
            dismiss()
        }
    }
}
