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
        ThemedPicker(title, selection: $selection, options: options, label: label)
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
        ControllerSection(settings: $settings)
    }
}

struct PresetSection: View {
    @Binding var settings: GameSettings
    var body: some View {
        ThemedSection("Preset") {
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
        ThemedSection("CPU") {
            ThemedSegmented("Cycles", selection: mode, options: CyclesMode.allCases, label: \.rawValue)
            if CyclesMode(settings.cycles) == .fixed {
                ThemedNumberField(title: "Fixed cycles", value: fixedValue)
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
        ThemedSection("Memory") {
            OptionalPicker("Memory size", selection: $settings.memoryMB, options: Self.sizes) { "\($0) MB" }
        }
    }
}

struct GraphicsSection: View {
    static let shaders = ["crt-auto", "crt-auto-machine", "crt-auto-arcade", "sharp", "bilinear", "nearest"]
    @Binding var settings: GameSettings
    var body: some View {
        ThemedSection("Graphics") {
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
        ThemedSection("Sound") {
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
        ThemedSection("Input") {
            OptionalPicker("Mouse capture", selection: $settings.mouseCapture, options: MouseCapture.allCases, label: \.displayName)
            ThemedTextField(title: "Keyboard layout", text: layout, prompt: "auto")
        }
    }
}

struct ControllerSection: View {
    @Binding var settings: GameSettings

    static func binding(for button: ControllerButton, in settings: Binding<GameSettings>) -> Binding<ControllerKey?> {
        Binding(
            get: { settings.wrappedValue.controllerBindings?[button] },
            set: { newValue in
                var current = settings.wrappedValue.controllerBindings ?? ControllerBindings()
                current[button] = newValue
                settings.wrappedValue.controllerBindings = current.nonEmpty
            }
        )
    }

    var body: some View {
        ThemedSection("Controller") {
            OptionalPicker("Controller mode", selection: $settings.controllerMode, options: ControllerMode.allCases, label: \.displayName)
            if settings.controllerMode != .disabled {
                ForEach(ControllerButton.allCases, id: \.self) { button in
                    ThemedPicker(
                        button.displayName,
                        selection: Self.binding(for: button, in: $settings),
                        nilLabel: button.defaultLabel(for: settings.controllerMode),
                        options: ControllerKey.allCases,
                        label: \.displayName
                    )
                }
            }
        }
    }
}

// MARK: Per-game groups

struct DrivesSection: View {
    let record: GameRecord
    @Binding var game: Game
    var onAddMedia: (URL) -> Void
    /// Called when an entry is removed; its file is trashed by the owner once the change is saved.
    var onRemoved: (MediaImage) -> Void
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        ThemedSection("Drives") {
            ForEach(Array(game.media.enumerated()), id: \.element.relativePath) { index, image in
                if retroTheme {
                    HStack(spacing: 6) {
                        PixelSymbol(image.kind == .cdrom ? "opticaldisc" : "externaldrive",
                                    color: RetroPalette.desktop,
                                    pointSize: 16,
                                    scale: 1)
                        Text((image.relativePath as NSString).lastPathComponent)
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("▲") { game.media.swapAt(index, index - 1) }
                            .buttonStyle(RetroButtonStyle())
                            .disabled(index == 0)
                        Button("▼") { game.media.swapAt(index, index + 1) }
                            .buttonStyle(RetroButtonStyle())
                            .disabled(index == game.media.count - 1)
                        Button("−") { remove(at: index) }
                            .buttonStyle(RetroButtonStyle())
                    }
                } else {
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
            }
            if retroTheme {
                Button(action: add) {
                    HStack(spacing: 6) {
                        PixelSymbol("plus", color: RetroPalette.green, pointSize: 16, scale: 1)
                        Text("Add Disc or Floppy Image…")
                    }
                }
                .buttonStyle(RetroButtonStyle())
            } else {
                Button("Add Disc or Floppy Image…", systemImage: "plus", action: add)
            }
            ForEach(Array(game.launch.folderMounts.enumerated()), id: \.offset) { index, mount in
                if retroTheme {
                    HStack(spacing: 6) {
                        PixelSymbol("folder", color: RetroPalette.desktop, pointSize: 16, scale: 1)
                        Menu {
                            ForEach(Self.availableDriveLetters(for: index, in: game), id: \.self) { letter in
                                Button {
                                    game.launch.folderMounts[index].driveLetter = letter
                                } label: {
                                    if mount.driveLetter.uppercased() == letter {
                                        Label("\(letter):", systemImage: "checkmark")
                                    } else {
                                        Text("\(letter):")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 0) {
                                Text("\(mount.driveLetter.uppercased()):")
                                    .font(RetroFont.font())
                                    .foregroundStyle(RetroPalette.shadow)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(RetroPalette.bevelLight)
                                    .retroBevel(.sunken)
                                Text("▼")
                                    .font(RetroFont.font())
                                    .foregroundStyle(RetroPalette.shadow)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 3)
                                    .background(RetroPalette.panel)
                                    .retroBevel(.raised)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Text((mount.path as NSString).lastPathComponent)
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(mount.path)
                        Spacer()
                        Button("−") { removeFolderMount(at: index) }
                            .buttonStyle(RetroButtonStyle())
                    }
                } else {
                    HStack {
                        Image(systemName: "folder")
                        Picker("Drive", selection: driveLetterBinding(for: index)) {
                            ForEach(Self.availableDriveLetters(for: index, in: game), id: \.self) { letter in
                                Text("\(letter):").tag(letter)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text((mount.path as NSString).lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(mount.path)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { removeFolderMount(at: index) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
            }
            if retroTheme {
                Button(action: addFolderMount) {
                    HStack(spacing: 6) {
                        PixelSymbol("plus", color: RetroPalette.green, pointSize: 16, scale: 1)
                        Text("Add Folder Mount…")
                    }
                }
                .buttonStyle(RetroButtonStyle())
                .disabled(!Self.canAddFolderMount(to: game))
            } else {
                Button("Add Folder Mount…", systemImage: "folder.badge.plus", action: addFolderMount)
                    .disabled(!Self.canAddFolderMount(to: game))
            }
            ThemedTextField(title: "C: root subfolder", text: $game.launch.driveCRoot, prompt: "(game folder)")
        }
    }

    static func canAddFolderMount(to game: Game) -> Bool {
        FolderMount.nextAvailableDriveLetter(
            existing: game.launch.folderMounts,
            hasCDROM: game.media.contains { $0.kind == .cdrom }
        ) != nil
    }

    static func availableDriveLetters(for index: Int, in game: Game) -> [String] {
        let hasCDROM = game.media.contains { $0.kind == .cdrom }
        guard game.launch.folderMounts.indices.contains(index) else {
            return hasCDROM ? Array(FolderMount.availableDriveLetters.dropFirst()) : FolderMount.availableDriveLetters
        }
        let current = game.launch.folderMounts[index].driveLetter.uppercased()
        let otherUsed = Set(
            game.launch.folderMounts.enumerated()
                .filter { $0.offset != index }
                .map { $0.element.driveLetter.uppercased() }
        )
        return FolderMount.availableDriveLetters.filter { letter in
            if hasCDROM && letter == "D" { return false }
            return letter == current || !otherUsed.contains(letter)
        }
    }

    @discardableResult
    static func appendFolderMount(url: URL, to game: inout Game) -> FolderMount? {
        let hasCDROM = game.media.contains { $0.kind == .cdrom }
        guard let letter = FolderMount.nextAvailableDriveLetter(existing: game.launch.folderMounts, hasCDROM: hasCDROM) else {
            return nil
        }
        let bookmark = (try? CrateIO.makeBookmark(for: url)) ?? Data()
        let mount = FolderMount(driveLetter: letter, path: url.path, bookmark: bookmark)
        game.launch.folderMounts.append(mount)
        return mount
    }

    private func driveLetterBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard game.launch.folderMounts.indices.contains(index) else { return "D" }
                let current = game.launch.folderMounts[index].driveLetter.uppercased()
                let available = Self.availableDriveLetters(for: index, in: game)
                return available.contains(current) ? current : (available.first ?? current)
            },
            set: { newValue in
                guard game.launch.folderMounts.indices.contains(index) else { return }
                game.launch.folderMounts[index].driveLetter = newValue.uppercased()
            }
        )
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["iso", "img", "ima"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        onAddMedia(source)
    }

    private func addFolderMount() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Mount"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Self.appendFolderMount(url: folder, to: &game)
    }

    private func remove(at index: Int) {
        onRemoved(game.media.remove(at: index))
    }

    private func removeFolderMount(at index: Int) {
        guard game.launch.folderMounts.indices.contains(index) else { return }
        game.launch.folderMounts.remove(at: index)
    }
}

struct StartupSection: View {
    let record: GameRecord
    @Binding var game: Game

    var body: some View {
        ThemedSection("Startup") {
            ExecutablePicker(record: record, game: game, executable: $game.launch.executable)
            ExecutablePicker(title: "Setup program", record: record, game: game, executable: $game.launch.setupExecutable)
            ThemedTextField(title: "Arguments", text: $game.launch.arguments)
            CommandsEditor(title: "Before the game", commands: $game.launch.preCommands)
            CommandsEditor(title: "After the game", commands: $game.launch.postCommands)
            Toggle("Quit DOSBox when game exits", isOn: $game.launch.exitWhenDone)
        }
    }
}

/// Lists the executables found on the C: drive, best guess first (the importer's ranking).
struct ExecutablePicker: View {
    var title = "Program"
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
        ThemedPicker(
            title,
            selection: $executable,
            nilLabel: "None",
            showsDividerAfterNil: false,
            options: options,
            label: { $0 }
        )
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
    @Environment(\.retroTheme) private var retroTheme

    init(title: String, commands: Binding<[String]>) {
        self.title = title
        self._commands = commands
        self._text = State(initialValue: commands.wrappedValue.joined(separator: "\n"))
    }

    var body: some View {
        ThemedLabeledRow(title) {
            if retroTheme {
                TextEditor(text: $text)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.shadow)
                    .frame(minHeight: 54)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RetroPalette.bevelLight)
                    .retroBevel(.sunken)
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 54)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
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
    var onAddMedia: (URL) -> Void
    var onRemovedMedia: (MediaImage) -> Void

    var body: some View {
        ThemedForm {
            CuratedSettingsSections(settings: $game.settings)
            DrivesSection(record: record, game: $game, onAddMedia: onAddMedia, onRemoved: onRemovedMedia)
            StartupSection(record: record, game: $game)
        }
    }
}
