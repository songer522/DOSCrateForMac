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
        case .chooseExecutable: "Choose Executable…"
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
        CommandMenu("Library") {
            Button("Find Missing Metadata") {
                model.metadata.findMissingMetadata()
            }
            .disabled(model.store.records.isEmpty || model.metadata.isFindingMissing)
        }
    }
}
