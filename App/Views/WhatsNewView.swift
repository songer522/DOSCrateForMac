import Foundation
import SwiftUI

struct ReleaseNoteItem: Identifiable, Equatable, Hashable, Sendable {
    let title: String
    let summary: String
    var id: String { title.isEmpty ? summary : "\(title): \(summary)" }
}

struct ReleaseVersionNotes: Identifiable, Equatable, Hashable, Sendable {
    let version: String
    let items: [ReleaseNoteItem]
    var id: String { version }
    var displayTitle: String { "Version \(version)" }
}

enum WhatsNewChangelog {
    static var bundledURL: URL? {
        Bundle(for: AppModel.self).url(forResource: "CHANGELOG", withExtension: "md")
            ?? Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
    }

    static var bundled: [ReleaseVersionNotes] {
        guard let url = bundledURL,
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(markdown)
    }

    static func parse(_ markdown: String) -> [ReleaseVersionNotes] {
        var sections: [ReleaseVersionNotes] = []
        var currentVersion: String?
        var currentItems: [ReleaseNoteItem] = []

        func flushSection() {
            if let version = currentVersion, !currentItems.isEmpty {
                sections.append(ReleaseVersionNotes(version: version, items: currentItems))
            }
            currentVersion = nil
            currentItems = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushSection()
                let header = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !header.isEmpty {
                    currentVersion = header
                }
            } else if currentVersion != nil, line.hasPrefix("- ") {
                let bullet = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                guard !bullet.isEmpty else { continue }
                currentItems.append(parseBullet(bullet))
            }
        }
        flushSection()
        return sections
    }

    static func parseBullet(_ raw: String) -> ReleaseNoteItem {
        let cleaned = raw.replacingOccurrences(of: "`", with: "")
        if cleaned.hasPrefix("**"),
           let closeRange = cleaned.dropFirst(2).range(of: "**:") {
            let title = String(cleaned.dropFirst(2)[..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let summary = String(cleaned[closeRange.upperBound...])
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ReleaseNoteItem(title: title, summary: summary)
        }
        return ReleaseNoteItem(
            title: "",
            summary: cleaned.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        )
    }

    /// Renders an embedded HTML fragment (without DOCTYPE or body tags) suitable for Sparkle appcast `<description>`.
    static func html(for section: ReleaseVersionNotes) -> String {
        var lines = ["<h3>What's New in DOSCrate \(escapeHTML(section.version))</h3>", "<ul>"]
        for item in section.items {
            if item.title.isEmpty {
                lines.append("  <li>\(escapeHTML(item.summary))</li>")
            } else {
                lines.append("  <li><strong>\(escapeHTML(item.title)):</strong> \(escapeHTML(item.summary))</li>")
            }
        }
        lines.append("</ul>")
        return lines.joined(separator: "\n")
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct WhatsNewView: View {
    var prefs: Preferences?
    var sections: [ReleaseVersionNotes] = WhatsNewChangelog.bundled
    @State private var selection: ReleaseVersionNotes.ID?
    @FocusState private var isListFocused: Bool
    @Environment(\.retroTheme) private var retroTheme

    static func steppedSelection(
        in sections: [ReleaseVersionNotes],
        current: ReleaseVersionNotes.ID?,
        by delta: Int
    ) -> ReleaseVersionNotes.ID? {
        guard !sections.isEmpty, delta != 0 else { return nil }
        let ids = sections.map(\.id)
        guard let current, let index = ids.firstIndex(of: current) else {
            return delta > 0 ? ids.first : ids.last
        }
        let nextIndex = min(max(index + delta, 0), ids.count - 1)
        return ids[nextIndex]
    }

    private var selected: ReleaseVersionNotes? {
        sections.first { $0.id == selection } ?? sections.first
    }

    private var isRetro: Bool {
        retroTheme || (prefs.map { LibraryLayout(theme: $0.appTheme) == .retro } ?? false)
    }

    var body: some View {
        Group {
            if isRetro {
                RetroPanel(title: "What's New in DOSCrate") {
                    HStack(spacing: 10) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(sections) { section in
                                        let isSelected = (selected?.id == section.id)
                                        HStack {
                                            Text(section.displayTitle)
                                                .font(RetroFont.font())
                                                .foregroundStyle(RetroPalette.highlightText)
                                                .lineLimit(1)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(isSelected ? RetroPalette.highlight : RetroPalette.desktop)
                                        .overlay {
                                            if isSelected {
                                                Rectangle()
                                                    .strokeBorder(
                                                        RetroPalette.highlightText,
                                                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                                                    )
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .id(section.id)
                                        .onTapGesture {
                                            selection = section.id
                                            isListFocused = true
                                        }
                                    }
                                }
                            }
                            .frame(width: 160)
                            .background(RetroPalette.desktop)
                            .retroBevel(.sunken)
                            .focusable()
                            .focusEffectDisabled()
                            .focused($isListFocused)
                            .onAppear { isListFocused = true }
                            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                                let delta = press.key == .upArrow ? -1 : 1
                                guard let next = Self.steppedSelection(in: sections, current: selected?.id, by: delta) else {
                                    return .ignored
                                }
                                selection = next
                                proxy.scrollTo(next)
                                return .handled
                            }
                            .onMoveCommand { direction in
                                let delta: Int
                                switch direction {
                                case .up: delta = -1
                                case .down: delta = 1
                                default: return
                                }
                                if let next = Self.steppedSelection(in: sections, current: selected?.id, by: delta) {
                                    selection = next
                                    proxy.scrollTo(next)
                                }
                            }
                        }

                        ScrollView {
                            if let section = selected {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("DOSCrate \(section.version)")
                                        .font(RetroFont.font())
                                        .foregroundStyle(RetroPalette.shadow)
                                    ForEach(section.items) { item in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("■")
                                                .font(RetroFont.font())
                                                .foregroundStyle(RetroPalette.shadow)
                                            Text(retroItemText(for: item))
                                                .font(RetroFont.font())
                                                .foregroundStyle(RetroPalette.shadow)
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(12)
                            } else {
                                Text("No release notes found.")
                                    .font(RetroFont.font())
                                    .foregroundStyle(RetroPalette.shadow)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RetroPalette.bevelLight)
                        .retroBevel(.sunken)
                    }
                    .padding(12)
                }
                .retroControls()
            } else {
                HSplitView {
                    List(sections, selection: $selection) { section in
                        Text(section.displayTitle)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)

                    ScrollView {
                        if let section = selected {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("What's New in DOSCrate \(section.version)")
                                    .font(.title3.weight(.semibold))
                                ForEach(section.items) { item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.secondary)
                                        Text(standardItemText(for: item))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .padding()
                        } else {
                            Text("No release notes found.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                    .frame(minWidth: 360)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear { if selection == nil { selection = sections.first?.id } }
    }

    private func retroItemText(for item: ReleaseNoteItem) -> String {
        item.title.isEmpty ? item.summary : "\(item.title): \(item.summary)"
    }

    private func standardItemText(for item: ReleaseNoteItem) -> AttributedString {
        guard !item.title.isEmpty else { return AttributedString(item.summary) }
        var result = AttributedString("\(item.title): ")
        result.inlinePresentationIntent = .stronglyEmphasized
        result.append(AttributedString(item.summary))
        return result
    }
}
