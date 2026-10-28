import Foundation

struct GridSelection {
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
}
