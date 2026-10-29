import Foundation
import LibraryKit
import MetadataKit
import Observation
import SwiftUI

@MainActor @Observable
final class FindMetadataModel {
    let model: AppModel
    let gameID: UUID

    var query: String {
        didSet {
            guard query != oldValue else { return }
            queryGeneration += 1
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                debounceTask?.cancel()
                results = []
                errorText = nil
                isLoading = false
            }
        }
    }
    var results: [MatchCandidate] = []
    var isLoading = false
    var errorText: String?
    var isApplying = false
    var confirmingRecord: LaunchBoxRecord?

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration = 0

    init(model: AppModel, gameID: UUID) {
        self.model = model
        self.gameID = gameID
        self.query = model.store.record(gameID)?.game.title ?? ""
    }

    var emptyStateText: String? {
        guard !isLoading, errorText == nil, results.isEmpty else { return nil }
        return "No matches"
    }

    var showsInSheetReplacePanel: Bool {
        confirmingRecord != nil && model.prefs.appTheme == .dos
    }

    var showsNativeConfirmationDialog: Bool {
        confirmingRecord != nil && model.prefs.appTheme == .standard
    }

    func scheduleSearch() {
        debounceTask?.cancel()
        queryGeneration += 1
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            errorText = nil
            isLoading = false
            return
        }
        let scheduledGeneration = queryGeneration
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.queryGeneration == scheduledGeneration else { return }
            await self.searchNow()
        }
    }

    func searchNow() async {
        queryGeneration += 1
        let generation = queryGeneration
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
            guard generation == queryGeneration else { return }
            if let currentID = model.store.record(gameID)?.game.metadataSource?.id {
                if let idx = matched.firstIndex(where: { $0.record.id == currentID }) {
                    let current = matched.remove(at: idx)
                    matched.insert(current, at: 0)
                }
            }
            results = matched
            isLoading = false
        } catch {
            guard generation == queryGeneration else { return }
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
        model.flushPendingWrites(for: gameID)
        guard let gameRecord = model.store.record(gameID) else { return false }
        let patch = MetadataApplier.patch(from: record)
        let existingArt = MetadataApplier.existingArtKinds(in: gameRecord.crateURL)
        return MetadataApplier.wouldReplace(patch, game: gameRecord.game, existingArt: existingArt)
    }

    /// Returns true if the record can be applied immediately without confirmation,
    /// or false after setting `confirmingRecord` when existing fields/art would be replaced.
    func requestUse(_ record: LaunchBoxRecord) -> Bool {
        if needsReplaceConfirmation(for: record) {
            confirmingRecord = record
            return false
        }
        confirmingRecord = nil
        return true
    }

    func cancelReplaceConfirmation() {
        confirmingRecord = nil
    }

    func confirmReplace() async -> ApplyOutcome? {
        guard let record = confirmingRecord else { return nil }
        confirmingRecord = nil
        return await use(record)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.retroTheme) private var retroTheme

    init(model: AppModel, gameID: UUID) {
        self.model = model
        self.gameID = gameID
        self._viewModel = State(initialValue: FindMetadataModel(model: model, gameID: gameID))
    }

    init(gameID: UUID, model: AppModel) {
        self.init(model: model, gameID: gameID)
    }

    static func layout(for theme: AppTheme) -> LibraryLayout {
        LibraryLayout(theme: theme)
    }

    static func subtitle(for record: LaunchBoxRecord) -> String {
        var parts: [String] = []
        if let year = record.releaseYear {
            parts.append(String(year))
        }
        let dev = record.developer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pub = record.publisher?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !dev.isEmpty {
            parts.append(dev)
        }
        if !pub.isEmpty, pub.caseInsensitiveCompare(dev) != .orderedSame {
            parts.append(pub)
        }
        return parts.joined(separator: " · ")
    }

    private var isRetro: Bool {
        retroTheme || Self.layout(for: model.prefs.appTheme) == .retro
    }

    private var selectedRecord: LaunchBoxRecord? {
        guard let selectedID else { return nil }
        return viewModel.results.first { $0.record.id == selectedID }?.record
    }

    var body: some View {
        Group {
            if isRetro {
                retroBody
            } else {
                standardBody
            }
        }
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
            isPresented: Binding(
                get: { viewModel.showsNativeConfirmationDialog },
                set: { if !$0 { viewModel.cancelReplaceConfirmation() } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.confirmingRecord
        ) { record in
            Button("Replace", role: .destructive) {
                viewModel.cancelReplaceConfirmation()
                applyAndClose(record)
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelReplaceConfirmation()
            }
        }
    }

    // MARK: - Standard Layout

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find Metadata…").font(.headline)

            TextField("Search by title, publisher, developer, or year", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isApplying)
                .onChange(of: viewModel.query) { _, _ in
                    viewModel.scheduleSearch()
                }

            standardContentArea
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
                    triggerUseSelected()
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
    }

    @ViewBuilder private var standardContentArea: some View {
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
                standardCandidateRow(candidate.record)
                    .tag(candidate.record.id)
            }
            .border(Color.secondary.opacity(0.3))
        }
    }

    private func standardCandidateRow(_ record: LaunchBoxRecord) -> some View {
        let patch = MetadataApplier.patch(from: record)
        let frontURL = patch.art[.front]
        let subtitle = Self.subtitle(for: record)

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
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Retro (DOS) Layout

    private var retroBody: some View {
        ZStack {
            RetroPanel(title: "Find Metadata…") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        PixelSymbol("magnifyingglass", color: RetroPalette.bevelDark, pointSize: 16, scale: 1)
                        TextField("Search by title, publisher, developer, or year", text: $viewModel.query)
                            .textFieldStyle(RetroTextFieldStyle())
                            .disabled(viewModel.isApplying || viewModel.showsInSheetReplacePanel)
                            .onChange(of: viewModel.query) { _, _ in
                                viewModel.scheduleSearch()
                            }
                    }

                    retroContentArea
                        .frame(height: 280)
                        .disabled(viewModel.isApplying || viewModel.showsInSheetReplacePanel)

                    Text(LicensesView.launchBoxCredit)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.secondaryText)

                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") {
                            dismiss()
                        }
                        .buttonStyle(RetroButtonStyle(kind: .text))
                        .keyboardShortcut(.cancelAction)
                        .disabled(viewModel.isApplying || viewModel.showsInSheetReplacePanel)

                        Button {
                            triggerUseSelected()
                        } label: {
                            if viewModel.isApplying {
                                HStack(spacing: 6) {
                                    RetroSpinner()
                                    Text("Saving…")
                                        .font(RetroFont.font())
                                }
                            } else {
                                Text("Use This Match")
                            }
                        }
                        .buttonStyle(RetroButtonStyle(kind: .text))
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedRecord == nil || viewModel.isApplying || viewModel.showsInSheetReplacePanel)
                    }
                }
                .padding(12)
            }

            if viewModel.showsInSheetReplacePanel, let record = viewModel.confirmingRecord {
                RetroPalette.shadow.opacity(0.45)
                    .ignoresSafeArea()
                RetroPanel(title: "Replace existing info and art?") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Replace existing info and art for this game with LaunchBox metadata?")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Spacer()
                            Button("Cancel") {
                                viewModel.cancelReplaceConfirmation()
                            }
                            .buttonStyle(RetroButtonStyle(kind: .text))
                            .keyboardShortcut(.cancelAction)

                            Button("Replace") {
                                viewModel.cancelReplaceConfirmation()
                                applyAndClose(record)
                            }
                            .buttonStyle(RetroButtonStyle(kind: .text))
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14)
                }
                .frame(width: 360)
            }
        }
        .frame(width: 520)
    }

    @ViewBuilder private var retroContentArea: some View {
        if let errorText = viewModel.errorText {
            VStack(spacing: 10) {
                Spacer()
                Text(errorText)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.shadow)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await viewModel.searchNow() }
                }
                .buttonStyle(RetroButtonStyle(kind: .text))
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(RetroPalette.desktop)
            .retroBevel(.sunken)
        } else if viewModel.isLoading, let status = model.metadata.statusText {
            VStack(spacing: 10) {
                Spacer()
                RetroSpinner()
                Text(status)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.highlightText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(RetroPalette.desktop)
            .retroBevel(.sunken)
        } else if let empty = viewModel.emptyStateText {
            VStack {
                Spacer()
                Text(empty)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.highlightText)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(RetroPalette.desktop)
            .retroBevel(.sunken)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.results, id: \.record.id) { candidate in
                        retroCandidateRow(candidate.record)
                    }
                }
            }
            .background(RetroPalette.desktop)
            .retroBevel(.sunken)
        }
    }

    private func retroCandidateRow(_ record: LaunchBoxRecord) -> some View {
        let selected = (selectedID == record.id)
        let patch = MetadataApplier.patch(from: record)
        let frontURL = patch.art[.front]
        let subtitle = Self.subtitle(for: record)

        return HStack(spacing: 10) {
            Group {
                if let frontURL {
                    AsyncImage(url: frontURL) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RetroPalette.panel
                    }
                } else {
                    RetroPalette.panel
                }
            }
            .frame(width: 36, height: 48)
            .background(RetroPalette.panel)
            .retroBevel(.sunken)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.highlightText)
                        .lineLimit(1)
                    if let badge = viewModel.badgeText(for: record) {
                        Text(badge)
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .padding(.horizontal, 4)
                            .background(RetroPalette.yellow)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(RetroFont.font())
                        .foregroundStyle(selected ? RetroPalette.highlightText : RetroPalette.cyan)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(selected ? RetroPalette.highlight : RetroPalette.desktop)
        .overlay {
            if selected {
                Rectangle()
                    .strokeBorder(RetroPalette.highlightText, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedID = record.id
            triggerUseSelected()
        }
        .onTapGesture {
            selectedID = record.id
        }
    }

    private func triggerUseSelected() {
        guard let chosen = selectedRecord else { return }
        if viewModel.requestUse(chosen) {
            applyAndClose(chosen)
        }
    }

    private func applyAndClose(_ record: LaunchBoxRecord) {
        Task {
            let outcome = await viewModel.use(record)
            if outcome == .artNotWritable {
                let message = "The game information was saved, but the art files couldn't be written."
                model.metadata.artErrorMessage = message
                if model.prefs.appTheme == .standard {
                    model.alert = AppAlert(title: "Couldn't save art", message: message)
                }
            }
            dismiss()
        }
    }
}
