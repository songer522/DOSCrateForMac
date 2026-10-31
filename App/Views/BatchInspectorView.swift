import LibraryKit
import SwiftUI

struct BatchInspectorView: View {
    struct TagSummary: Equatable, Identifiable, Sendable {
        var id: String { name.lowercased() }
        let name: String
        let count: Int
        let total: Int

        var isOnAll: Bool { count == total }
    }

    enum PresetChoice: Hashable, Equatable, Sendable {
        case mixed
        case presetDefault
        case preset(Preset)

        var displayName: String {
            switch self {
            case .mixed: "Multiple values"
            case .presetDefault: "Preset default"
            case .preset(let preset): preset.displayName
            }
        }
    }

    struct BatchMetadataDraft: Equatable, Sendable {
        var genre: String {
            didSet {
                if genre != oldValue { genreEdited = true }
            }
        }
        var yearText: String {
            didSet {
                if yearText != oldValue { yearEdited = true }
            }
        }
        var developer: String {
            didSet {
                if developer != oldValue { developerEdited = true }
            }
        }
        var publisher: String {
            didSet {
                if publisher != oldValue { publisherEdited = true }
            }
        }

        private(set) var hasMultipleGenres: Bool
        private(set) var hasMultipleYears: Bool
        private(set) var hasMultipleDevelopers: Bool
        private(set) var hasMultiplePublishers: Bool

        var genreEdited = false
        var yearEdited = false
        var developerEdited = false
        var publisherEdited = false

        init(records: [GameRecord]) {
            let genres = records.map { Self.trimmedNonEmpty($0.game.genre) }
            if let first = genres.first, genres.allSatisfy({ $0 == first }) {
                self.genre = first ?? ""
                self.hasMultipleGenres = false
            } else {
                self.genre = ""
                self.hasMultipleGenres = records.count > 1
            }

            let years = records.map(\.game.year)
            if let first = years.first, years.allSatisfy({ $0 == first }) {
                self.yearText = first.map(String.init) ?? ""
                self.hasMultipleYears = false
            } else {
                self.yearText = ""
                self.hasMultipleYears = records.count > 1
            }

            let developers = records.map { Self.trimmedNonEmpty($0.game.developer) }
            if let first = developers.first, developers.allSatisfy({ $0 == first }) {
                self.developer = first ?? ""
                self.hasMultipleDevelopers = false
            } else {
                self.developer = ""
                self.hasMultipleDevelopers = records.count > 1
            }

            let publishers = records.map { Self.trimmedNonEmpty($0.game.publisher) }
            if let first = publishers.first, publishers.allSatisfy({ $0 == first }) {
                self.publisher = first ?? ""
                self.hasMultiplePublishers = false
            } else {
                self.publisher = ""
                self.hasMultiplePublishers = records.count > 1
            }
        }

        var genrePrompt: String? {
            hasMultipleGenres && !genreEdited ? "Multiple values" : nil
        }

        var yearPrompt: String? {
            hasMultipleYears && !yearEdited ? "Multiple values" : nil
        }

        var developerPrompt: String? {
            hasMultipleDevelopers && !developerEdited ? "Multiple values" : nil
        }

        var publisherPrompt: String? {
            hasMultiplePublishers && !publisherEdited ? "Multiple values" : nil
        }

        var isYearValid: Bool {
            let trimmed = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || Int(trimmed) != nil
        }

        var hasChanges: Bool {
            (genreEdited || yearEdited || developerEdited || publisherEdited) && isYearValid
        }

