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
        guard model.sessions.hasLiveProcesses else { return .terminateNow }
        Task { @MainActor in
            await model.sessions.waitForAllProcessesToExit()
            reply(true)
        }
        return .terminateLater
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
            .task {
                appDelegate.model = model
                guard !model.needsLibrarySetup else { return }
                await model.store.reload()
                model.store.startWatching()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.stopAllSessions()
            }
            .overlay {
                if LibraryLayout(theme: model.prefs.appTheme) == .retro, let alert = model.alert {
                    RetroAlertModal(model: model, alert: alert)
                }
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

    var body: some View {
        ZStack {
            RetroPalette.shadow.opacity(0.45)
                .ignoresSafeArea()
            RetroPanel(title: alert.title) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(alert.message)
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer()
                        if let fix = alert.fix, let id = alert.gameID {
                            Button("Cancel") {
                                model.alert = nil
                            }
                            .keyboardShortcut(.cancelAction)
                            Button(DOSCrateApp.label(fix)) {
                                model.alert = nil
                                model.applyFix(fix, for: id)
                            }
                            .keyboardShortcut(.defaultAction)
                        } else {
                            Button("OK") {
                                model.alert = nil
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .padding(14)
            }
            .retroControls()
            .frame(width: 420)
        }
    }
}

struct AppCommands: Commands {
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
