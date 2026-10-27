import ImportKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Queue of dropped or chosen items; the library window shows one import sheet at a time.
@MainActor @Observable
final class ImportQueue {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var waiting: [URL] = []
    private(set) var current: Item?

    func add(_ urls: [URL]) {
        waiting.append(contentsOf: urls)
        if current == nil { advance() }
    }

    func finishCurrent() { advance() }

    private func advance() { current = waiting.isEmpty ? nil : Item(url: waiting.removeFirst()) }

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
    @State private var mode = ImportMode.copy
    @State private var title = ""
    @State private var executable: String?
    @State private var error: String?
    @State private var isCreating = false

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
