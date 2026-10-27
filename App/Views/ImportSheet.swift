import ImportKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Handles dropped or chosen items: one item opens `ImportSheet`; two or more run as a background batch.
@MainActor @Observable
final class ImportQueue {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let defaultMode: ImportMode
    }

    struct BatchPrompt: Identifiable, Equatable {
        let id = UUID()
        var urls: [URL]
        var presetMode: ImportMode?
        var matches: [URL: DuplicateMatch] = [:]

        var duplicateTitles: [String] {
            urls.compactMap { matches[$0]?.record.game.title }
        }
        var duplicateCount: Int { matches.count }
        var hasDuplicates: Bool { !matches.isEmpty }
        var duplicateMessage: String {
            "\(duplicateCount) of \(urls.count) items are already in your library"
        }
        var title: String {
            if presetMode != nil, hasDuplicates {
                return duplicateMessage
            }
            return "Import \(urls.count) items"
        }
    }

    struct BatchEntry: Equatable, Sendable {
        var url: URL
        var mode: ImportMode
        var replacing: UUID?

        init(url: URL, mode: ImportMode, replacing: UUID? = nil) {
            self.url = url
            self.mode = mode
            self.replacing = replacing
        }
    }

    struct Progress: Equatable {
        var current: Int
        var total: Int
        var label: String { "Importing \(current) of \(total)…" }
    }

    private var waiting: [Item] = []
    private var waitingPrompts: [BatchPrompt] = []
    private var batchEntries: [BatchEntry] = []
    private var batchTask: Task<Void, Never>?
    private var checkingCount = 0
    private var checkGeneration = 0
    private(set) var current: Item?
    private(set) var batchPrompt: BatchPrompt?
    private(set) var progress: Progress?
    var isCheckingDuplicates: Bool { checkingCount > 0 }
    /// Index in `batchEntries` of the item the running batch is importing.
    private var batchIndex = 0
    /// Test hook called inside each batch item's detached task before preparing the item.
    var itemHook: (@Sendable (URL) async -> Void)?

    @discardableResult
    func add(_ urls: [URL], model: AppModel) -> Task<Void, Never>? {
        guard !urls.isEmpty else { return nil }
        let preference = model.prefs.importLocation
        if urls.count == 1 {
            waiting.append(Item(url: urls[0], defaultMode: preference.defaultMode))
            if current == nil { advance() }
            return nil
        }
        let records = model.store.records
        if records.isEmpty {
            switch preference {
            case .ask:
                waitingPrompts.append(BatchPrompt(urls: urls, presetMode: nil, matches: [:]))
                if batchPrompt == nil { advanceBatchPrompt() }
                return nil
            case .copy, .reference:
                let mode: ImportMode = preference == .reference ? .reference : .copy
                return enqueue(urls.map { BatchEntry(url: $0, mode: mode) }, model: model)
            }
        }
        let presetMode: ImportMode? = switch preference {
        case .ask: nil
        case .copy: .copy
        case .reference: .reference
        }
        let startedGeneration = checkGeneration
        checkingCount += 1
        return Task {
            let matches = await Task.detached { Self.findDuplicates(for: urls, in: records) }.value
            guard startedGeneration == checkGeneration else { return }
            checkingCount -= 1
            if let presetMode, matches.isEmpty {
                await enqueue(urls.map { BatchEntry(url: $0, mode: presetMode) }, model: model)?.value
            } else {
                waitingPrompts.append(BatchPrompt(urls: urls, presetMode: presetMode, matches: matches))
                if batchPrompt == nil { advanceBatchPrompt() }
            }
        }
    }

    nonisolated private static func findDuplicates(for urls: [URL], in records: [GameRecord]) -> [URL: DuplicateMatch] {
        guard !records.isEmpty else { return [:] }
        let index = DuplicateIndex(records)
        var matches: [URL: DuplicateMatch] = [:]
        for url in urls {
            if let match = index.match(for: url) {
                matches[url] = match
            }
        }
        return matches
    }

    @discardableResult
    func confirmBatch(
        mode: ImportMode? = nil,
        remember: Bool = false,
        duplicateAction: DuplicateAction = .skip,
        model: AppModel
    ) -> Task<Void, Never>? {
        guard let prompt = batchPrompt else { return nil }
        let resolvedMode = mode ?? prompt.presetMode ?? model.prefs.importLocation.defaultMode
        if remember {
            model.prefs.importLocation = resolvedMode == .reference ? .reference : .copy
        }
        advanceBatchPrompt()
        var entries: [BatchEntry] = []
        for url in prompt.urls {
            if let match = prompt.matches[url] {
                switch duplicateAction {
                case .skip:
                    continue
                case .replace:
                    entries.append(BatchEntry(url: url, mode: resolvedMode, replacing: match.record.id))
                case .keepBoth:
                    entries.append(BatchEntry(url: url, mode: resolvedMode, replacing: nil))
                }
            } else {
                entries.append(BatchEntry(url: url, mode: resolvedMode, replacing: nil))
            }
        }
        return enqueue(entries, model: model)
    }

    func cancelBatch() {
        advanceBatchPrompt()
    }

    @discardableResult
    func finishSingleImport(
        _ prepared: PreparedImport,
        action: DuplicateAction,
        replacing existing: GameRecord? = nil,
        mode: ImportMode,
        title: String,
        executable: String?,
        model: AppModel
    ) async throws -> GameRecord? {
        let importer = model.importer
        let library = model.store.library
        let effectiveMode = prepared.allowsReference ? mode : .copy
        switch action {
        case .skip:
            importer.discard(prepared)
            return nil
        case .replace:
            guard let existing else {
                importer.discard(prepared)
                return nil
            }
            guard !model.sessions.running.contains(existing.id) else {
                model.alert = AppModel.alert(for: .alreadyRunning, gameID: existing.id, game: existing.game)
                importer.discard(prepared)
                return nil
            }
            let fresh = CrateIO().loadRecord(at: existing.crateURL)
            let record = try await Task.detached {
                try await importer.replace(fresh, with: prepared, mode: effectiveMode)
            }.value
            importer.discard(prepared)
            await model.store.reload()
            model.selection = record.id
            return record
        case .keepBoth:
            let record = try await Task.detached {
                try await importer.commit(
                    prepared, mode: effectiveMode, title: title, executable: executable, into: library
                )
            }.value
            importer.discard(prepared)
            await model.store.reload()
            model.selection = record.id
            return record
        }
    }

    @discardableResult
    func enqueue(_ entries: [BatchEntry], model: AppModel) -> Task<Void, Never>? {
        guard !entries.isEmpty else { return nil }
        batchEntries.append(contentsOf: entries)
        progress = Progress(current: progress?.current ?? 1, total: batchEntries.count)
        if batchTask == nil {
            batchTask = Task { await runBatch(model: model) }
        }
        return batchTask
    }

    /// Stops the running batch after the item in progress (or cancels a duplicate check); games already imported stay in the library.
    func cancelBatchImport() {
        if checkingCount > 0 {
            checkGeneration += 1
            checkingCount = 0
        }
        guard batchTask != nil, batchIndex + 1 < batchEntries.count else { return }
        batchEntries.removeSubrange((batchIndex + 1)...)
        progress = Progress(current: batchIndex + 1, total: batchEntries.count)
    }

    func finishCurrent() { advance() }

    private func advance() { current = waiting.isEmpty ? nil : waiting.removeFirst() }

    private func advanceBatchPrompt() {
        batchPrompt = waitingPrompts.isEmpty ? nil : waitingPrompts.removeFirst()
    }

    private func runBatch(model: AppModel) async {
        let importer = model.importer
        let library = model.store.library
        let hook = itemHook
        let io = CrateIO()
        var firstID: UUID?
        var selectedFirst = false
        var dirtyCount = 0
        var lastReload = ContinuousClock.now
        var failures: [String] = []
        batchIndex = 0

        model.store.isWatcherSuppressed = true
        defer { model.store.isWatcherSuppressed = false }

        while batchIndex < batchEntries.count {
            let entry = batchEntries[batchIndex]
            progress = Progress(current: batchIndex + 1, total: batchEntries.count)
            do {
                var replaceTarget: GameRecord?
                if let replaceID = entry.replacing {
                    if model.sessions.running.contains(replaceID) {
                        throw ImportError.alreadyRunning
                    }
                    if let currentRecord = model.store.record(replaceID) {
                        replaceTarget = io.loadRecord(at: currentRecord.crateURL)
                    }
                }
                let target = replaceTarget
                let record = try await Task.detached {
                    await hook?(entry.url)
                    let prepared = try await importer.prepare(entry.url)
                    defer { importer.discard(prepared) }
                    let mode = prepared.allowsReference ? entry.mode : .copy
                    if let target {
                        return try await importer.replace(target, with: prepared, mode: mode)
                    }
                    let executable = prepared.candidates.count == 1 ? prepared.candidates[0].relativePath : nil
                    return try await importer.commit(
                        prepared, mode: mode, title: prepared.suggestedTitle, executable: executable, into: library
                    )
                }.value
                if firstID == nil { firstID = record.id }
                dirtyCount += 1
                let now = ContinuousClock.now
                if dirtyCount >= 10 || now - lastReload >= .seconds(1) {
                    await model.store.reload()
                    dirtyCount = 0
                    lastReload = ContinuousClock.now
                    if !selectedFirst, let firstID {
                        model.selection = firstID
                        selectedFirst = true
                    }
                }
            } catch {
                failures.append("\(entry.url.lastPathComponent): \(importErrorMessage(error))")
            }
            batchIndex += 1
        }

        if dirtyCount > 0 {
            await model.store.reload()
        }
        batchEntries.removeAll()
        batchTask = nil
        progress = nil
        if let firstID { model.selection = firstID }
        if !failures.isEmpty {
            model.alert = AppAlert(
                title: failures.count == 1 ? "Couldn't import 1 item" : "Couldn't import \(failures.count) items",
                message: failures.joined(separator: "\n")
            )
        }
    }

    /// Folders, zips and the disc and floppy image types the importer accepts.
    static let contentTypes: [UTType] = [.folder, .zip] + ["iso", "cue", "img", "ima"].compactMap { UTType(filenameExtension: $0) }
}

