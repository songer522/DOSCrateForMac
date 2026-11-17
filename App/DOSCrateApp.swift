import AppKit
import ImportKit
import LauncherKit
import LibraryKit
import Sparkle
import SwiftUI

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        prepareForTermination { shouldTerminate in
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    func prepareForTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.beginTermination()
        guard model.sessions.hasLiveProcesses || model.imports.hasActiveImports else { return .terminateNow }
        Task { @MainActor in
            await model.sessions.waitForAllProcessesToExit()
            await model.imports.waitForActiveImports()
            reply(true)
        }
        return .terminateLater
    }
}

enum RetroAlertContext: Equatable, Sendable {
    case mainWindow
    case importSheet
    case batchImportSheet
    case chooseProgramSheet
    case unmatchedMetadataSheet
    case findMetadataSheet
}

@MainActor
struct RetroAlertHostModifier: ViewModifier {
    @Bindable var model: AppModel
    let context: RetroAlertContext

    private var activeAlert: AppAlert? {
        guard DOSCrateApp.activeRetroAlertContext(for: model) == context else { return nil }
        return model.alert
    }

    func body(content: Content) -> some View {
        content
            .disabled(activeAlert != nil)
            .frame(minHeight: activeAlert != nil && context != .mainWindow ? 240 : nil)
            .overlay {
                if let alert = activeAlert {
                    RetroAlertModal(model: model, alert: alert)
                }
            }
    }
}

extension View {
    func retroAlertHost(model: AppModel, context: RetroAlertContext) -> some View {
        modifier(RetroAlertHostModifier(model: model, context: context))
    }
}

@main
struct DOSCrateApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let updaterController: SPUStandardUpdaterController
    /// False in Debug builds (where SUFeedURL / SUPublicEDKey are empty), which disables Sparkle.
    private let updatesEnabled: Bool

    static func isSparkleConfigured(info: [String: Any]?) -> Bool {
        let feedURL = (info?["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !feedURL.isEmpty && !publicKey.isEmpty
    }

    static func isShowingRetroAlert(theme: AppTheme, alert: AppAlert?) -> Bool {
        LibraryLayout(theme: theme) == .retro && alert != nil
    }

    @MainActor
    static func activeRetroAlertContext(for model: AppModel) -> RetroAlertContext? {
        guard isShowingRetroAlert(theme: model.prefs.appTheme, alert: model.alert) else {
            return nil
        }
        guard !model.needsLibrarySetup else {
            return .mainWindow
        }
        if model.imports.current != nil {
            return .importSheet
        }
        if model.imports.batchPrompt != nil {
            return .batchImportSheet
        }
        if model.chooseProgram != nil {
            return .chooseProgramSheet
        }
        if model.showingUnmatchedMetadata {
            return model.findMetadataFor != nil ? .findMetadataSheet : .unmatchedMetadataSheet
        }
        if model.findMetadataFor != nil {
            return .findMetadataSheet
        }
        return .mainWindow
    }

    init() {
        RetroFont.register()
        let enabled = Self.isSparkleConfigured(info: Bundle.main.infoDictionary)
        updatesEnabled = enabled
        updaterController = SPUStandardUpdaterController(
            startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)
        let prefs = Preferences()
        let store = LibraryStore(library: prefs.libraryURL)
        let appModel = AppModel(
            prefs: prefs, store: store, sessions: SessionManager(), importer: Importer(),
            dosbox: StagingLocator.dosboxURL())
        _model = State(initialValue: appModel)
        appDelegate.model = appModel
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.needsLibrarySetup {
                    FirstRunView(model: model)
                } else {
                    LibraryView(model: model)
                        .frame(minWidth: 700, minHeight: 450)
                }
            }
            .retroAlertHost(model: model, context: .mainWindow)
            .task {
                appDelegate.model = model
                guard !model.needsLibrarySetup else { return }
                await model.store.reload()
                model.store.startWatching()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.stopAllSessions()
            }
            .alert(
                item: Binding(
                    get: { LibraryLayout(theme: model.prefs.appTheme) == .standard ? model.alert : nil },
                    set: { model.alert = $0 }
                )
            ) { alert in
                if let fix = alert.fix, let id = alert.gameID {
                    Alert(title: Text(alert.title), message: Text(alert.message),
                          primaryButton: .default(Text(Self.label(fix))) { model.applyFix(fix, for: id) },
                          secondaryButton: .cancel())
                } else {
                    Alert(title: Text(alert.title), message: Text(alert.message))
                }
            }
        }
        .commands {
            AppCommands(model: model, updater: updaterController.updater, updatesEnabled: updatesEnabled)
        }

        Settings {
            PreferencesView(model: model, updater: updatesEnabled ? updaterController.updater : nil)
        }

        Window("What's New", id: AppCommands.whatsNewWindowID) {
            WhatsNewView(prefs: model.prefs)
        }

        Window("Licenses", id: AppCommands.licensesWindowID) {
            LicensesView(prefs: model.prefs)
        }
    }

    static func label(_ fix: AppAlert.Fix) -> String {
        switch fix {
        case .chooseExecutable, .chooseSetupExecutable: "Choose Executable…"
        case .locateFolder: "Locate Folder…"
        case .useFolderAsC: "Use Folder as C:"
        case .resetCRoot: "Use Whole Folder as C:"
        case .recreate: "Recreate…"
        case .reinstall: "OK"
        }
    }
}

