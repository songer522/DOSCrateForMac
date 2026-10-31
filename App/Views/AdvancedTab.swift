import AppKit
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
    @Environment(\.retroTheme) private var retroTheme

    private let io = CrateIO()

    var body: some View {
        ThemedForm {
            ThemedSection("Override (override.conf)") {
                if retroTheme {
                    TextEditor(text: $text)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(minHeight: 140)
                        .background(RetroPalette.bevelLight)
                        .retroBevel(.sunken)
                        .disabled(unreadable)
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 140)
                        .disabled(unreadable)
                }
                if unreadable {
                    Text("override.conf isn't valid UTF-8 text, so it can't be edited here.")
                        .font(retroTheme ? RetroFont.font() : .caption)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                }
                if retroTheme {
                    Link("DOSBox Staging documentation", destination: URL(string: "https://dosbox-staging.github.io/")!)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.desktop)
                        .underline()
                } else {
                    Link("DOSBox Staging documentation", destination: URL(string: "https://dosbox-staging.github.io/")!)
                }
            }
            ThemedSection("Generated config") {
                Text(preview)
                    .font(retroTheme ? RetroFont.font() : .system(.caption, design: .monospaced))
                    .foregroundStyle(retroTheme ? RetroPalette.shadow : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ThemedSection("Logs") {
                let _ = model.sessions.running.contains(record.id)
                let _ = model.lastResult[record.id]
                if let logURL = Self.latestLogURL(for: record.crateURL, io: io) {
                    if retroTheme {
                        HStack(spacing: 8) {
                            Button("View Log") { Self.openLog(logURL) }
                                .buttonStyle(RetroButtonStyle())
                            Button("Show Log in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([logURL])
                            }
                            .buttonStyle(RetroButtonStyle())
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("View Log") { Self.openLog(logURL) }
                            Button("Show Log in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([logURL])
                            }
                        }
                    }
                } else {
                    Text("No log file yet. Launch the game to generate dosbox.log.")
                        .font(retroTheme ? RetroFont.font() : .caption)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                }
            }
        }
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
        let global = model.prefs.launchConfig(gamepads: GamepadDetector.snapshot())
        return LaunchPlanner.generatedConfigPreview(r, global: global, io: io)
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write()
        }
        // Play may come before the debounce fires; let it write the text first.
        model.setPendingWrite(record.id, owner: "override") { [writeTask] in
            writeTask?.cancel()
            write()
        }
    }

    private func write() {
        writeTask = nil
        model.setPendingWrite(record.id, owner: "override", nil)
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

    static func latestLogURL(for crateURL: URL, io: CrateIO = CrateIO()) -> URL? {
        let logsDir = io.logsURL(crateURL)
        let fm = FileManager.default
        let dosboxLog = logsDir.appending(path: "dosbox.log", directoryHint: .notDirectory)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dosboxLog.path, isDirectory: &isDir), !isDir.boolValue {
            return dosboxLog
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: logsDir.path) else {
            return nil
        }
        for name in entries.filter({ $0.hasSuffix(".log") }).sorted().reversed() {
            let candidate = logsDir.appending(path: name, directoryHint: .notDirectory)
            var candidateIsDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &candidateIsDir), !candidateIsDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    static func openLog(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard let console = workspace.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            workspace.open(url)
            return
        }
        workspace.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}
