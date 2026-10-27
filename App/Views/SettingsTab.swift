import AppKit
import ImportKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

extension Cycles {
    static let fixedRange = 100...500_000

    static func clampedFixed(_ n: Int) -> Cycles {
        .fixed(Swift.min(Swift.max(n, fixedRange.lowerBound), fixedRange.upperBound))
    }
}

/// The segmented choice above the fixed-cycles field; `.preset` is the inherit (nil) state.
enum CyclesMode: String, CaseIterable, Identifiable {
    case preset = "Preset", auto = "Auto", max = "Max", fixed = "Fixed"
    var id: Self { self }

    init(_ cycles: Cycles?) {
        switch cycles {
        case nil: self = .preset
        case .auto: self = .auto
        case .max: self = .max
        case .fixed: self = .fixed
        }
    }

    func cycles(fixed n: Int) -> Cycles? {
        switch self {
        case .preset: nil
        case .auto: .auto
        case .max: .max
        case .fixed: .clampedFixed(n)
        }
    }
}

/// A picker whose first row, "Preset default", is nil: the field is not stored and the default applies.
struct OptionalPicker<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T?

    init(_ title: String, selection: Binding<T?>, options: [T], label: @escaping (T) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Preset default").tag(T?.none)
            Divider()
            ForEach(options, id: \.self) { Text(label($0)).tag(T?.some($0)) }
        }
    }
}

// MARK: Reusable sections (also used by the Preferences Defaults tab)

/// Every curated per-game setting group (spec section 4.2) that lives in `GameSettings`.
struct CuratedSettingsSections: View {
    @Binding var settings: GameSettings
    /// Off for the global defaults, where the preset comes from General › Default preset instead.
    var showsPreset = true

    var body: some View {
        if showsPreset { PresetSection(settings: $settings) }
        CPUSection(settings: $settings)
        MemorySection(settings: $settings)
        GraphicsSection(settings: $settings)
        SoundSection(settings: $settings)
        InputSection(settings: $settings)
    }
}

struct PresetSection: View {
    @Binding var settings: GameSettings
    var body: some View {
        Section("Preset") {
            OptionalPicker("Machine preset", selection: $settings.preset, options: Preset.allCases, label: \.displayName)
        }
    }
}

struct CPUSection: View {
    @Binding var settings: GameSettings
    @State private var lastFixed: Int

    init(settings: Binding<GameSettings>) {
        self._settings = settings
        var seed = 3000
        if case .fixed(let n) = settings.wrappedValue.cycles { seed = n }
        self._lastFixed = State(initialValue: seed)
    }

    private var mode: Binding<CyclesMode> {
        Binding(get: { CyclesMode(settings.cycles) },
                set: { settings.cycles = $0.cycles(fixed: lastFixed) })
    }

    private var fixedValue: Binding<Int> {
        Binding(get: {
                    if case .fixed(let n) = settings.cycles { return n }
                    return lastFixed
                },
                set: {
                    let clamped = Cycles.clampedFixed($0)
                    if case .fixed(let n) = clamped { lastFixed = n }
                    settings.cycles = clamped
                })
    }

