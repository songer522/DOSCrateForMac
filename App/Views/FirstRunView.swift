import AppKit
import SwiftUI

struct FirstRunView: View {
    let model: AppModel

    var body: some View {
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
