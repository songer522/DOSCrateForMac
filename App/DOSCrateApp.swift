import ImportKit
import LauncherKit
import LibraryKit
import SwiftUI

@main
struct DOSCrateApp: App {
    @State private var model: AppModel

    init() {
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
                    // Replaced by LibraryView in Task 11.
                    Text("DOSCrate")
                        .frame(minWidth: 400, minHeight: 300)
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
    }

    private static func label(_ fix: AppAlert.Fix) -> String {
        switch fix {
        case .chooseExecutable: "Choose Executable…"
        case .locateFolder: "Locate Folder…"
        case .useFolderAsC: "Use Folder as C:"
        case .reinstall: "OK"
        }
    }
}
