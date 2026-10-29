import AppKit
import LibraryKit
import SwiftUI

struct RetroWindowChrome: NSViewRepresentable {
    let isRetro: Bool

    @MainActor
    static func apply(isRetro: Bool, to window: NSWindow) {
        let targetVisibility: NSWindow.TitleVisibility = isRetro ? .hidden : .visible
        if window.titleVisibility != targetVisibility {
            window.titleVisibility = targetVisibility
        }
        if window.titlebarAppearsTransparent != isRetro {
            window.titlebarAppearsTransparent = isRetro
        }
        if window.styleMask.contains(.fullSizeContentView) != isRetro {
            if isRetro {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
        }
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let btn = window.standardWindowButton(button), btn.isHidden != isRetro {
                btn.isHidden = isRetro
            }
        }
        if let titlebarView = window.standardWindowButton(.closeButton)?.superview {
            if titlebarView.isHidden != isRetro {
                titlebarView.isHidden = isRetro
            }
            if let container = titlebarView.superview, container.isHidden != isRetro {
                container.isHidden = isRetro
            }
        }
        if let themeFrame = window.contentView?.superview {
            for subview in themeFrame.subviews where NSStringFromClass(type(of: subview)).contains("Titlebar") {
                if subview.isHidden != isRetro {
                    subview.isHidden = isRetro
                }
            }
        }
    }

    func makeNSView(context: Context) -> ChromeView {
        let view = ChromeView()
        view.isRetro = isRetro
        return view
    }

    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.isRetro = isRetro
        nsView.scheduleApply()
    }

    final class ChromeView: NSView {
        var isRetro = false
        private var keyObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyObserver {
                NotificationCenter.default.removeObserver(keyObserver)
                self.keyObserver = nil
            }
            if let window {
                keyObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.scheduleApply()
                    }
                }
            }
            scheduleApply()
        }

        override func layout() {
            super.layout()
            scheduleApply()
        }

        @MainActor
        func scheduleApply() {
            guard let window else { return }
            let retro = isRetro
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                RetroWindowChrome.apply(isRetro: retro, to: window)
            }
        }
    }
}

private struct RetroControlBoxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let offset: CGFloat = configuration.isPressed ? 1 : 0
        ZStack {
            Rectangle()
                .fill(RetroPalette.bevelDark)
                .frame(width: 12, height: 4)
                .offset(x: 1 + offset, y: 1 + offset)
            Rectangle()
                .fill(RetroPalette.highlightText)
                .frame(width: 12, height: 4)
                .overlay {
                    Rectangle()
                        .strokeBorder(RetroPalette.shadow, lineWidth: 1)
                }
                .offset(x: offset, y: offset)
        }
        .frame(width: 20, height: 20)
        .background(RetroPalette.panel, ignoresSafeAreaEdges: [])
        .retroBevel(configuration.isPressed ? .sunken : .raised)
        .contentShape(Rectangle())
    }
}

struct RetroLibraryView: View {
    @Bindable var model: AppModel
    let records: [GameRecord]
    let commands: LibraryCommands
    @Binding var showsGrid: Bool
    @Binding var showsInspector: Bool
    @Binding var choosingImport: Bool
    var onClose: () -> Void = { NSApplication.shared.terminate(nil) }

    static func playTarget(
        selected: Set<UUID>,
        running: Set<UUID>,
        starting: Set<UUID>,
        pendingRemoval: Set<UUID>,
        replacing: Set<UUID> = []
    ) -> UUID? {
        guard selected.count == 1, let id = selected.first else { return nil }
        guard !running.contains(id),
              !starting.contains(id),
              !pendingRemoval.contains(id),
              !replacing.contains(id) else {
            return nil
        }
        return id
    }

