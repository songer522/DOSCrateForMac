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
}

/// A game's cover at 3:4, or a colored placeholder with the title when there is none.
struct CoverView: View {
    let record: GameRecord
    var isRunning = false
    var isStarting = false

    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    PlaceholderCover.color(for: record.game.title)
                        .overlay {
                            Text(record.game.title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) { badges.padding(6) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task(id: CoverKey(crate: record.crateURL, modified: coverModified)) {
                image = await Self.loadCover(in: record.crateURL)
            }
    }

    private struct CoverKey: Equatable {
        var crate: URL
        var modified: Date?
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
