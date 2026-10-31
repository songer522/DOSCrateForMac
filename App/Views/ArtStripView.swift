import AppKit
import LibraryKit
import os
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct ArtStripView: View {
    static let thumbnailSize = CGSize(width: 112, height: 84)

    let crateURL: URL
    var isLoadingArt = false
    var artRevision = 0
    var isReadOnly = false
    var onArtChanged: () -> Void = {}
    var onError: (String, String) -> Void = { _, _ in }

    @State private var localRevision = 0
    @State private var dropTargeted = false
    @Environment(\.retroTheme) private var retroTheme

    static func items(in crate: URL) -> [URL] {
        let io = CrateIO()
        let fm = FileManager.default
        var result: [URL] = []
        for url in [io.backURL(crate), io.discURL(crate), io.logoURL(crate)] {
            if fm.fileExists(atPath: url.path) {
                result.append(url)
            }
        }
        result.append(contentsOf: io.screenshotURLs(crate))
        return result
    }

    static func isHidden(in crate: URL) -> Bool {
        items(in: crate).isEmpty
    }

    @discardableResult
    static func addScreenshots(
        from urls: [URL],
        in crate: URL,
        gameID: UUID? = nil,
        model: AppModel? = nil,
        onArtChanged: () -> Void = {},
        onError: (String, String) -> Void = { _, _ in }
    ) -> Bool {
        let io = CrateIO()
        var addedAny = false
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { continue }
            do {
                try io.addScreenshot(pngData: png, in: crate)
                addedAny = true
            } catch {
                if let model {
                    model.alert = AppAlert(title: "Can't save screenshot", message: error.localizedDescription)
                } else {
                    onError("Can't save screenshot", error.localizedDescription)
                }
                return false
            }
        }
        guard addedAny else {
            if !urls.isEmpty {
                let message = "The image couldn't be converted to PNG."
                if let model {
                    model.alert = AppAlert(title: "Can't use that image", message: message)
                } else {
                    onError("Can't use that image", message)
                }
            }
            return false
        }
        if let model, let gameID {
            model.metadata.artRevision[gameID, default: 0] += 1
        }
        onArtChanged()
        return true
    }

    @discardableResult
    static func removeArtItem(
        at url: URL,
        gameID: UUID? = nil,
        model: AppModel? = nil,
        onArtChanged: () -> Void = {},
        onError: (String, String) -> Void = { _, _ in }
    ) -> Bool {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let model, let gameID {
                model.metadata.artRevision[gameID, default: 0] += 1
            }
            onArtChanged()
            return true
        } catch {
            if let model {
                model.alert = AppAlert(title: "Can't remove \(url.lastPathComponent)", message: error.localizedDescription)
            } else {
                onError("Can't remove \(url.lastPathComponent)", error.localizedDescription)
            }
            return false
        }
    }

    var body: some View {
        let effectiveRevision = artRevision &+ localRevision
        let _ = effectiveRevision
        let urls = Self.items(in: crateURL)
        if !urls.isEmpty || isLoadingArt || !isReadOnly {
            if retroTheme {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Art")
                            .font(RetroFont.font())
                            .foregroundStyle(RetroPalette.secondaryText)
                        if isLoadingArt {
                            RetroSpinner()
                        }
                        Spacer(minLength: 0)
                        if !isReadOnly {
                            Button("+", action: chooseScreenshots)
                                .buttonStyle(RetroButtonStyle(kind: .text))
                                .help("Add Screenshot…")
                                .accessibilityLabel("Add Screenshot…")
                        }
                    }
                    if !urls.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                                    ArtThumbnailButton(url: url, retro: true, revision: effectiveRevision) {
                                        ArtQuickLookController.shared.present(urls: urls, startingAt: index)
                                    }
                                    .contextMenu {
                                        thumbnailContextMenu(for: url, index: index, urls: urls)
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .background(RetroPalette.panel)
                        .retroBevel(.sunken)
                    }
                }
                .overlay {
                    if dropTargeted && !isReadOnly {
                        Rectangle()
                            .strokeBorder(RetroPalette.highlight, style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                    }
                }
                .dropDestination(for: URL.self) { dropped, _ in
                    addScreenshots(from: dropped)
                } isTargeted: { dropTargeted = $0 }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Art")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if isLoadingArt {
                            ProgressView().controlSize(.small)
                        }
                        Spacer(minLength: 0)
                        if !isReadOnly {
                            Button("Add Screenshot…", systemImage: "plus", action: chooseScreenshots)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Add Screenshot…")
                        }
                    }
                    if !urls.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                                    ArtThumbnailButton(url: url, retro: false, revision: effectiveRevision) {
                                        ArtQuickLookController.shared.present(urls: urls, startingAt: index)
                                    }
                                    .contextMenu {
                                        thumbnailContextMenu(for: url, index: index, urls: urls)
                                    }
                                }
                            }
                        }
                    }
                }
                .overlay {
                    if dropTargeted && !isReadOnly {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .dropDestination(for: URL.self) { dropped, _ in
                    addScreenshots(from: dropped)
                } isTargeted: { dropTargeted = $0 }
            }
        }
    }

    @ViewBuilder
    private func thumbnailContextMenu(for url: URL, index: Int, urls: [URL]) -> some View {
        Button("Quick Look") {
            ArtQuickLookController.shared.present(urls: urls, startingAt: index)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if !isReadOnly {
            Divider()
            Button("Remove", role: .destructive) {
                removeArt(at: url)
            }
        }
    }

    private func chooseScreenshots() {
        guard !isReadOnly else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        _ = addScreenshots(from: panel.urls)
    }

    private func addScreenshots(from urls: [URL]) -> Bool {
        guard !isReadOnly else { return false }
        return Self.addScreenshots(
            from: urls,
            in: crateURL,
            onArtChanged: {
                localRevision += 1
                onArtChanged()
            },
            onError: onError
        )
    }

    private func removeArt(at url: URL) {
        guard !isReadOnly else { return }
        _ = Self.removeArtItem(
            at: url,
            onArtChanged: {
                localRevision += 1
                onArtChanged()
            },
            onError: onError
        )
    }
}

private struct ArtThumbnailButton: View {
    let url: URL
    let retro: Bool
    var revision = 0
    let action: () -> Void
    @State private var image: NSImage?

    private struct Key: Equatable {
        var url: URL
        var revision: Int
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: ArtStripView.thumbnailSize.width, height: ArtStripView.thumbnailSize.height)
            .clipped()
            .modifier(ThumbnailChrome(retro: retro))
        }
        .buttonStyle(.plain)
        .task(id: Key(url: url, revision: revision)) {
            let target = url
            let data = await Task.detached { try? Data(contentsOf: target) }.value
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

private struct ThumbnailChrome: ViewModifier {
    let retro: Bool

    func body(content: Content) -> some View {
        if retro {
            content
                .background(RetroPalette.bevelLight)
                .retroBevel(.raised)
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

final class ArtQuickLookController: NSObject, QLPreviewPanelDataSource, Sendable {
    static let shared = ArtQuickLookController()

    private let urlsLock = OSAllocatedUnfairLock<[URL]>(initialState: [])

    @MainActor
    func present(urls: [URL], startingAt index: Int) {
        urlsLock.withLock { $0 = urls }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        if urls.indices.contains(index) {
            panel.currentPreviewItemIndex = index
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urlsLock.withLock { $0.count }
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = urlsLock.withLock { urls in
            urls.indices.contains(index) ? urls[index] : nil
        }
        return url.map { $0 as NSURL }
    }
}
