import AppKit
import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// The inspector for one game. Edits go to a draft that is saved 500 ms after the last change.
/// Create it with `.id(record.id)` so the draft resets when the selection changes.
struct GameDetailView: View {
    static let headerCoverWidth: CGFloat = 140

    enum Tab: String, CaseIterable, Identifiable {
        case info = "Info", settings = "Settings", advanced = "Advanced"
        var id: Self { self }
    }

    let model: AppModel
    let record: GameRecord

    @State private var draft: Game
    @State private var saveTask: Task<Void, Never>?
    /// Media files whose entries were removed; trashed only once the removal is saved.
    @State private var removedMedia: [String] = []
    @State private var tab: Tab
    @Environment(\.retroTheme) private var retroTheme

    init(model: AppModel, record: GameRecord, initialTab: Tab = .info) {
        self.model = model
        self.record = record
        self._draft = State(initialValue: record.game)
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            GameHeader(model: model, record: record, isReadOnly: isReadOnly, onPlay: play)
                .padding()
            if case .readOnly(let reason) = record.status {
                Text(reason)
                    .font(retroTheme ? RetroFont.font() : .callout)
                    .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 8)
            }
            ThemedSegmented("Section", showsTitle: false, selection: $tab, options: Tab.allCases, label: \.rawValue)
                .padding(.horizontal)
                .padding(.bottom, retroTheme ? 8 : 0)
            Group {
                switch tab {
                case .info: InfoTab(game: $draft) { model.findMetadataFor = record.id }
                case .settings:
                    SettingsTab(
                        record: record,
                        game: $draft,
                        onAddMedia: addMedia,
                        onRemovedMedia: { removedMedia.append($0.relativePath) }
                    )
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
        if model.imports.replacingIDs.contains(record.id) || model.imports.importingIDs.contains(record.id) {
            return true
        }
        return false
    }

    /// `model.play` runs the registered draft save first, so the launch uses what the inspector shows.
    private func play() {
        model.play(record.id)
    }

    private func showError(_ title: String, _ message: String) {
        model.alert = AppAlert(title: title, message: message)
    }

    private func addMedia(_ source: URL) {
        let targetID = record.id
        Task {
            guard let image = await model.addMedia(from: source, to: targetID) else { return }
            if draft.id == targetID {
                if !draft.media.contains(image) {
                    draft.media.append(image)
                }
                FolderMount.reassignConflictsWithCDROM(
                    &draft.launch.folderMounts,
                    hasCDROM: draft.media.contains { $0.kind == .cdrom }
                )
            }
        }
    }

    private func scheduleSave() {
        saveTask = Self.scheduleDraftSave(
            draft: draft,
            removedMedia: removedMedia,
            in: model,
            previousTask: saveTask,
            flushAction: { flush() }
        )
    }

    @discardableResult
    static func scheduleDraftSave(
        draft: Game,
        removedMedia: [String] = [],
        in model: AppModel,
        previousTask: Task<Void, Never>? = nil,
        flushAction: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard let current = model.store.record(draft.id)?.game,
              merged(draft, into: current) != current || !removedMedia.isEmpty else { return nil }
        previousTask?.cancel()
        let doFlush: @MainActor () -> Void = flushAction ?? {
            model.setPendingWrite(draft.id, owner: "draft", nil)
            guard let latestRecord = model.store.record(draft.id) else { return }
            let latest = latestRecord.game
            let game = merged(draft, into: latest)
            if game != latest {
                do {
                    try model.store.save(game)
                } catch {
                    model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
                    return
                }
            }
            if !removedMedia.isEmpty {
                trashRemovedMedia(removedMedia, keeping: game.media, in: latestRecord.crateURL) { title, message in
                    model.alert = AppAlert(title: title, message: message)
                }
            }
        }
        let task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            doFlush()
        }
        // A launch from the grid, list or context menu may come before the debounce fires.
        model.setPendingWrite(draft.id, owner: "draft") {
            task.cancel()
            doFlush()
        }
        return task
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
        Self.trashRemovedMedia(paths, keeping: media, in: record.crateURL) { title, message in
            showError(title, message)
        }
    }