/// Inline text for an import failure.
func importErrorMessage(_ error: Error) -> String {
    guard let error = error as? ImportError else { return error.localizedDescription }
    switch error {
    case .unsupportedType(let ext):
        return ext.isEmpty ? "DOSCrate can't import this kind of item."
            : "DOSCrate can't import \".\(ext)\" files. Choose a folder, zip, ISO/CUE or IMG/IMA."
    case .noExecutables:
        return "No .EXE, .COM or .BAT program was found in this item."
    case .unzipFailed(let detail):
        return detail.isEmpty ? "The zip file couldn't be unpacked." : "The zip file couldn't be unpacked: \(detail)"
    case .referenceNotAllowed:
        return "Only a folder can be kept in place. Choose Copy into library."
    case .mediaNameCollision(let name):
        return "Two different files in this disc image are named \"\(name)\"."
    case .alreadyRunning:
        return "This game is already running."
    }
}

struct ImportSheet: View {
    let model: AppModel
    let url: URL
    let onFinish: () -> Void

    @State private var prepared: PreparedImport?
    @State private var duplicateMatch: DuplicateMatch?
    @State private var mode: ImportMode
    @State private var title = ""
    @State private var executable: String?
    @State private var error: String?
    @State private var isCreating = false

    init(model: AppModel, url: URL, defaultMode: ImportMode? = nil, onFinish: @escaping () -> Void) {
        self.model = model
        self.url = url
        self.onFinish = onFinish
        self._mode = State(initialValue: defaultMode ?? model.prefs.importLocation.defaultMode)
    }

