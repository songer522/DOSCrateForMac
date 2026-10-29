import Foundation

struct SelectionStep: Equatable {
    let selected: Set<UUID>
    let anchor: UUID
    let cursor: UUID
}

struct GridSelection {
    /// The game Return plays: the selected one, only when exactly one is selected.
    static func activationTarget(_ selected: Set<UUID>) -> UUID? {
        selected.count == 1 ? selected.first : nil
    }

    static func clear(selected: inout Set<UUID>, anchor: inout UUID?) {
        selected.removeAll()
        anchor = nil
    }

    static func toggle(_ id: UUID, in selected: Set<UUID>) -> Set<UUID> {
        var result = selected
        if result.contains(id) {
            result.remove(id)
        } else {
            result.insert(id)
        }
        return result
    }

    static func extend(from anchor: UUID?, to id: UUID, in order: [UUID]) -> Set<UUID>? {
        guard let anchor,
              let from = order.firstIndex(of: anchor),
              let to = order.firstIndex(of: id) else {
            return nil
        }
        return Set(order[min(from, to)...max(from, to)])
    }

    static func step(
        selected: Set<UUID>,
        anchor: UUID?,
        cursor: UUID?,
        by delta: Int,
        extend shouldExtend: Bool,
        in order: [UUID]
    ) -> SelectionStep? {
        guard !order.isEmpty, delta != 0 else { return nil }

        let currentIndex: Int
        if let cursor, selected.contains(cursor), let idx = order.firstIndex(of: cursor) {
            currentIndex = idx
        } else if let anchor, selected.contains(anchor), let idx = order.firstIndex(of: anchor) {
            currentIndex = idx
        } else {
            let selectedIndices = order.indices.filter { selected.contains(order[$0]) }
            guard let fallback = delta > 0 ? selectedIndices.last : selectedIndices.first else {
                let target = delta > 0 ? order.first! : order.last!
                return SelectionStep(selected: [target], anchor: target, cursor: target)
            }
            currentIndex = fallback
        }

        let nextIndex = min(max(0, currentIndex + delta), order.count - 1)
        let target = order[nextIndex]

        if shouldExtend {
            let effectiveAnchor: UUID
            if let anchor, selected.contains(anchor), order.contains(anchor) {
                effectiveAnchor = anchor
            } else {
                effectiveAnchor = order[currentIndex]
            }
            let range = extend(from: effectiveAnchor, to: target, in: order) ?? [target]
            return SelectionStep(selected: range, anchor: effectiveAnchor, cursor: target)
        } else {
            return SelectionStep(selected: [target], anchor: target, cursor: target)
        }
    }
}