        private static func trimmedNonEmpty(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    let model: AppModel
    let selectedIDs: Set<UUID>

    @State private var newTag = ""
    @State private var metadataDraft: BatchMetadataDraft
    @Environment(\.retroTheme) private var retroTheme

    init(model: AppModel, selectedIDs: Set<UUID>) {
        self.model = model
        self.selectedIDs = selectedIDs
        let selected = Self.selectedRecords(in: model, selectedIDs: selectedIDs)
        self._metadataDraft = State(initialValue: BatchMetadataDraft(records: selected))
    }

    private var selectedRecords: [GameRecord] {
        Self.selectedRecords(in: model, selectedIDs: selectedIDs)
    }

    private var writableRecords: [GameRecord] {
        Self.writableRecords(in: model, selectedIDs: selectedIDs)
    }

    private var isAllReadOnly: Bool {
        writableRecords.isEmpty
    }

    private var allFavorites: Bool {
        !writableRecords.isEmpty && writableRecords.allSatisfy(\.game.isFavorite)
    }

    private var anyFavorites: Bool {
        writableRecords.contains(where: \.game.isFavorite)
    }

    private var tagSummaries: [TagSummary] {
        Self.tagSummaries(in: selectedRecords)
    }

    private var currentPresetChoice: PresetChoice {
        Self.presetChoice(in: selectedRecords)
    }

    private var presetOptions: [PresetChoice] {
        var options: [PresetChoice] = [.presetDefault] + Preset.allCases.map(PresetChoice.preset)
        if currentPresetChoice == .mixed {
            options.insert(.mixed, at: 0)
        }
        return options
    }

    private var presetBinding: Binding<PresetChoice> {
        Binding(
            get: { currentPresetChoice },
            set: { newValue in
                switch newValue {
                case .mixed:
                    break
                case .presetDefault:
                    Self.applyPreset(nil, for: selectedIDs, in: model)
                case .preset(let preset):
                    Self.applyPreset(preset, for: selectedIDs, in: model)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
            ThemedForm {
                favoritesSection
                tagsSection
                metadataSection
                presetSection
            }
            .disabled(isAllReadOnly)
        }
        .onChange(of: selectedIDs) { _, newIDs in
            let records = Self.selectedRecords(in: model, selectedIDs: newIDs)
            metadataDraft = BatchMetadataDraft(records: records)
            newTag = ""
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if retroTheme {
                PixelSymbol("square.stack", color: RetroPalette.desktop, pointSize: 16, scale: 2)
            } else {
                Image(systemName: "square.stack")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(selectedRecords.count) Games Selected")
                    .font(retroTheme ? RetroFont.font() : .title3.bold())
                    .foregroundStyle(retroTheme ? RetroPalette.shadow : .primary)
                if let subtitle = Self.headerSubtitle(
                    selectedCount: selectedRecords.count,
                    writableCount: writableRecords.count
                ) {
                    Text(subtitle)
                        .font(retroTheme ? RetroFont.font() : .callout)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var favoritesSection: some View {
        ThemedSection("Favorites") {
            HStack(spacing: 8) {
                if retroTheme {
                    Button("Add All to Favorites") {
                        Self.setFavorite(true, for: selectedIDs, in: model)
                    }
                    .buttonStyle(RetroButtonStyle())
                    .disabled(allFavorites)

                    Button("Remove All") {
                        Self.setFavorite(false, for: selectedIDs, in: model)
                    }
                    .buttonStyle(RetroButtonStyle())
                    .disabled(!anyFavorites)
                } else {
                    Button("Add All to Favorites", systemImage: "heart.fill") {
                        Self.setFavorite(true, for: selectedIDs, in: model)
                    }
                    .disabled(allFavorites)

                    Button("Remove All", systemImage: "heart.slash") {
                        Self.setFavorite(false, for: selectedIDs, in: model)
                    }
                    .disabled(!anyFavorites)
                }
            }
        }
    }

    private var tagsSection: some View {
        ThemedSection("Tags") {
            if tagSummaries.isEmpty {
                Text("No tags on selected games")
                    .font(retroTheme ? RetroFont.font() : .callout)
                    .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
            } else {
                ForEach(tagSummaries) { summary in
                    HStack(spacing: 8) {
                        Text(summary.name)
                            .font(retroTheme ? RetroFont.font() : .body)
                            .foregroundStyle(retroTheme ? RetroPalette.shadow : .primary)
                        if !summary.isOnAll {
                            Text("\(summary.count) of \(summary.total)")
                                .font(retroTheme ? RetroFont.font() : .caption)
                                .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                        }
                        Spacer()
                        if retroTheme {
                            Button("−") {
                                Self.removeTag(summary.name, for: selectedIDs, in: model)
                            }
                            .buttonStyle(RetroButtonStyle())
                        } else {
                            Button("Remove \(summary.name)", systemImage: "minus.circle") {
                                Self.removeTag(summary.name, for: selectedIDs, in: model)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if retroTheme {
                    TextField("", text: $newTag)
                        .textFieldStyle(RetroTextFieldStyle())
                        .overlay(alignment: .leading) {
                            if newTag.isEmpty {
                                Text("Add tag to all…")
                                    .font(RetroFont.font())
                                    .foregroundStyle(RetroPalette.secondaryText)
                                    .padding(.leading, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onSubmit { submitNewTag() }
                    Button("Add") {
                        submitNewTag()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    TextField("Add tag", text: $newTag, prompt: Text("Add tag to all…"))
                        .labelsHidden()
                        .onSubmit { submitNewTag() }
                    Button("Add") {
                        submitNewTag()
                    }
                    .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var metadataSection: some View {
        ThemedSection("Shared Metadata") {
            ThemedTextField(title: "Genre", text: $metadataDraft.genre, prompt: metadataDraft.genrePrompt)
            ThemedTextField(title: "Year", text: $metadataDraft.yearText, prompt: metadataDraft.yearPrompt)
            ThemedTextField(title: "Developer", text: $metadataDraft.developer, prompt: metadataDraft.developerPrompt)
            ThemedTextField(title: "Publisher", text: $metadataDraft.publisher, prompt: metadataDraft.publisherPrompt)
            HStack {
                if !metadataDraft.isYearValid {
                    Text("Year must be a number")
                        .font(retroTheme ? RetroFont.font() : .caption)
                        .foregroundStyle(retroTheme ? RetroPalette.red : .red)
                }
                Spacer()
                if retroTheme {
                    Button("Apply Metadata") {
                        applyMetadataChanges()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .disabled(!metadataDraft.hasChanges)
                } else {
                    Button("Apply Metadata") {
                        applyMetadataChanges()
                    }
                    .disabled(!metadataDraft.hasChanges)
                }
            }
        }
    }

    private var presetSection: some View {
        ThemedSection("Preset") {
            ThemedValuePicker(
                "Machine preset",
                selection: presetBinding,
                options: presetOptions,
                label: \.displayName
            )
        }
    }

    private func submitNewTag() {
        let tag = newTag
        newTag = ""
        Self.addTag(tag, for: selectedIDs, in: model)
    }

    private func applyMetadataChanges() {
        Self.applyMetadata(metadataDraft, for: selectedIDs, in: model)
        metadataDraft = BatchMetadataDraft(records: Self.selectedRecords(in: model, selectedIDs: selectedIDs))
    }

    // MARK: - Batch Logic & Helpers

    static func isWritable(_ record: GameRecord, in model: AppModel) -> Bool {
        if case .readOnly = record.status { return false }
        if case .needsRepair = record.status { return false }
        if model.imports.replacingIDs.contains(record.id)
            || model.imports.importingIDs.contains(record.id)
            || model.pendingRemovalIDs.contains(record.id) {
            return false
        }
        return true
    }

    static func selectedRecords(in model: AppModel, selectedIDs: Set<UUID>) -> [GameRecord] {
        model.store.records.filter { selectedIDs.contains($0.id) }
    }

    static func writableRecords(in model: AppModel, selectedIDs: Set<UUID>) -> [GameRecord] {
        selectedRecords(in: model, selectedIDs: selectedIDs).filter { isWritable($0, in: model) }
    }

    static func headerSubtitle(selectedCount: Int, writableCount: Int) -> String? {
        guard selectedCount > 0 else { return nil }
        if writableCount == 0 {
            return "All selected games are read-only"
        }
        if writableCount < selectedCount {
            let readOnlyCount = selectedCount - writableCount
            return "\(writableCount) editable · \(readOnlyCount) read-only"
        }
        return nil
    }

    static func tagSummaries(in records: [GameRecord]) -> [TagSummary] {
        guard !records.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        var displayNames: [String: String] = [:]

        for record in records {
            var seenInRecord = Set<String>()
            for raw in record.game.tags {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                guard seenInRecord.insert(key).inserted else { continue }
                counts[key, default: 0] += 1
                if displayNames[key] == nil {
                    displayNames[key] = trimmed
                }
            }
        }

        return counts.keys
            .compactMap { key -> TagSummary? in
                guard let name = displayNames[key], let count = counts[key] else { return nil }
                return TagSummary(name: name, count: count, total: records.count)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func presetChoice(in records: [GameRecord]) -> PresetChoice {
        guard let first = records.first else { return .presetDefault }
        let firstPreset = first.game.settings.preset
        if records.allSatisfy({ $0.game.settings.preset == firstPreset }) {
            return firstPreset.map(PresetChoice.preset) ?? .presetDefault
        }
        return .mixed
    }

    static func setFavorite(_ isFavorite: Bool, for selectedIDs: Set<UUID>, in model: AppModel) {
        for record in writableRecords(in: model, selectedIDs: selectedIDs) {
            model.flushPendingWrites(for: record.id)
            guard var game = model.store.record(record.id)?.game, game.isFavorite != isFavorite else { continue }
            game.isFavorite = isFavorite
            save(game, in: model)
        }
    }

    static func addTag(_ rawTag: String, for selectedIDs: Set<UUID>, in model: AppModel) {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for record in writableRecords(in: model, selectedIDs: selectedIDs) {
            model.flushPendingWrites(for: record.id)
            guard var game = model.store.record(record.id)?.game else { continue }
            let alreadyPresent = game.tags.contains {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }
            guard !alreadyPresent else { continue }
            game.tags.append(trimmed)
            save(game, in: model)
        }
    }

    static func removeTag(_ rawTag: String, for selectedIDs: Set<UUID>, in model: AppModel) {
        let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for record in writableRecords(in: model, selectedIDs: selectedIDs) {
            model.flushPendingWrites(for: record.id)
            guard var game = model.store.record(record.id)?.game else { continue }
            let filtered = game.tags.filter {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(trimmed) != .orderedSame
            }
            guard filtered != game.tags else { continue }
            game.tags = filtered
            save(game, in: model)
        }
    }

    static func applyMetadata(_ draft: BatchMetadataDraft, for selectedIDs: Set<UUID>, in model: AppModel) {
        guard draft.hasChanges else { return }
        for record in writableRecords(in: model, selectedIDs: selectedIDs) {
            model.flushPendingWrites(for: record.id)
            guard var game = model.store.record(record.id)?.game else { continue }
            let original = game

            if draft.genreEdited {
                let trimmed = draft.genre.trimmingCharacters(in: .whitespacesAndNewlines)
                game.genre = trimmed.isEmpty ? nil : trimmed
            }
            if draft.yearEdited, draft.isYearValid {
                let trimmed = draft.yearText.trimmingCharacters(in: .whitespacesAndNewlines)
                game.year = trimmed.isEmpty ? nil : Int(trimmed)
            }
            if draft.developerEdited {
                let trimmed = draft.developer.trimmingCharacters(in: .whitespacesAndNewlines)
                game.developer = trimmed.isEmpty ? nil : trimmed
            }
            if draft.publisherEdited {
                let trimmed = draft.publisher.trimmingCharacters(in: .whitespacesAndNewlines)
                game.publisher = trimmed.isEmpty ? nil : trimmed
            }

            if game != original {
                save(game, in: model)
            }
        }
    }

    static func applyPreset(_ preset: Preset?, for selectedIDs: Set<UUID>, in model: AppModel) {
        for record in writableRecords(in: model, selectedIDs: selectedIDs) {
            model.flushPendingWrites(for: record.id)
            guard var game = model.store.record(record.id)?.game, game.settings.preset != preset else { continue }
            game.settings.preset = preset
            save(game, in: model)
        }
    }

    private static func save(_ game: Game, in model: AppModel) {
        do {
            try model.store.save(game)
        } catch {
            model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
        }
    }
}
