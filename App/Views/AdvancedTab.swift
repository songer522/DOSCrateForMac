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
    @State private var loaded = false
    @State private var writeTask: Task<Void, Never>?

    private let io = CrateIO()

    var body: some View {
        Form {
            Section("Override (override.conf)") {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
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
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
    }

    private func write() {
        writeTask = nil
        let url = io.overrideURL(record.crateURL)
        do {
            if text.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try Data(text.utf8).write(to: url, options: .atomic)
            }
        } catch {
            model.alert = AppAlert(title: "Can't save override.conf", message: error.localizedDescription)
        }
    }
}
