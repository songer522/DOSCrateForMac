import AppKit
import ConfigKit
import LibraryKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case defaults = "Defaults"
        case audio = "Audio"
        case updates = "Updates"

        var id: Self { self }
    }

    let model: AppModel
    /// Nil when updates are not configured (Debug builds).
    let updater: SPUUpdater?
    @State private var selectedTab: Tab
    @Environment(\.retroTheme) private var retroTheme

    init(model: AppModel, updater: SPUUpdater?, initialTab: Tab = .general) {
        self.model = model
        self.updater = updater
        self._selectedTab = State(initialValue: initialTab)
    }

    private var isRetro: Bool {
        retroTheme || LibraryLayout(theme: model.prefs.appTheme) == .retro
    }

    var body: some View {
        Group {
            if isRetro {
                RetroPanel(title: "Settings") {
                    VStack(spacing: 0) {
                        ThemedSegmented(
                            "Section",
                            showsTitle: false,
                            selection: $selectedTab,
                            options: Tab.allCases,
                            label: \.rawValue
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                        RetroPalette.bevelDark.frame(height: 1)

                        Group {
                            switch selectedTab {
                            case .general:
                                GeneralPreferences(model: model)
                            case .defaults:
                                DefaultsPreferences(prefs: model.prefs)
                            case .audio:
                                AudioPreferences(prefs: model.prefs)
                            case .updates:
                                UpdatesPreferences(updater: updater)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .retroControls()
            } else {
                TabView(selection: $selectedTab) {
                    GeneralPreferences(model: model)
                        .tabItem { Label("General", systemImage: "gearshape") }
                        .tag(Tab.general)
                    DefaultsPreferences(prefs: model.prefs)
                        .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                        .tag(Tab.defaults)
                    AudioPreferences(prefs: model.prefs)
                        .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                        .tag(Tab.audio)
                    UpdatesPreferences(updater: updater)
                        .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                        .tag(Tab.updates)
                }
            }
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
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        ThemedLabeledRow(title) {
            HStack(spacing: 6) {
                Text(path.isEmpty ? placeholder : path)
                    .font(retroTheme ? RetroFont.font() : .body)
                    .foregroundStyle(
                        retroTheme
                            ? (path.isEmpty ? RetroPalette.secondaryText : RetroPalette.shadow)
                            : (path.isEmpty ? Color.secondary : Color.primary)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Choose…", action: onChoose)
                if let onClear, !path.isEmpty { Button("Clear", action: onClear) }
            }
        }
    }
}

struct GeneralPreferences: View {
    let model: AppModel
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        @Bindable var prefs = model.prefs
        ThemedForm {
            ThemedSection {
                PathRow(title: "Library location", path: prefs.libraryPath, onChoose: chooseLibrary)
                ThemedValuePicker("Theme", selection: $prefs.appTheme, options: AppTheme.allCases, label: \.displayName)
                ThemedValuePicker("Default preset", selection: $prefs.defaultPreset, options: Preset.allCases, label: \.displayName)
                ThemedValuePicker(
                    "When importing",
                    selection: $prefs.importLocation,
                    options: ImportLocationPreference.allCases,
                    label: \.displayName
                )
                Toggle("Fetch metadata on import", isOn: $prefs.fetchMetadataOnImport)
                ThemedLabeledRow("LaunchBox database") {
                    HStack(spacing: 8) {
                        Text(Self.lastUpdatedText(model.metadata.lastUpdated))
                            .font(retroTheme ? RetroFont.font() : .body)
                            .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                        Button("Refresh LaunchBox data") {
                            Self.refreshLaunchBox(model: model)
                        }
                    }
                }
                Toggle("Use game controllers", isOn: $prefs.useControllers)
                Text("Maps the d-pad, left stick, A/B/X/Y and Start to keyboard keys.")
                    .font(retroTheme ? RetroFont.font() : .caption)
                    .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
            }
        }
    }

    static func lastUpdatedText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return "Last updated \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    static func refreshLaunchBox(model: AppModel) {
        model.metadata.refreshIndex()
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
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        ThemedForm {
            Text("Applied to every game before its own settings.")
                .font(retroTheme ? RetroFont.font() : .body)
                .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
            CuratedSettingsSections(settings: $prefs.globalOverrides, showsPreset: false)
            ThemedSection("Raw DOSBox settings") {
                if retroTheme {
                    TextEditor(text: $prefs.rawGlobalOverrides)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RetroPalette.bevelLight)
                        .retroBevel(.sunken)
                } else {
                    TextEditor(text: $prefs.rawGlobalOverrides)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

private struct AudioPreferences: View {
    @Bindable var prefs: Preferences

    var body: some View {
        ThemedForm {
            ThemedSection {
                PathRow(title: "SoundFont (.sf2)", path: prefs.soundfontPath, onChoose: chooseSoundfont,
                        onClear: { prefs.soundfontPath = "" })
                PathRow(title: "MT-32 ROM folder", path: prefs.mt32RomDir, onChoose: chooseRomFolder,
                        onClear: { prefs.mt32RomDir = "" })
            }
        }
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
    @Environment(\.retroTheme) private var retroTheme

    init(updater: SPUUpdater?) {
        self.updater = updater
        _automatic = State(initialValue: updater?.automaticallyChecksForUpdates ?? false)
    }

    var body: some View {
        ThemedForm {
            ThemedSection {
                Toggle("Automatically check for updates", isOn: $automatic)
                    .disabled(updater == nil)
                    .onChange(of: automatic) { _, new in updater?.automaticallyChecksForUpdates = new }
                if updater == nil {
                    Text("Updates are not configured in this build.")
                        .font(retroTheme ? RetroFont.font() : .body)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                }
            }
        }
        .onAppear {
            automatic = updater?.automaticallyChecksForUpdates ?? false
        }
    }
}
