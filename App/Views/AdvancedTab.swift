import ConfigKit
import LauncherKit
import LibraryKit
import SwiftUI

/// The raw `override.conf` editor plus a read-only preview of the config DOSCrate generates.
struct AdvancedTab: View {
    let model: AppModel
    let record: GameRecord
    let game: Game

    @State private var text = ""
    @State private var loadedText = ""
    @State private var loaded = false
    @State private var unreadable = false
    @State private var writeTask: Task<Void, Never>?

    private let io = CrateIO()

    var body: some View {
        Form {
            Section("Override (override.conf)") {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .disabled(unreadable)
                if unreadable {
                    Text("override.conf isn't valid UTF-8 text, so it can't be edited here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Link("DOSBox Staging documentation", destination: URL(string: "https://dosbox-staging.github.io/")!)
            }
            Section("Generated config") {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .task {
            let url = io.overrideURL(record.crateURL)
            if FileManager.default.fileExists(atPath: url.path) {
                if let existing = try? String(contentsOf: url, encoding: .utf8) {
                    text = existing
                } else {
                    unreadable = true
                }
            }
            loadedText = text
            loaded = true
        }
        .onChange(of: text) { _, _ in if loaded { scheduleWrite() } }
        .onDisappear { if writeTask != nil { write() } }
    }

    private var preview: String {
        var r = record
        r.game = game
        return LaunchPlanner.generatedConfigPreview(r, global: model.prefs.globalConfig, io: io)
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write()
        }
        // Play may come before the debounce fires; let it write the text first.
        model.setPendingWrite(record.id) { [writeTask] in
            writeTask?.cancel()
            write()
        }
    }

    private func write() {
        writeTask = nil
        model.setPendingWrite(record.id, nil)
        guard !unreadable, text != loadedText else { return }
        let url = io.overrideURL(record.crateURL)
        do {
            if text.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
            loadedText = text
        } catch {
            model.alert = AppAlert(title: "Can't save override.conf", message: error.localizedDescription)
        }
    }
}