    private var playID: UUID? {
        Self.playTarget(
            selected: model.selectedIDs,
            running: model.sessions.running,
            starting: model.startingIDs,
            pendingRemoval: model.pendingRemovalIDs,
            replacing: model.imports.replacingIDs
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            windowTitleBar
            buttonBar
            HStack(spacing: 0) {
                RetroSidebar(model: model)
                    .frame(width: 180)
                desktop
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsInspector {
                    inspectorPanel
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            RetroStatusBar(model: model)
        }
        .disabled(model.metadata.artErrorMessage != nil)
        .background(RetroPalette.desktop)
        .ignoresSafeArea(.container, edges: .top)
        .toolbar(.hidden, for: .windowToolbar)
        .overlay {
            if let artError = model.metadata.artErrorMessage {
                RetroModalContainer(
                    title: "Couldn't save art",
                    width: 360,
                    onCancel: { model.metadata.artErrorMessage = nil },
                    onDefaultAction: { model.metadata.artErrorMessage = nil }
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(artError)
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button("OK") {
                                model.metadata.artErrorMessage = nil
                            }
                            .buttonStyle(RetroButtonStyle(kind: .text))
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var windowTitleBar: some View {
        ZStack(alignment: .leading) {
            Text("DOSCrate")
                .font(RetroFont.font())
                .foregroundStyle(RetroPalette.highlightText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                .background(RetroPalette.highlight, ignoresSafeAreaEdges: [])
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            HStack(spacing: 0) {
                Button(action: onClose) {
                    EmptyView()
                }
                .buttonStyle(RetroControlBoxButtonStyle())
                .help("Quit DOSCrate")
                .accessibilityLabel("Quit DOSCrate")

                Rectangle()
                    .fill(RetroPalette.shadow)
                    .frame(width: 1, height: 24)
            }
        }
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(RetroPalette.shadow)
                .frame(height: 1)
        }
    }

    private var buttonBar: some View {
        HStack(spacing: 8) {
            Button {
                choosingImport = true
            } label: {
                iconLabel("Import", symbol: "plus", color: RetroPalette.green)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            Button {
                if let id = playID { model.play(id) }
            } label: {
                iconLabel("Play", symbol: "play.fill", color: playID != nil ? RetroPalette.green : RetroPalette.bevelDark)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))
            .disabled(playID == nil)

            Button {
                showsGrid.toggle()
            } label: {
                iconLabel(showsGrid ? "List" : "Grid",
                          symbol: showsGrid ? "list.bullet" : "square.grid.2x2",
                          color: RetroPalette.desktop)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            RetroMenuButton(buildMenu: { buildFilterMenu() }) {
                iconLabel(
                    "Filter",
                    symbol: model.query.hasActiveMetadataFilter
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle",
                    color: model.query.hasActiveMetadataFilter ? RetroPalette.green : RetroPalette.desktop
                )
            }

            RetroMenuButton(buildMenu: { buildSortMenu() }) {
                iconLabel("Sort", symbol: "arrow.up.arrow.down", color: RetroPalette.desktop)
            }

            Button {
                showsInspector.toggle()
            } label: {
                iconLabel("Details", symbol: "sidebar.trailing", color: RetroPalette.desktop)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            SettingsLink {
                iconLabel("Settings", symbol: "gearshape", color: RetroPalette.shadow)
            }
            .buttonStyle(RetroButtonStyle(kind: .icon))

            Spacer()

            HStack(spacing: 6) {
                PixelSymbol("magnifyingglass", color: RetroPalette.bevelDark, pointSize: 16, scale: 1)
                TextField("Search", text: $model.query.search)
                    .textFieldStyle(RetroTextFieldStyle())
                    .frame(width: 200)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RetroPalette.panel, ignoresSafeAreaEdges: [])
        .retroBevel(.raised)
    }

    private func iconLabel(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 2) {
            PixelSymbol(symbol, color: color, pointSize: 16, scale: 2)
            Text(title)
                .font(RetroFont.font())
        }
    }

    private func buildSortMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items: [(String, SortKey)] = [
            ("Title", .title),
            ("Year", .year),
            ("Last Played", .lastPlayed),
            ("Play Time", .playTime),
        ]
        for (title, key) in items {
            menu.addItem(
                RetroMenuAction.makeItem(title: title, checked: model.query.sort == key) { [model] in
                    model.query.sort = key
                }
            )
        }
        return menu
    }

    private func buildFilterMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let records = model.store.records

        let genres = LibraryFilterMenuContent.includingSelected(
            model.query.genre,
            in: allGenres(in: records)
        )
        menu.addItem(
            makeStringFilterSubmenuItem(
                title: model.query.genre.map { "Genre: \($0)" } ?? "Genre",
                allTitle: "All Genres",
                options: genres,
                current: model.query.genre
            ) { [model] newValue in
                model.query.genre = newValue
            }
        )

        var years = allYears(in: records)
        if let selectedYear = model.query.year, !years.contains(selectedYear) {
            years.append(selectedYear)
            years.sort()
        }
        let yearItem = NSMenuItem(
            title: model.query.year.map { "Year: \(String($0))" } ?? "Year",
            action: nil,
            keyEquivalent: ""
        )
        let yearSubmenu = NSMenu()
        yearSubmenu.autoenablesItems = false
        yearSubmenu.addItem(
            RetroMenuAction.makeItem(title: "All Years", checked: model.query.year == nil) { [model] in
                model.query.year = nil
            }
        )
        if !years.isEmpty {
            yearSubmenu.addItem(.separator())
            for year in years {
                let isSelected = model.query.year == year
                yearSubmenu.addItem(
                    RetroMenuAction.makeItem(title: String(year), checked: isSelected) { [model] in
                        model.query.year = isSelected ? nil : year
                    }
                )
            }
        }
        yearItem.submenu = yearSubmenu
        menu.addItem(yearItem)

        let publishers = LibraryFilterMenuContent.includingSelected(
            model.query.publisher,
            in: allPublishers(in: records)
        )
        menu.addItem(
            makeStringFilterSubmenuItem(
                title: model.query.publisher.map { "Publisher: \($0)" } ?? "Publisher",
                allTitle: "All Publishers",
                options: publishers,
                current: model.query.publisher
            ) { [model] newValue in
                model.query.publisher = newValue
            }
        )

        let developers = LibraryFilterMenuContent.includingSelected(
            model.query.developer,
            in: allDevelopers(in: records)
        )
        menu.addItem(
            makeStringFilterSubmenuItem(
                title: model.query.developer.map { "Developer: \($0)" } ?? "Developer",
                allTitle: "All Developers",
                options: developers,
                current: model.query.developer
            ) { [model] newValue in
                model.query.developer = newValue
            }
        )

        menu.addItem(.separator())
        let clearItem = RetroMenuAction.makeItem(
            title: "Clear Filters",
            checked: false,
            enabled: model.query.hasActiveMetadataFilter
        ) { [model] in
            model.query.clearMetadataFilters()
        }
        menu.addItem(clearItem)
        return menu
    }

    private func makeStringFilterSubmenuItem(
        title: String,
        allTitle: String,
        options: [String],
        current: String?,
        onSelect: @escaping @MainActor (String?) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(
            RetroMenuAction.makeItem(title: allTitle, checked: current == nil) {
                onSelect(nil)
            }
        )
        if !options.isEmpty {
            submenu.addItem(.separator())
            for option in options {
                let isSelected = current.map {
                    $0.localizedCaseInsensitiveCompare(option) == .orderedSame
                } ?? false
                submenu.addItem(
                    RetroMenuAction.makeItem(title: option, checked: isSelected) {
                        onSelect(isSelected ? nil : option)
                    }
                )
            }
        }
        item.submenu = submenu
        return item
    }

    @ViewBuilder private var desktop: some View {
        if records.isEmpty {
            let isEmptyStore = model.store.records.isEmpty
            ZStack {
                RetroPalette.desktop
                RetroPanel(title: isEmptyStore ? "No Games Yet" : "No Matches") {
                    VStack(spacing: 8) {
                        PixelSymbol("gamecontroller", color: RetroPalette.desktop, pointSize: 16, scale: 2)
                        Text(isEmptyStore
                             ? "Import a game folder, zip or disc image to get started."
                             : "Try a different search or collection.")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.shadow)
                            .multilineTextAlignment(.center)
                    }
                    .padding(16)
                }
                .frame(maxWidth: 360)
            }
        } else if showsGrid {
            RetroGameGrid(model: model, records: records, commands: commands)
        } else {
            RetroGameList(model: model, records: records, commands: commands)
        }
    }

    private var inspectorTitle: String {
        if let record = model.selection.flatMap(model.store.record) {
            return record.game.title
        } else if model.selectedIDs.count > 1 {
            return "\(model.selectedIDs.count) Games Selected"
        } else {
            return "No Game Selected"
        }
    }

    private var inspectorPanel: some View {
        RetroPanel(title: inspectorTitle) {
            if let record = model.selection.flatMap(model.store.record) {
                GameDetailView(model: model, record: record)
                    .id(record.id)
                    .retroControls()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedIDs.count > 1 {
                VStack(spacing: 8) {
                    PixelSymbol("square.stack", color: RetroPalette.bevelDark, pointSize: 16, scale: 2)
                    Text("\(model.selectedIDs.count) Games Selected")
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    PixelSymbol("gamecontroller", color: RetroPalette.bevelDark, pointSize: 16, scale: 2)
                    Text("No Game Selected")
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.shadow)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct RetroMenuButton<Label: View>: View {
    let buildMenu: @MainActor () -> NSMenu
    @ViewBuilder let label: () -> Label
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            guard let anchorView else { return }
            let menu = buildMenu()
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: -2),
                in: anchorView
            )
        } label: {
            label()
        }
        .buttonStyle(RetroButtonStyle(kind: .icon))
        .background(RetroMenuAnchor(anchorView: $anchorView))
    }
}

private struct RetroMenuAnchor: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            anchorView = view
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchorView !== nsView {
            DispatchQueue.main.async {
                anchorView = nsView
            }
        }
    }
}

@MainActor
private final class RetroMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }

    static func makeItem(
        title: String,
        checked: Bool,
        enabled: Bool = true,
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let target = RetroMenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(RetroMenuAction.invoke), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        return item
    }
}
