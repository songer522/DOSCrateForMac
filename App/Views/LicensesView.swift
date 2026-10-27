import SwiftUI

/// A license text shipped in the app's `Resources/Licenses` folder.
struct LicenseFile: Identifiable, Hashable {
    let url: URL
    /// Path relative to the Licenses folder, e.g. "DOSBox-Staging/licenses/GPL-2.0.txt".
    let name: String
    var id: URL { url }

    /// Every regular file under `root`, recursively, sorted by name.
    static func all(in root: URL) -> [LicenseFile] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        let base = root.standardizedFileURL.path
        var files: [LicenseFile] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let name = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            files.append(LicenseFile(url: url, name: name))
        }
        return files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var bundled: [LicenseFile] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return all(in: resources.appending(path: "Licenses", directoryHint: .isDirectory))
    }
}

struct LicensesView: View {
    static let notice = "DOSCrate bundles DOSBox Staging 0.83.0, licensed under GPL-2.0-or-later. "
        + "Source: https://github.com/dosbox-staging/dosbox-staging/tree/v0.83.0 — "
        + "a copy of the corresponding source is attached to every DOSCrate release, "
        + "and we will provide it on request for three years."

    private let files = LicenseFile.bundled
    @State private var selection: LicenseFile.ID?

    private var selected: LicenseFile? { files.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.notice)
                .textSelection(.enabled)
                .padding()
            Divider()
            HSplitView {
                List(files, selection: $selection) { Text($0.name).lineLimit(1).truncationMode(.middle) }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                ScrollView {
                    Text(text(for: selected))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minWidth: 320)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { if selection == nil { selection = files.first?.id } }
    }

    private func text(for file: LicenseFile?) -> String {
        guard let file else { return files.isEmpty ? "No license files found." : "Select a license." }
        return (try? String(contentsOf: file.url, encoding: .utf8))
            ?? (try? String(contentsOf: file.url, encoding: .isoLatin1))
            ?? "Can't read \(file.name)."
    }
}