struct RetroAlertModal: View {
    let model: AppModel
    let alert: AppAlert

    private func dismiss() {
        model.alert = nil
    }

    private func accept() {
        model.alert = nil
        if let fix = alert.fix, let id = alert.gameID {
            model.applyFix(fix, for: id)
        }
    }

    var body: some View {
        RetroModalContainer(
            title: alert.title,
            width: 420,
            onCancel: { dismiss() },
            onDefaultAction: { accept() }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                RetroScrollableMessage(text: alert.message)
                HStack(spacing: 8) {
                    Spacer()
                    if let fix = alert.fix, let id = alert.gameID {
                        Button("Cancel") {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        Button(DOSCrateApp.label(fix)) {
                            model.alert = nil
                            model.applyFix(fix, for: id)
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("OK") {
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(14)
        }
    }
}

struct AppCommands: Commands {
    static let whatsNewWindowID = "whats-new"
    static let licensesWindowID = "licenses"
    let model: AppModel
    let updater: SPUUpdater
    let updatesEnabled: Bool
    @AppStorage("libraryShowsGrid") private var showsGrid = true
    @AppStorage("libraryShowsInspector") private var showsInspector = true
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DOSCrate") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(string: LicensesView.notice),
                ])
            }
            Button("What's New…") { openWindow(id: Self.whatsNewWindowID) }
            Button("Licenses…") { openWindow(id: Self.licensesWindowID) }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updatesEnabled)
        }
        CommandGroup(after: .newItem) {
            Button("Import…") {
                Self.triggerImport(model)
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(!Self.canImport(model))
        }
        CommandGroup(after: .toolbar) {
            Button {
                showsGrid = true
            } label: {
                if showsGrid { Label("as Grid", systemImage: "checkmark") } else { Text("as Grid") }
            }
            .keyboardShortcut("1", modifiers: .command)
            Button {
                showsGrid = false
            } label: {
                if !showsGrid { Label("as List", systemImage: "checkmark") } else { Text("as List") }
            }
            .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button(Self.detailsButtonTitle(showsInspector: showsInspector)) {
                showsInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Menu("Sort By") {
                sortButton("Title", .title)
                sortButton("Year", .year)
                sortButton("Last Played", .lastPlayed)
                sortButton("Play Time", .playTime)
            }
        }
        CommandMenu("Game") {
            Button("Play") {
                if let id = model.selection { model.play(id) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!Self.canPlay(model))
            Button("Run Setup") {
                if let id = model.selection { model.runSetup(id) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!Self.canRunSetup(model))
            Button("Stop") {
                if let id = model.selection { model.stop(id) }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!Self.canStop(model))
            Divider()
            Button(Self.favoriteButtonTitle(for: model)) {
                Self.toggleFavorite(model)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!Self.canEdit(model))
            Button("Find Metadata…") {
                Self.findMetadata(model)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!Self.canEdit(model))
            Divider()
            Button("Show in Finder") {
                if let record = Self.selectedRecord(for: model) {
                    NSWorkspace.shared.activateFileViewerSelecting([record.crateURL])
                }
            }
            .disabled(!Self.canShowInFinder(model))
            Button("Show Game Files (C:) in Finder") {
                if let url = Self.selectedCDriveURL(for: model) {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(!Self.canShowCDriveInFinder(model))
        }
        CommandMenu("Library") {
            Button("Find Missing Metadata") {
                model.metadata.findMissingMetadata()
            }
            .disabled(model.store.records.isEmpty || model.metadata.isFindingMissing)
        }
    }

    private func sortButton(_ title: String, _ key: SortKey) -> some View {
        Button {
            model.query.sort = key
        } label: {
            if model.query.sort == key { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    @MainActor
    static func selectedRecord(for model: AppModel) -> GameRecord? {
        model.selection.flatMap(model.store.record)
    }

    @MainActor
    static func canImport(_ model: AppModel) -> Bool {
        !model.needsLibrarySetup
    }

    @MainActor
    static func triggerImport(_ model: AppModel) {
        guard canImport(model) else { return }
        model.isChoosingImport = true
    }

    static func detailsButtonTitle(showsInspector: Bool) -> String {
        showsInspector ? "Hide Details" : "Show Details"
    }

    @MainActor
    static func canPlay(_ model: AppModel) -> Bool {
        guard let record = selectedRecord(for: model) else { return false }
        let id = record.id
        return !model.sessions.running.contains(id)
            && !model.startingIDs.contains(id)
            && !model.imports.importingIDs.contains(id)
            && !model.imports.replacingIDs.contains(id)
            && !model.pendingRemovalIDs.contains(id)
    }

    @MainActor
    static func canRunSetup(_ model: AppModel) -> Bool {
        guard canPlay(model),
              let setup = selectedRecord(for: model)?.game.launch.setupExecutable,
              !setup.isEmpty else {
            return false
        }
        return true
    }

    @MainActor
    static func canStop(_ model: AppModel) -> Bool {
        guard let id = model.selection else { return false }
        return model.sessions.running.contains(id)
    }

    @MainActor
    static func canEdit(_ model: AppModel) -> Bool {
        guard let record = selectedRecord(for: model) else { return false }
        return BatchInspectorView.isWritable(record, in: model)
    }

    @MainActor
    static func favoriteButtonTitle(for model: AppModel) -> String {
        selectedRecord(for: model)?.game.isFavorite == true ? "Remove from Favorites" : "Add to Favorites"
    }

    @MainActor
    static func toggleFavorite(_ model: AppModel) {
        guard canEdit(model), let record = selectedRecord(for: model) else { return }
        var game = record.game
        game.isFavorite.toggle()
        do {
            try model.store.save(game)
        } catch {
            model.alert = AppAlert(title: "Can't save \(game.title)", message: error.localizedDescription)
        }
    }

    @MainActor
    static func findMetadata(_ model: AppModel) {
        guard canEdit(model), let id = model.selection else { return }
        model.findMetadataFor = id
    }

    @MainActor
    static func canShowInFinder(_ model: AppModel) -> Bool {
        selectedRecord(for: model) != nil
    }

    @MainActor
    static func selectedCDriveURL(for model: AppModel, io: CrateIO = CrateIO()) -> URL? {
        guard let record = selectedRecord(for: model) else { return nil }
        return GameContextMenu.cDriveFolderURL(for: record, io: io)
    }

    @MainActor
    static func canShowCDriveInFinder(_ model: AppModel, io: CrateIO = CrateIO()) -> Bool {
        selectedCDriveURL(for: model, io: io) != nil
    }
}