    static func trashRemovedMedia(
        _ removedPaths: [String],
        keeping media: [MediaImage],
        in crateURL: URL,
        onError: (String, String) -> Void = { _, _ in }
    ) {
        let fm = FileManager.default
        let mediaDir = crateURL.appending(path: "media", directoryHint: .isDirectory)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let mediaPrefix = mediaDir.hasSuffix("/") ? mediaDir : mediaDir + "/"

        func isContainedRegularFile(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return false
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard let resolvedValues = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  resolvedValues.isRegularFile == true,
                  resolvedValues.isSymbolicLink != true else {
                return false
            }
            return resolved.path.hasPrefix(mediaPrefix)
        }

        var keptKeys: Set<String> = []
        var keptResourceIDs: Set<NSObject> = []
        func recordKept(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            keptKeys.insert(resolved.path.lowercased())
            if let id = (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject {
                keptResourceIDs.insert(id)
            }
        }
        for item in media {
            let itemURL = crateURL.appending(path: item.relativePath)
            recordKept(itemURL)
            if (item.relativePath as NSString).pathExtension.lowercased() == "cue",
               isContainedRegularFile(itemURL),
               let sheet = try? CueSheet(itemURL) {
                for trackURL in sheet.files where isContainedRegularFile(trackURL) {
                    recordKept(trackURL)
                }
            }
        }

        func isKept(_ url: URL) -> Bool {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            if keptKeys.contains(resolved.path.lowercased()) {
                return true
            }
            if let id = (try? resolved.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier) as? NSObject,
               keptResourceIDs.contains(id) {
                return true
            }
            return false
        }

        var trashedTrackKeys: Set<String> = []
        for path in removedPaths where !media.contains(where: { $0.relativePath == path }) {
            let fileURL = crateURL.appending(path: path)
            let companionTracks: [URL]
            if (path as NSString).pathExtension.lowercased() == "cue",
               isContainedRegularFile(fileURL),
               let sheet = try? CueSheet(fileURL) {
                companionTracks = sheet.files.filter(isContainedRegularFile)
            } else {
                companionTracks = []
            }

            do {
                try fm.trashItem(at: fileURL, resultingItemURL: nil)
            } catch {
                onError("Can't move \((path as NSString).lastPathComponent) to the Trash", error.localizedDescription)
            }

            for trackURL in companionTracks {
                let resolvedTrack = trackURL.resolvingSymlinksInPath().standardizedFileURL
                let key = resolvedTrack.path.lowercased()
                guard isContainedRegularFile(trackURL),
                      !isKept(trackURL),
                      trashedTrackKeys.insert(key).inserted else { continue }
                do {
                    try fm.trashItem(at: resolvedTrack, resultingItemURL: nil)
                } catch {
                    onError("Can't move \(trackURL.lastPathComponent) to the Trash", error.localizedDescription)
                }
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
        game.description = draft.description
        game.notes = draft.notes
        game.tags = draft.tags
        game.media = draft.media
        game.launch = draft.launch
        game.settings = draft.settings
        return game
    }

    @discardableResult
    static func setCover(from urls: [URL], for record: GameRecord, in model: AppModel) -> Bool {
        guard let image = urls.lazy.compactMap({ NSImage(contentsOf: $0) }).first else { return false }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            model.alert = AppAlert(title: "Can't use that image", message: "The image couldn't be converted to PNG.")
            return false
        }
        do {
            try png.write(to: CrateIO().coverURL(record.crateURL), options: .atomic)
            model.metadata.artRevision[record.id, default: 0] += 1
            return true
        } catch {
            model.alert = AppAlert(title: "Can't save the cover", message: error.localizedDescription)
            return false
        }
    }

    @discardableResult
    static func removeCover(for record: GameRecord, in model: AppModel) -> Bool {
        let coverURL = CrateIO().coverURL(record.crateURL)
        guard FileManager.default.fileExists(atPath: coverURL.path) else { return false }
        do {
            try FileManager.default.trashItem(at: coverURL, resultingItemURL: nil)
            model.metadata.artRevision[record.id, default: 0] += 1
            return true
        } catch {
            model.alert = AppAlert(title: "Can't remove the cover", message: error.localizedDescription)
            return false
        }
    }
}

private struct GameHeader: View {
    let model: AppModel
    let record: GameRecord
    var isReadOnly = false
    let onPlay: () -> Void
    @State private var coverRevision = 0
    @State private var dropTargeted = false
    @Environment(\.retroTheme) private var retroTheme

    private var running: Bool { model.sessions.running.contains(record.id) }
    private var starting: Bool { model.startingIDs.contains(record.id) }
    private var importing: Bool { model.imports.importingIDs.contains(record.id) }
    private var hasCover: Bool {
        _ = coverRevision
        _ = model.metadata.artRevision[record.id, default: 0]
        return FileManager.default.fileExists(atPath: CrateIO().coverURL(record.crateURL).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                coverBox
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.game.title)
                        .font(retroTheme ? RetroFont.font() : .title2.bold())
                        .foregroundStyle(retroTheme ? RetroPalette.shadow : .primary)
                        .lineLimit(2)
                    Text(playTime)
                        .font(retroTheme ? RetroFont.font() : .callout)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                    Text(lastPlayed)
                        .font(retroTheme ? RetroFont.font() : .callout)
                        .foregroundStyle(retroTheme ? RetroPalette.secondaryText : .secondary)
                    actionButton
                }
                Spacer(minLength: 0)
            }
            ArtStripView(
                crateURL: record.crateURL,
                isLoadingArt: model.metadata.artLoading.contains(record.id),
                artRevision: model.metadata.artRevision[record.id, default: 0],
                isReadOnly: isReadOnly,
                onArtChanged: { model.metadata.artRevision[record.id, default: 0] += 1 },
                onError: { title, message in model.alert = AppAlert(title: title, message: message) }
            )
            if let result = model.lastResult[record.id], result.unexpected {
                unexpectedExitBanner(logURL: result.logURL)
            }
        }
    }

    @ViewBuilder private var coverBox: some View {
        let base = CoverView(
            record: record,
            isRunning: !retroTheme && running,
            isStarting: !retroTheme && starting,
            isImporting: !retroTheme && importing,
            isLoadingArt: model.metadata.artLoading.contains(record.id) || (retroTheme && importing),
            artRevision: model.metadata.artRevision[record.id, default: 0]
        )
            .id(coverRevision)
            .frame(width: GameDetailView.headerCoverWidth)
            .onTapGesture {
                let coverURL = CrateIO().coverURL(record.crateURL)
                if FileManager.default.fileExists(atPath: coverURL.path) {
                    ArtQuickLookController.shared.present(urls: [coverURL], startingAt: 0)
                }
            }
            .contextMenu {
                if !isReadOnly {
                    Button("Choose Cover Image…", action: chooseCoverImage)
                    if hasCover {
                        Button("Remove Cover Image", role: .destructive, action: removeCoverImage)
                    }
                }
            }
        if retroTheme {
            base
                .retroBevel(.sunken)
                .overlay {
                    if dropTargeted && !isReadOnly {
                        Rectangle()
                            .strokeBorder(RetroPalette.highlight, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in setCover(from: urls) } isTargeted: { dropTargeted = $0 }
        } else {
            base
                .overlay {
                    if dropTargeted && !isReadOnly {
                        RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in setCover(from: urls) } isTargeted: { dropTargeted = $0 }
        }
    }

    @ViewBuilder private var actionButton: some View {
        if retroTheme {
            if running {
                Button { model.stop(record.id) } label: {
                    HStack(spacing: 6) {
                        PixelSymbol("stop.fill", color: RetroPalette.red, pointSize: 16, scale: 1)
                        Text("Stop")
                    }
                }
                .buttonStyle(RetroButtonStyle())
            } else if starting {
                Button("Starting…", action: onPlay)
                    .buttonStyle(RetroButtonStyle())
                    .disabled(true)
            } else if importing {
                Button(action: onPlay) {
                    HStack(spacing: 6) {
                        RetroSpinner()
                        Text("Importing…")
                    }
                }
                .buttonStyle(RetroButtonStyle())
                .disabled(true)
            } else {
                let disabled = model.pendingRemovalIDs.contains(record.id) || model.imports.replacingIDs.contains(record.id)
                Button(action: onPlay) {
                    HStack(spacing: 6) {
                        PixelSymbol("play.fill", color: disabled ? RetroPalette.bevelDark : RetroPalette.green, pointSize: 16, scale: 1)
                        Text("Play")
                    }
                }
                .buttonStyle(RetroButtonStyle())
                .disabled(disabled)
            }
        } else if running {
            Button("Stop", systemImage: "stop.fill") { model.stop(record.id) }
        } else if starting {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        } else if importing {
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        } else {
            Button("Play", systemImage: "play.fill", action: onPlay)
                .buttonStyle(.borderedProminent)
                .disabled(model.pendingRemovalIDs.contains(record.id) || model.imports.replacingIDs.contains(record.id))
        }
    }

    @ViewBuilder private func unexpectedExitBanner(logURL: URL) -> some View {
        if retroTheme {
            HStack {
                PixelSymbol("exclamationmark.triangle.fill", color: RetroPalette.red, pointSize: 16, scale: 1)
                Text("Exited unexpectedly")
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.shadow)
                Spacer()
                Button("View Log") { openLog(logURL) }
                    .buttonStyle(RetroButtonStyle())
            }
            .padding(8)
            .background(RetroPalette.yellow)
            .retroBevel(.sunken)
        } else {
            HStack {
                Label("Exited unexpectedly", systemImage: "exclamationmark.triangle.fill")
                Spacer()
                Button("View Log") { openLog(logURL) }
            }
            .padding(8)
            .background(.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
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
        AdvancedTab.openLog(url)
    }

    private func chooseCoverImage() {
        guard !isReadOnly else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = setCover(from: [url])
    }

    private func removeCoverImage() {
        guard !isReadOnly else { return }
        if GameDetailView.removeCover(for: record, in: model) {
            coverRevision += 1
        }
    }

    private func setCover(from urls: [URL]) -> Bool {
        guard !isReadOnly else { return false }
        guard GameDetailView.setCover(from: urls, for: record, in: model) else { return false }
        coverRevision += 1
        return true
    }
}
