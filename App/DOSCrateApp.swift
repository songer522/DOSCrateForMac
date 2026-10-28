import AppKit
import ImportKit
import LauncherKit
import LibraryKit
import Sparkle
import SwiftUI

@main
struct DOSCrateApp: App {
    @State private var model: AppModel
    private let updaterController: SPUStandardUpdaterController
    /// Empty in Debug builds, which disables Sparkle.
    private let appcastURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""

    init() {
        RetroFont.register()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: !appcastURL.isEmpty, updaterDelegate: nil, userDriverDelegate: nil)
        let prefs = Preferences()
        let store = LibraryStore(library: prefs.libraryURL)
        _model = State(initialValue: AppModel(
            prefs: prefs, store: store, sessions: SessionManager(), importer: Importer(),
            dosbox: StagingLocator.dosboxURL()))
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
                guard !model.needsLibrarySetup else { return }
                await model.store.reload()
                model.store.startWatching()
            }
            .alert(item: $model.alert) { alert in
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
            AppCommands(model: model, updater: updaterController.updater, updatesEnabled: !appcastURL.isEmpty)
        }

        Settings {
            PreferencesView(model: model, updater: appcastURL.isEmpty ? nil : updaterController.updater)
        }

        Window("Licenses", id: AppCommands.licensesWindowID) {
            LicensesView()
        }
    }

    private static func label(_ fix: AppAlert.Fix) -> String {
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
            if updatesEnabled {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
        }
        CommandMenu("Library") {
            Button("Find Missing Metadata") {
                model.metadata.findMissingMetadata()
            }
            .disabled(model.store.records.isEmpty || model.metadata.isFindingMissing)
        }
    }
}
