import AppKit
import LauncherKit
import LibraryKit
import SwiftUI

/// Play, Edit, Show in Finder, Favorite and Remove… for one game.
struct GameContextMenu: View {
    let model: AppModel
    let record: GameRecord
    var onEdit: (() -> Void)?
    let onRemove: () -> Void

    static func showsRunSetup(for record: GameRecord, running: Set<UUID>) -> Bool {
        guard !running.contains(record.id),
              let setup = record.game.launch.setupExecutable, !setup.isEmpty else {
            return false
        }
        return true
    }

    var body: some View {
        if model.sessions.running.contains(record.id) {
            Button("Stop") { model.stop(record.id) }
        } else {
            let starting = model.startingIDs.contains(record.id)
            let importing = model.imports.importingIDs.contains(record.id)
            let blocked = model.pendingRemovalIDs.contains(record.id)
                || model.imports.replacingIDs.contains(record.id)
                || importing
                || starting
            Button(starting ? "Starting…" : (importing ? "Importing…" : "Play")) { model.play(record.id) }
                .disabled(blocked)
            if let setup = record.game.launch.setupExecutable, !setup.isEmpty {
                Button("Run Setup") { model.runSetup(record.id) }
                    .disabled(blocked)
            }
        }
        Button("Edit") {
            if let onEdit {
                onEdit()
            } else {
                model.selection = record.id
            }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.crateURL]) }
        let cDriveURL = Self.cDriveFolderURL(for: record)
        Button("Show Game Files (C:) in Finder") {
            if let cDriveURL {
                NSWorkspace.shared.open(cDriveURL)
            }
        }
        .disabled(cDriveURL == nil)
        if let logURL = AdvancedTab.latestLogURL(for: record.crateURL) {
            Button("View Log") { AdvancedTab.openLog(logURL) }
        }
        Button(record.game.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            var game = record.game
            game.isFavorite.toggle()
            do {
                try model.store.save(game)
            } catch {
                model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
            }
        }
        if case .needsRepair = record.status {
            Button("Recreate Game Info…") { model.applyFix(.recreate, for: record.id) }
        }
        Button("Find Metadata…") { model.findMetadataFor = record.id }
            .disabled({
                if case .readOnly = record.status { return true }
                return false
            }())
        Divider()
        // Right-clicking a game in a multiple selection removes the whole selection.
        let count = model.selectedIDs.contains(record.id) ? model.selectedIDs.count : 1
        Button(count > 1 ? "Remove \(count) Games…" : "Remove…", role: .destructive, action: onRemove)
            .disabled(count == 1 && model.sessions.running.contains(record.id))
    }

    static func cDriveFolderURL(for record: GameRecord, io: CrateIO = CrateIO()) -> URL? {
        guard let url = try? io.cDriveURL(for: record) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @AppStorage("libraryShowsGrid") private var showsGrid = true
    @AppStorage("libraryShowsInspector") private var showsInspector = true
    @State private var removing: UUID?
    @State private var removingMany: Set<UUID>?
    @State private var choosingImport = false

    private var records: [GameRecord] {
        model.query.apply(to: model.store.records, now: Date())
    }

    private var commands: LibraryCommands {
        LibraryCommands(
            model: model,
            records: records,
            removing: $removing,
            removingMany: $removingMany,
            showsInspector: $showsInspector
        )
    }

    private var controllerStatus: ControllerStatus? {
        ControllerStatus.make(model.gamepads.devices, enabled: model.prefs.useControllers)
    }

    var body: some View {
        Group {
            // Inspector edits in GameDetailView and AdvancedTab flush in onDisappear, which runs when the layout changes.
            switch LibraryLayout(theme: model.prefs.appTheme) {
            case .standard:
                standardLayout
            case .retro:
                RetroLibraryView(
                    model: model,
                    records: records,
                    commands: commands,
                    showsGrid: $showsGrid,
                    showsInspector: $showsInspector,
                    choosingImport: $choosingImport
                )
            }
        }
        .background(RetroWindowChrome(isRetro: model.prefs.appTheme == .dos))
        .modifier(LibraryActions(model: model, records: records, removing: $removing,
                                 removingMany: $removingMany, choosingImport: $choosingImport))
    }

    private var standardLayout: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let progress = model.imports.progress {
                        statusBar {
                            ProgressView(value: Double(progress.current), total: Double(max(progress.total, 1)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 180)
                            Text(progress.label)
                        }
                    } else if !model.imports.importingIDs.isEmpty {
                        statusBar(cancellable: false) {
                            ProgressView().controlSize(.small)
                            Text(Self.singleImportStatusText(for: model) ?? "Importing…")
                        }
                    } else if model.isScanningLibrary {
                        statusBar {
                            ProgressView().controlSize(.small)
                            Text("Looking for games…")
                        }
                    } else if model.imports.isCheckingDuplicates {
                        statusBar {
                            ProgressView().controlSize(.small)
                            Text("Checking for duplicates…")
                        }
                    } else if let removal = model.removalProgress {
                        statusBar(cancellable: Self.showsRemovalCancel(for: model), onCancel: { model.cancelRemoval() }) {
                            ProgressView(value: Double(removal.done), total: Double(max(removal.total, 1)))
                                .progressViewStyle(.linear)
                                .frame(maxWidth: 180)
                            Text("Removing \(removal.done) of \(removal.total)…")
                        }
                    } else if let metadataText = model.metadata.statusText {
                        statusBar(cancellable: false) {
                            if case .downloading(let fraction) = model.metadata.phase {
                                ProgressView(value: min(1.0, max(0.0, fraction)), total: 1.0)
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 140)
                            } else if case .building = model.metadata.phase {
                                ProgressView().controlSize(.small)
                            } else if let findProgress = model.metadata.findMissingProgress {
                                ProgressView(value: Double(findProgress.current), total: Double(max(findProgress.total, 1)))
                                    .progressViewStyle(.linear)
                                    .frame(maxWidth: 140)
                            }
                            Text(metadataText)
                            if Self.showsMetadataRetry(for: model) {
                                Button("Retry") { model.metadata.retry() }
                                    .controlSize(.small)
                            } else if Self.showsFindMissingCancel(for: model) {
                                Button("Cancel") { model.metadata.cancelFindMissing() }
                                    .controlSize(.small)
                            } else if Self.showsUnmatchedReview(for: model) {
                                Button("Review") { model.showingUnmatchedMetadata = true }
                                    .controlSize(.small)
                            }
                        }
                    } else if controllerStatus != nil {
                        statusBar(cancellable: false) {}
                    }
                }
                .navigationTitle("DOSCrate")
                .searchable(text: $model.query.search)
                .toolbar { toolbar }
                .inspector(isPresented: $showsInspector) {
                    Group {
                        if let record = model.selection.flatMap(model.store.record) {
                            GameDetailView(model: model, record: record).id(record.id)
                        } else if model.selectedIDs.count > 1 {
                            BatchInspectorView(model: model, selectedIDs: model.selectedIDs)
                        } else {
                            ContentUnavailableView("No Game Selected", systemImage: "gamecontroller")
                        }
                    }
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 560)
                }
        }
    }

    private func statusBar(
        cancellable: Bool = true,
        onCancel: (() -> Void)? = nil,
        @ViewBuilder _ items: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                items()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let status = controllerStatus {
                    Label(status.label, systemImage: "gamecontroller")
                        .font(.callout)
                        .foregroundStyle(status.enabled ? .secondary : .tertiary)
                        .monospacedDigit()
                }
                if cancellable {
                    Button("Cancel") { (onCancel ?? { model.cancelImport() })() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    @ViewBuilder private var content: some View {
        if records.isEmpty {
            ContentUnavailableView(model.store.records.isEmpty ? "No Games Yet" : "No Matches",
                                   systemImage: "gamecontroller",
                                   description: Text(model.store.records.isEmpty
                                                     ? "Import a game folder, zip or disc image to get started."
                                                     : "Try a different search or collection."))
        } else if showsGrid {
            GameGridView(model: model, records: records, menu: commands.menu)
                .onDeleteCommand { commands.requestRemoval(model.selectedIDs) }
        } else {
            GameListView(model: model, records: records, menu: commands.menu, onRemove: commands.requestRemoval)
                .onDeleteCommand { commands.requestRemoval(model.selectedIDs) }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $showsGrid) {
                Label("Grid", systemImage: "square.grid.2x2").tag(true)
                Label("List", systemImage: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu {
                LibraryFilterMenuContent(model: model)
            } label: {
                Label(
                    "Filter",
                    systemImage: model.query.hasActiveMetadataFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
            .help("Filter")
        }
        ToolbarItem {
            Menu("Sort", systemImage: "arrow.up.arrow.down") {
                sortButton("Title", .title)
                sortButton("Year", .year)
                sortButton("Last Played", .lastPlayed)
                sortButton("Play Time", .playTime)
            }
        }
        ToolbarItem {
            Button("Details", systemImage: "sidebar.trailing") { showsInspector.toggle() }
        }
        ToolbarItem {
            Button("Import", systemImage: "plus") { choosingImport = true }
        }
        ToolbarItem {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }

    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.query.sort = key
        } label: {
            if model.query.sort == key { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    static func singleImportStatusText(for model: AppModel) -> String? {
        let ids = model.imports.importingIDs
        guard !ids.isEmpty else { return nil }
        if ids.count == 1, let id = ids.first, let title = model.store.record(id)?.game.title {
            return "Importing \(title)…"
        }
        return "Importing \(ids.count) games…"
    }

    static func statusBarLeadingText(for model: AppModel) -> String? {
        if let progress = model.imports.progress {
            return progress.label
        } else if let singleImportText = singleImportStatusText(for: model) {
            return singleImportText
        } else if model.isScanningLibrary {
            return "Looking for games…"
        } else if model.imports.isCheckingDuplicates {
            return "Checking for duplicates…"
        } else if let removal = model.removalProgress {
            return "Removing \(removal.done) of \(removal.total)…"
        } else if let metadataText = model.metadata.statusText {
            return metadataText
        }
        return nil
    }

    static func showsMetadataRetry(for model: AppModel) -> Bool {
        guard model.imports.progress == nil,
              model.imports.importingIDs.isEmpty,
              !model.isScanningLibrary,
              !model.imports.isCheckingDuplicates,
              model.removalProgress == nil
        else { return false }
        if case .failed = model.metadata.phase {
            return true
        }
        return false
    }

    static func showsUnmatchedReview(for model: AppModel) -> Bool {
        guard model.imports.progress == nil,
              !model.isScanningLibrary,
              !model.imports.isCheckingDuplicates,
              model.removalProgress == nil
        else { return false }
        return model.metadata.showsUnmatchedReview
    }

    static func showsFindMissingCancel(for model: AppModel) -> Bool {
        guard model.imports.progress == nil,
              !model.isScanningLibrary,
              !model.imports.isCheckingDuplicates,
              model.removalProgress == nil
        else { return false }
        return model.metadata.showsFindMissingCancel
    }

    static func showsRemovalCancel(for model: AppModel) -> Bool {
        guard model.imports.progress == nil,
              !model.isScanningLibrary,
              !model.imports.isCheckingDuplicates
        else { return false }
        return model.removalProgress != nil
    }

    /// What removal does, worded per source: a managed game's files live in its crate, so they always go with it.
    static func removalMessage(for record: GameRecord, running: Bool) -> String {
        if running { return "Stop \"\(record.game.title)\" before removing it." }
        if case .referenced(let path, _) = record.game.source {
            return "\"\(record.game.title)\" will be removed from the library. Its folder at \(path) stays where it is, "
                + "unless you also move its files to the Trash."
        }
        return "\"\(record.game.title)\" and its game files will be moved to the Trash."
    }

    /// What removing several games does: copied games always go to the Trash with their files; kept-in-place
    /// folders stay unless the user also trashes them; running games are skipped.
    static func removalMessage(for records: [GameRecord], running: Set<UUID>) -> String {
        let active = records.filter { !running.contains($0.id) }
        let referenced = active.filter { if case .referenced = $0.game.source { true } else { false } }.count
        let copied = active.count - referenced
        func games(_ n: Int) -> String { n == 1 ? "1 game" : "\(n) games" }
        var parts: [String] = []
        if copied > 0 {
            parts.append("\(games(copied)) copied into the library will be moved to the Trash with "
                + (copied == 1 ? "its files." : "their files."))
        }
        if referenced > 0 {
            parts.append("\(games(referenced)) kept in place will be removed from the library. "
                + (referenced == 1 ? "Its folder stays where it is, unless you also move it to the Trash."
                                   : "Their folders stay where they are, unless you also move them to the Trash."))
        }
        let skipped = records.count - active.count
        if skipped > 0 {
            parts.append("\(games(skipped)) still running will be skipped.")
        }
        return parts.joined(separator: " ")
    }
}

struct LibraryFilterMenuContent: View {
    @Bindable var model: AppModel

    private var genres: [String] {
        Self.includingSelected(model.query.genre, in: allGenres(in: model.store.records))
    }

    private var years: [Int] {
        var result = allYears(in: model.store.records)
        if let selected = model.query.year, !result.contains(selected) {
            result.append(selected)
            result.sort()
        }
        return result
    }

    private var publishers: [String] {
        Self.includingSelected(model.query.publisher, in: allPublishers(in: model.store.records))
    }

    private var developers: [String] {
        Self.includingSelected(model.query.developer, in: allDevelopers(in: model.store.records))
    }

    var body: some View {
        stringFilterMenu(
            title: model.query.genre.map { "Genre: \($0)" } ?? "Genre",
            allTitle: "All Genres",
            options: genres,
            selection: $model.query.genre
        )
        Menu(model.query.year.map { "Year: \(String($0))" } ?? "Year") {
            Button {
                model.query.year = nil
            } label: {
                if model.query.year == nil {
                    Label("All Years", systemImage: "checkmark")
                } else {
                    Text("All Years")
                }
            }
            if !years.isEmpty {
                Divider()
                ForEach(years, id: \.self) { year in
                    let label = String(year)
                    Button {
                        model.query.year = (model.query.year == year) ? nil : year
                    } label: {
                        if model.query.year == year {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            }
        }
        stringFilterMenu(
            title: model.query.publisher.map { "Publisher: \($0)" } ?? "Publisher",
            allTitle: "All Publishers",
            options: publishers,
            selection: $model.query.publisher
        )
        stringFilterMenu(
            title: model.query.developer.map { "Developer: \($0)" } ?? "Developer",
            allTitle: "All Developers",
            options: developers,
            selection: $model.query.developer
        )
        Divider()
        Button("Clear Filters") {
            model.query.clearMetadataFilters()
        }
        .disabled(!model.query.hasActiveMetadataFilter)
    }

    private func stringFilterMenu(
        title: String,
        allTitle: String,
        options: [String],
        selection: Binding<String?>
    ) -> some View {
        Menu(title) {
            Button {
                selection.wrappedValue = nil
            } label: {
                if selection.wrappedValue == nil {
                    Label(allTitle, systemImage: "checkmark")
                } else {
                    Text(allTitle)
                }
            }
            if !options.isEmpty {
                Divider()
                ForEach(options, id: \.self) { option in
                    let isSelected = selection.wrappedValue.map {
                        $0.localizedCaseInsensitiveCompare(option) == .orderedSame
                    } ?? false
                    Button {
                        selection.wrappedValue = isSelected ? nil : option
                    } label: {
                        if isSelected {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            }
        }
    }

    static func includingSelected(_ selected: String?, in values: [String]) -> [String] {
        guard let selected else { return values }
        let containsSelected = values.contains { $0.localizedCaseInsensitiveCompare(selected) == .orderedSame }
        guard !containsSelected else { return values }
        return (values + [selected]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
