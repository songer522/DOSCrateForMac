import AppKit
import LibraryKit
import os
import QuickLookUI
import SwiftUI

struct ArtStripView: View {
    let crateURL: URL
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

    var body: some View {
        let urls = Self.items(in: crateURL)
        if !urls.isEmpty {
            if retroTheme {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Art")
                        .font(RetroFont.font())
                        .foregroundStyle(RetroPalette.secondaryText)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                                ArtThumbnailButton(url: url, retro: true) {
                                    ArtQuickLookController.shared.present(urls: urls, startingAt: index)
                                }
                            }
                        }
                        .padding(4)
                    }
                    .background(RetroPalette.panel)
                    .retroBevel(.sunken)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Art")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(urls.enumerated()), id: \.element) { index, url in
                                ArtThumbnailButton(url: url, retro: false) {
                                    ArtQuickLookController.shared.present(urls: urls, startingAt: index)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ArtThumbnailButton: View {
    let url: URL
    let retro: Bool
    let action: () -> Void
    @State private var image: NSImage?

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
            .frame(width: 60, height: 44)
            .clipped()
            .modifier(ThumbnailChrome(retro: retro))
        }
        .buttonStyle(.plain)
        .task(id: url) {
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
