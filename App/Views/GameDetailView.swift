import AppKit
import LauncherKit
import LibraryKit
import SwiftUI

/// The inspector for one game. Edits go to a draft that is saved 500 ms after the last change.
/// Create it with `.id(record.id)` so the draft resets when the selection changes.
struct GameDetailView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", settings = "Settings", advanced = "Advanced"
        var id: Self { self }
    }

    let model: AppModel
    let record: GameRecord

    @State private var draft: Game
    @State private var saveTask: Task<Void, Never>?
    /// Media files whose entries were removed; trashed only once the removal is saved.
    @State private var removedMedia: [String] = []
    @State private var tab = Tab.info

    init(model: AppModel, record: GameRecord) {
        self.model = model
        self.record = record
        self._draft = State(initialValue: record.game)
    }

    var body: some View {
        VStack(spacing: 0) {
            GameHeader(model: model, record: record, onPlay: play)
                .padding()
            if case .readOnly(let reason) = record.status {
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            Group {
                switch tab {
                case .info: InfoTab(game: $draft)
                case .settings: SettingsTab(record: record, game: $draft, onError: showError) { removedMedia.append($0.relativePath) }
                case .advanced: AdvancedTab(model: model, record: record, game: draft)
                }
            }
            .disabled(isReadOnly)
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: record.game) { _, new in
            // Pick up changes made elsewhere (fixes, play stats) unless an edit is waiting to be saved.
            if saveTask == nil, Self.shouldAdopt(stored: new, over: draft) { draft = new }
        }
        .onDisappear { if saveTask != nil { flush() } }
    }

    private var isReadOnly: Bool {
        if case .readOnly = record.status { return true }
        return false
    }

    /// `model.play` runs the registered draft save first, so the launch uses what the inspector shows.
    private func play() {
        model.play(record.id)
    }

    private func showError(_ title: String, _ message: String) {
        model.alert = AppAlert(title: title, message: message)
    }

    private func scheduleSave() {
        guard let current = model.store.record(draft.id)?.game,
              Self.merged(draft, into: current) != current || !removedMedia.isEmpty else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            flush()
        }
        // A launch from the grid, list or context menu may come before the debounce fires.
        model.setPendingWrite(draft.id, owner: "draft") {
            saveTask?.cancel()
            flush()
        }
    }

    private func flush() {
        saveTask = nil
        model.setPendingWrite(draft.id, owner: "draft", nil)
        guard let current = model.store.record(draft.id)?.game else { return }
        let game = Self.merged(draft, into: current)
        if game != current {
            do {
                try model.store.save(game)
            } catch {
                showError("Can't save \(game.title)", error.localizedDescription)
                return
            }
        }
        trashRemovedMedia(keeping: game.media)
    }

    private func trashRemovedMedia(keeping media: [MediaImage]) {
        let paths = removedMedia
        removedMedia = []
        for path in paths where !media.contains(where: { $0.relativePath == path }) {
            do {
                try FileManager.default.trashItem(at: record.crateURL.appending(path: path), resultingItemURL: nil)
            } catch {
                showError("Can't move \((path as NSString).lastPathComponent) to the Trash", error.localizedDescription)
            }
        }
    }

    /// Whether a stored game that differs from the draft should replace it. Differences the save itself
    /// causes (a trimmed title) must not, or they would undo what the user is typing.
    static func shouldAdopt(stored: Game, over draft: Game) -> Bool {
        draft != stored && merged(draft, into: stored) != stored
    }

    /// The editable fields of `draft` laid over the stored game, so play stats, favorite and source are never overwritten.
    static func merged(_ draft: Game, into base: Game) -> Game {
        var game = base
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { game.title = title }
        game.year = draft.year
        game.developer = draft.developer
        game.publisher = draft.publisher
        game.genre = draft.genre
        game.notes = draft.notes
        game.tags = draft.tags
        game.media = draft.media
        game.launch = draft.launch
        game.settings = draft.settings
        return game
    }
}

private struct GameHeader: View {
    let model: AppModel
    let record: GameRecord
    let onPlay: () -> Void
    @State private var coverRevision = 0
    @State private var dropTargeted = false

    private var running: Bool { model.sessions.running.contains(record.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CoverView(record: record, isRunning: running)
                    .id(coverRevision)
                    .frame(width: 90)
                    .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3) } }
                    .dropDestination(for: URL.self) { urls, _ in setCover(from: urls) } isTargeted: { dropTargeted = $0 }
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.game.title).font(.title2.bold()).lineLimit(2)
                    Text(playTime).font(.callout).foregroundStyle(.secondary)
                    Text(lastPlayed).font(.callout).foregroundStyle(.secondary)
                    if running {
                        Button("Stop", systemImage: "stop.fill") { model.stop(record.id) }
                    } else {
                        Button("Play", systemImage: "play.fill", action: onPlay)
                            .buttonStyle(.borderedProminent)
                    }
                }
                Spacer(minLength: 0)
            }
            if let result = model.lastResult[record.id], result.unexpected {
                HStack {
                    Label("Exited unexpectedly", systemImage: "exclamationmark.triangle.fill")
                    Spacer()
                    Button("View Log") { openLog(result.logURL) }
                }
                .padding(8)
                .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var playTime: String {
        let seconds = record.game.stats.totalPlaySeconds
        guard seconds >= 60 else { return record.game.stats.launchCount == 0 ? "Never played" : "Under a minute played" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " played"
    }

    private var lastPlayed: String {
        guard let date = record.game.stats.lastPlayed else { return "Not played yet" }
        return "Last played " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private func openLog(_ url: URL) {
        let workspace = NSWorkspace.shared
        guard let console = workspace.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            workspace.open(url)
            return
        }
        workspace.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private func setCover(from urls: [URL]) -> Bool {
        guard let image = urls.lazy.compactMap({ NSImage(contentsOf: $0) }).first else { return false }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            model.alert = AppAlert(title: "Can't use that image", message: "The image couldn't be converted to PNG.")
            return false
        }
        do {
            try png.write(to: CrateIO().coverURL(record.crateURL), options: .atomic)
            coverRevision += 1
            return true
        } catch {
            model.alert = AppAlert(title: "Can't save the cover", message: error.localizedDescription)
            return false
        }
    }
}
