import AppKit
import SwiftUI

struct FirstRunView: View {
    let model: AppModel
    @Environment(\.retroTheme) private var retroTheme

    private var isRetro: Bool {
        retroTheme || LibraryLayout(theme: model.prefs.appTheme) == .retro
    }

    var body: some View {
        Group {
            if isRetro {
                ZStack {
                    RetroPalette.desktop.ignoresSafeArea()
                    RetroPanel(title: "Welcome to DOSCrate") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Choose where your game library lives, or create a new one.")
                                .font(RetroFont.font())
                                .foregroundStyle(RetroPalette.shadow)
                            HStack(spacing: 8) {
                                Button("Choose Existing Folder…") { choose() }
                                Button("Create Library in Documents") {
                                    model.chooseLibrary(Preferences.defaultLibraryURL, create: true)
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(16)
                    }
                    .retroControls()
                    .fixedSize()
                }
            } else {
                VStack(spacing: 16) {
                    Text("Welcome to DOSCrate").font(.largeTitle)
                    Text("Choose where your game library lives, or create a new one.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Existing Folder…") { choose() }
                        Button("Create Library in Documents") {
                            model.chooseLibrary(Preferences.defaultLibraryURL, create: true)
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(40)
            }
        }
        .frame(minWidth: 480, minHeight: 240)
    }

    private func choose() {
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
