import AppKit
import LibraryKit
import SwiftUI

enum PlaceholderCover {
    /// FNV-1a hash of the title, mapped to a hue in [0, 1).
    static func hue(for title: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Double(hash % 360) / 360
    }

    static func color(for title: String) -> Color {
        Color(hue: hue(for: title), saturation: 0.45, brightness: 0.55)
    }

    static func yearText(for year: Int?) -> String? {
        year.map(String.init)
    }
}

/// A game's cover at 3:4, or a colored placeholder with the title (and year, when set) when there is none.
struct CoverView: View {
    let record: GameRecord
    var isRunning = false
    var isStarting = false
    var isLoadingArt = false
    var artRevision = 0

    @State private var image: NSImage?
    @Environment(\.retroTheme) private var retroTheme

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    PlaceholderCover.color(for: record.game.title)
                        .overlay {
                            VStack(spacing: 4) {
                                Text(record.game.title)
                                    .font(.headline)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                                if let yearText = PlaceholderCover.yearText(for: record.game.year) {
                                    Text(yearText)
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                            }
                            .padding(8)
                        }
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) { badges.padding(6) }
            .overlay(alignment: .bottomTrailing) {
                if isLoadingArt {
                    Group {
                        if retroTheme {
                            RetroSpinner()
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .padding(4)
                                .background(.regularMaterial, in: Circle())
                        }
                    }
                    .padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: CoverKey(crate: record.crateURL, modified: coverModified, revision: artRevision)) {
                image = await Self.loadCover(in: record.crateURL)
            }
    }

    private struct CoverKey: Equatable {
        var crate: URL
        var modified: Date?
        var revision: Int
    }

    private var coverModified: Date? {
        let url = CrateIO().coverURL(record.crateURL)
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @ViewBuilder private var badges: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch record.status {
            case .missingSource: badge("Missing", .orange)
            case .needsRepair: badge("Needs repair", .red)
            case .readOnly: badge("Read-only", .gray)
            case .ok: EmptyView()
            }
            if isRunning {
                badge("Running", .green)
            } else if isStarting {
                badge("Starting…", .blue)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }

    private static func loadCover(in crate: URL) async -> NSImage? {
        let url = CrateIO().coverURL(crate)
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        return data.flatMap { NSImage(data: $0) }
    }
}
