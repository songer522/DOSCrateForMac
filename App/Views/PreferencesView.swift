import AppKit
import ConfigKit
import LibraryKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    let model: AppModel
    /// Nil when updates are not configured (Debug builds).
    let updater: SPUUpdater?

    var body: some View {
        TabView {
            GeneralPreferences(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            DefaultsPreferences(prefs: model.prefs)
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            AudioPreferences(prefs: model.prefs)
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            UpdatesPreferences(updater: updater)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520, height: 460)
    }
}

/// A read-only path with a Choose button and a Clear button.
private struct PathRow: View {
    let title: String
    let path: String
    var placeholder = "None"
    var onChoose: () -> Void
    var onClear: (() -> Void)?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(path.isEmpty ? placeholder : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Choose…", action: onChoose)
                if let onClear, !path.isEmpty { Button("Clear", action: onClear) }
            }
        }
    }
}

private struct GeneralPreferences: View {
    let model: AppModel

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            PathRow(title: "Library location", path: prefs.libraryPath, onChoose: chooseLibrary)
            Picker("Default preset", selection: $prefs.defaultPreset) {
                ForEach(Preset.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use as Library"
        if panel.runModal() == .OK, let url = panel.url {
            model.chooseLibrary(url, create: false)
        }
    }
}

private struct DefaultsPreferences: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Text("Applied to every game before its own settings.").foregroundStyle(.secondary)
            CuratedSettingsSections(settings: $prefs.globalOverrides)
            Section("Raw DOSBox settings") {
                TextEditor(text: $prefs.rawGlobalOverrides)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioPreferences: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            PathRow(title: "SoundFont (.sf2)", path: prefs.soundfontPath, onChoose: chooseSoundfont,
                    onClear: { prefs.soundfontPath = "" })
            PathRow(title: "MT-32 ROM folder", path: prefs.mt32RomDir, onChoose: chooseRomFolder,
                    onClear: { prefs.mt32RomDir = "" })
        }
        .formStyle(.grouped)
    }

    private func chooseSoundfont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sf2")].compactMap { $0 }
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { prefs.soundfontPath = url.path }
    }

    private func chooseRomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { prefs.mt32RomDir = url.path }
    }
}

private struct UpdatesPreferences: View {
    let updater: SPUUpdater?
    @State private var automatic: Bool

    init(updater: SPUUpdater?) {
        self.updater = updater
        _automatic = State(initialValue: updater?.automaticallyChecksForUpdates ?? false)
    }

    var body: some View {
        Form {
            Toggle("Automatically check for updates", isOn: $automatic)
                .disabled(updater == nil)
                .onChange(of: automatic) { _, new in updater?.automaticallyChecksForUpdates = new }
            if updater == nil {
                Text("Updates are not configured in this build.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