    var body: some View {
        Section("CPU") {
            Picker("Cycles", selection: mode) {
                ForEach(CyclesMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if CyclesMode(settings.cycles) == .fixed {
                TextField("Fixed cycles", value: fixedValue, format: .number.grouping(.never))
                    .help("100 to 500000")
            }
            OptionalPicker("Core", selection: $settings.core, options: CPUCore.allCases, label: \.displayName)
        }
    }
}

struct MemorySection: View {
    static let sizes = [1, 2, 4, 8, 16, 32, 64]
    @Binding var settings: GameSettings
    var body: some View {
        Section("Memory") {
            OptionalPicker("Memory size", selection: $settings.memoryMB, options: Self.sizes) { "\($0) MB" }
        }
    }
}

struct GraphicsSection: View {
    static let shaders = ["crt-auto", "crt-auto-machine", "crt-auto-arcade", "sharp", "bilinear", "nearest"]
    @Binding var settings: GameSettings
    var body: some View {
        Section("Graphics") {
            OptionalPicker("Machine", selection: $settings.machine, options: Machine.allCases, label: \.displayName)
            OptionalPicker("Shader", selection: $settings.shader, options: Self.shaders) { $0 }
            OptionalPicker("Aspect", selection: $settings.aspect, options: Aspect.allCases, label: \.displayName)
            OptionalPicker("Start fullscreen", selection: $settings.fullscreen, options: [true, false]) { $0 ? "Yes" : "No" }
        }
    }
}

struct SoundSection: View {
    @Binding var settings: GameSettings
    var body: some View {
        Section("Sound") {
            OptionalPicker("Sound card", selection: $settings.soundCard, options: SoundCard.allCases, label: \.displayName)
            OptionalPicker("MIDI", selection: $settings.midi, options: MIDIMode.allCases, label: \.displayName)
        }
    }
}

struct InputSection: View {
    @Binding var settings: GameSettings

    private var layout: Binding<String> {
        Binding(get: { settings.keyboardLayout ?? "" },
                set: { settings.keyboardLayout = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        Section("Input") {
            OptionalPicker("Mouse capture", selection: $settings.mouseCapture, options: MouseCapture.allCases, label: \.displayName)
            TextField("Keyboard layout", text: layout, prompt: Text("auto"))
        }
    }
}

// MARK: Per-game groups

struct DrivesSection: View {
    let record: GameRecord
    @Binding var game: Game
    var onError: (String, String) -> Void
    /// Called when an entry is removed; its file is trashed by the owner once the change is saved.
    var onRemoved: (MediaImage) -> Void

    var body: some View {
        Section("Drives") {
            ForEach(Array(game.media.enumerated()), id: \.element.relativePath) { index, image in
                HStack {
                    Image(systemName: image.kind == .cdrom ? "opticaldisc" : "externaldrive")
                    Text((image.relativePath as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Move Up", systemImage: "chevron.up") { game.media.swapAt(index, index - 1) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "chevron.down") { game.media.swapAt(index, index + 1) }
                        .disabled(index == game.media.count - 1)
                    Button("Remove", systemImage: "minus.circle") { remove(at: index) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Button("Add Disc or Floppy Image…", systemImage: "plus", action: add)
            TextField("C: root subfolder", text: $game.launch.driveCRoot, prompt: Text("(game folder)"))
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["iso", "img", "ima"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let media = record.crateURL.appending(path: "media", directoryHint: .isDirectory)
        Task {
            do {
                let name = try await Task.detached { try Self.copy(source, into: media) }.value
                let kind: MediaKind = source.pathExtension.lowercased() == "iso" ? .cdrom : .floppy
                game.media.append(MediaImage(relativePath: "media/" + name, kind: kind))
            } catch {
                onError("Can't add \(source.lastPathComponent)", error.localizedDescription)
            }
        }
    }

    /// Copies into `media`, choosing an unused name; returns the name used.
    private nonisolated static func copy(_ source: URL, into media: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var name = source.lastPathComponent
        var n = 2
        while fm.fileExists(atPath: media.appending(path: name).path) {
            name = source.deletingPathExtension().lastPathComponent + " \(n)." + source.pathExtension
            n += 1
        }
        try fm.copyItem(at: source, to: media.appending(path: name))
        return name
    }

    private func remove(at index: Int) {
        onRemoved(game.media.remove(at: index))
    }
}

struct StartupSection: View {
    let record: GameRecord
    @Binding var game: Game

    var body: some View {
        Section("Startup") {
            ExecutablePicker(record: record, game: game, executable: $game.launch.executable)
            TextField("Arguments", text: $game.launch.arguments)
            CommandsEditor(title: "Before the game", commands: $game.launch.preCommands)
            CommandsEditor(title: "After the game", commands: $game.launch.postCommands)
            Toggle("Quit DOSBox when game exits", isOn: $game.launch.exitWhenDone)
        }
    }
}

/// Lists the executables found on the C: drive, best guess first (the importer's ranking).
struct ExecutablePicker: View {
    let record: GameRecord
    let game: Game
    @Binding var executable: String?
    @State private var candidates: [String] = []

    private struct Key: Equatable { var root: String; var title: String }

    private var options: [String] {
        if let executable, !candidates.contains(executable) { return [executable] + candidates }
        return candidates
    }

    var body: some View {
        Picker("Program", selection: $executable) {
            Text("None").tag(String?.none)
            ForEach(options, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .task(id: Key(root: game.launch.driveCRoot, title: game.title)) {
            var r = record
            r.game = game
            guard let root = try? CrateIO().cDriveURL(for: r) else { candidates = []; return }
            let title = game.title
            candidates = await Task.detached {
                ((try? ExecutableRanker.rank(root: root, title: title)) ?? []).map(\.relativePath)
            }.value
        }
    }
}

/// One DOS command per line, stored as an array without blank lines.
struct CommandsEditor: View {
    let title: String
    @Binding var commands: [String]
    @State private var text: String

    init(title: String, commands: Binding<[String]>) {
        self.title = title
        self._commands = commands
        self._text = State(initialValue: commands.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        LabeledContent(title) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 54)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        }
        .onChange(of: text) { _, new in
            let lines = new.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines != commands { commands = lines }
        }
    }
}

struct SettingsTab: View {
    let record: GameRecord
    @Binding var game: Game
    var onError: (String, String) -> Void
    var onRemovedMedia: (MediaImage) -> Void

    var body: some View {
        Form {
            CuratedSettingsSections(settings: $game.settings)
            DrivesSection(record: record, game: $game, onError: onError, onRemoved: onRemovedMedia)
            StartupSection(record: record, game: $game)
        }
        .formStyle(.grouped)
    }
}