    nonisolated static func duplicateNotice(for match: DuplicateMatch) -> String {
        switch match.kind {
        case .sameSource:
            return "\"\(match.record.game.title)\" is already in your library."
        case .sameTitle:
            return "A game named \"\(match.record.game.title)\" is already in your library."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(url.lastPathComponent)").font(.headline)
            if let prepared {
                form(prepared)
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(url.lastPathComponent)…")
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if let match = duplicateMatch {
                    Button("Skip", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isCreating)
                    Button("Keep Both", action: create)
                        .disabled(prepared == nil || isCreating || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Replace") { replace(match.record) }
                        .disabled(prepared == nil || isCreating)
                } else {
                    Button("Cancel", role: .cancel, action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isCreating)
                    Button("Create", action: create)
                        .keyboardShortcut(.defaultAction)
                        .disabled(prepared == nil || isCreating || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await prepare() }
    }

    @ViewBuilder private func form(_ prepared: PreparedImport) -> some View {
        if let match = duplicateMatch {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.duplicateNotice(for: match))
                    .font(.callout.weight(.medium))
                Text("Keeps saves, settings and play history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Picker("Location", selection: $mode) {
            Text("Copy into library").tag(ImportMode.copy)
            Text("Keep in place").tag(ImportMode.reference)
        }
        .pickerStyle(.radioGroup)
        .disabled(!prepared.allowsReference || isCreating)
        if !prepared.allowsReference {
            Text("Archives and images are always copied.").font(.caption).foregroundStyle(.secondary)
        }
        if !prepared.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Program")
                List(prepared.candidates, id: \.relativePath, selection: $executable) { candidate in
                    Text(candidate.relativePath).tag(candidate.relativePath)
                }
                .frame(height: 140)
                .border(Color.secondary.opacity(0.3))
            }
        } else {
            Text("Install the game from D: after it is created.").font(.caption).foregroundStyle(.secondary)
        }
        TextField("Title", text: $title)
    }

    private func prepare() async {
        let importer = model.importer
        let source = url
        let records = model.store.records
        do {
            let (result, match) = try await Task.detached {
                let prepared = try await importer.prepare(source)
                let match = DuplicateIndex(records).match(for: prepared)
                return (prepared, match)
            }.value
            if Task.isCancelled {
                importer.discard(result)
                return
            }
            prepared = result
            duplicateMatch = match
            if !result.allowsReference { mode = .copy }
            title = result.suggestedTitle
            executable = result.candidates.first?.relativePath
        } catch {
            self.error = importErrorMessage(error)
        }
    }

    private func create() {
        guard let prepared else { return }
        isCreating = true
        error = nil
        let mode = prepared.allowsReference ? mode : .copy
        let title = title.trimmingCharacters(in: .whitespaces)
        let executable = executable
        Task {
            do {
                _ = try await model.imports.finishSingleImport(
                    prepared, action: .keepBoth, mode: mode, title: title, executable: executable, model: model
                )
                onFinish()
            } catch {
                self.error = importErrorMessage(error)
                isCreating = false
            }
        }
    }

    private func replace(_ existing: GameRecord) {
        guard let prepared else { return }
        isCreating = true
        error = nil
        let mode = prepared.allowsReference ? mode : .copy
        let title = title.trimmingCharacters(in: .whitespaces)
        let executable = executable
        Task {
            do {
                _ = try await model.imports.finishSingleImport(
                    prepared, action: .replace, replacing: existing, mode: mode, title: title,
                    executable: executable, model: model
                )
                onFinish()
            } catch {
                self.error = importErrorMessage(error)
                isCreating = false
            }
        }
    }

    private func cancel() {
        guard !isCreating else { return }
        if let prepared { model.importer.discard(prepared) }
        onFinish()
    }
}

struct BatchImportSheet: View {
    let model: AppModel
    let prompt: ImportQueue.BatchPrompt

    @State private var mode = ImportMode.copy
    @State private var remember = false
    @State private var duplicateAction = DuplicateAction.skip
    @State private var showsDuplicates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title).font(.headline)
            if prompt.presetMode == nil {
                Picker("Location", selection: $mode) {
                    Text("Copy into library").tag(ImportMode.copy)
                    Text("Keep in place").tag(ImportMode.reference)
                }
                .pickerStyle(.radioGroup)
                Text("Zips and disc images are always copied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Remember my choice", isOn: $remember)
            }
            if prompt.hasDuplicates {
                if prompt.presetMode == nil {
                    Divider()
                    Text(prompt.duplicateMessage).font(.subheadline.weight(.medium))
                }
                DisclosureGroup("Already in library (\(prompt.duplicateCount))", isExpanded: $showsDuplicates) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(prompt.duplicateTitles.enumerated()), id: \.offset) { _, name in
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                .font(.caption)
                Picker("Duplicates", selection: $duplicateAction) {
                    Text("Skip duplicates").tag(DuplicateAction.skip)
                    Text("Replace").tag(DuplicateAction.replace)
                    Text("Keep Both").tag(DuplicateAction.keepBoth)
                }
                .pickerStyle(.radioGroup)
                Text("Keeps saves, settings and play history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.imports.cancelBatch()
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    model.imports.confirmBatch(
                        mode: prompt.presetMode ?? mode,
                        remember: prompt.presetMode == nil ? remember : false,
                        duplicateAction: duplicateAction,
                        model: model
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct ChooseProgramSheet: View {
    let model: AppModel
    let request: ChooseProgramRequest

    @State private var selection: String?

    init(model: AppModel, request: ChooseProgramRequest) {
        self.model = model
        self.request = request
        self._selection = State(initialValue: request.candidates.first?.relativePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title).font(.headline)
            Text("Choose which program starts this game.").font(.subheadline).foregroundStyle(.secondary)
            List(request.candidates, id: \.relativePath, selection: $selection) { candidate in
                Text(candidate.relativePath).tag(candidate.relativePath)
            }
            .frame(height: 160)
            .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Choose another file…") { model.chooseAnotherProgram() }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelChooseProgram() }
                    .keyboardShortcut(.cancelAction)
                Button("Play") {
                    if let selection { model.confirmProgram(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
