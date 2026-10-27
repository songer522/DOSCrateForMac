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
        var title: String { "Import \(urls.count) items" }
    }

    struct BatchEntry: Equatable, Sendable {
        var url: URL
        var mode: ImportMode
    }

    struct Progress: Equatable {
        var current: Int
        var total: Int
        var label: String { "Importing \(current) of \(total)…" }
    }

    private var waiting: [Item] = []
    private var batchEntries: [BatchEntry] = []
    private var batchTask: Task<Void, Never>?
    private(set) var current: Item?
    private(set) var batchPrompt: BatchPrompt?
    private(set) var progress: Progress?
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
        switch preference {
        case .ask:
            batchPrompt = BatchPrompt(urls: urls)
            return nil
        case .copy:
            return enqueue(urls.map { BatchEntry(url: $0, mode: .copy) }, model: model)
        case .reference:
            return enqueue(urls.map { BatchEntry(url: $0, mode: .reference) }, model: model)
        }
    }

    @discardableResult
    func confirmBatch(mode: ImportMode, remember: Bool = false, model: AppModel) -> Task<Void, Never>? {
        guard let prompt = batchPrompt else { return nil }
        batchPrompt = nil
        if remember {
            model.prefs.importLocation = mode == .reference ? .reference : .copy
        }
        return enqueue(prompt.urls.map { BatchEntry(url: $0, mode: mode) }, model: model)
    }

    func cancelBatch() {
        batchPrompt = nil
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

    func finishCurrent() { advance() }

    private func advance() { current = waiting.isEmpty ? nil : waiting.removeFirst() }

    private func runBatch(model: AppModel) async {
        let importer = model.importer
        let library = model.store.library
        let hook = itemHook
        var firstID: UUID?
        var failures: [String] = []
        var index = 0

        while index < batchEntries.count {
            let entry = batchEntries[index]
            progress = Progress(current: index + 1, total: batchEntries.count)
            do {
                let record = try await Task.detached {
                    await hook?(entry.url)
                    let prepared = try await importer.prepare(entry.url)
                    defer { importer.discard(prepared) }
                    let mode = prepared.allowsReference ? entry.mode : .copy
                    let executable = prepared.candidates.count == 1 ? prepared.candidates[0].relativePath : nil
                    return try await importer.commit(
                        prepared, mode: mode, title: prepared.suggestedTitle, executable: executable, into: library
                    )
                }.value
                await model.store.reload()
                if firstID == nil {
                    firstID = record.id
                    model.selection = record.id
                }
            } catch {
                failures.append("\(entry.url.lastPathComponent): \(importErrorMessage(error))")
            }
            index += 1
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
    }
}

struct ImportSheet: View {
    let model: AppModel
    let url: URL
    let onFinish: () -> Void

    @State private var prepared: PreparedImport?
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
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(prepared == nil || isCreating || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await prepare() }
    }

    @ViewBuilder private func form(_ prepared: PreparedImport) -> some View {
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
        do {
            let result = try await Task.detached { try await importer.prepare(source) }.value
            if Task.isCancelled {
                importer.discard(result)
                return
            }
            prepared = result
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
        let importer = model.importer
        let library = model.store.library
        let mode = prepared.allowsReference ? mode : .copy
        let title = title.trimmingCharacters(in: .whitespaces)
        let executable = executable
        Task {
            do {
                // Copying can take a while; keep it off the main actor.
                let record = try await Task.detached {
                    try await importer.commit(prepared, mode: mode, title: title, executable: executable, into: library)
                }.value
                importer.discard(prepared)
                await model.store.reload()
                model.selection = record.id
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title).font(.headline)
            Picker("Location", selection: $mode) {
                Text("Copy into library").tag(ImportMode.copy)
                Text("Keep in place").tag(ImportMode.reference)
            }
            .pickerStyle(.radioGroup)
            Text("Zips and disc images are always copied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Remember my choice", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.imports.cancelBatch()
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    model.imports.confirmBatch(mode: mode, remember: remember, model: model)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
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
