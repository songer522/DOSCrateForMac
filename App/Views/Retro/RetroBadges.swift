import LibraryKit
import SwiftUI

enum RetroBadge: Equatable, Sendable {
    case running
    case starting
    case importing
    case missing
    case needsRepair
    case readOnly

    var text: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting…"
        case .importing: "Importing…"
        case .missing: "Missing"
        case .needsRepair: "Needs repair"
        case .readOnly: "Read-only"
        }
    }

    var color: Color {
        switch self {
        case .running: RetroPalette.green
        case .starting, .importing: RetroPalette.yellow
        case .missing: RetroPalette.yellow
        case .needsRepair: RetroPalette.red
        case .readOnly: RetroPalette.panel
        }
    }

    var textColor: Color {
        switch self {
        case .running, .needsRepair: RetroPalette.highlightText
        case .starting, .importing, .missing, .readOnly: RetroPalette.shadow
        }
    }

    static func badges(
        for record: GameRecord,
        running: Set<UUID>,
        starting: Set<UUID>,
        importing: Set<UUID> = []
    ) -> [RetroBadge] {
        var result: [RetroBadge] = []
        if running.contains(record.id) {
            result.append(.running)
        } else if starting.contains(record.id) {
            result.append(.starting)
        } else if importing.contains(record.id) {
            result.append(.importing)
        }
        switch record.status {
        case .missingSource:
            result.append(.missing)
        case .needsRepair:
            result.append(.needsRepair)
        case .readOnly:
            result.append(.readOnly)
        case .ok:
            break
        }
        return result
    }
}

struct RetroBadgesView: View {
    let badges: [RetroBadge]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                Text(badge.text)
                    .font(RetroFont.font())
                    .foregroundStyle(badge.textColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badge.color)
            }
        }
    }
}
