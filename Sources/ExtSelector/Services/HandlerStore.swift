import UniformTypeIdentifiers

/// Process-wide cache of Launch Services lookups, keyed by UTType. Being an actor
/// gives three things at once: queries run off the main thread, the cache is
/// race-free, and revisiting a category returns instantly instead of re-querying.
///
/// Invalidate the affected type after changing a default, or invalidate
/// everything when the app regains focus (defaults may have changed externally).
actor HandlerStore {
    static let shared = HandlerStore()

    struct Snapshot: Sendable {
        let candidates: [AppHandler]
        let current: AppHandler?
        var hasHandlers: Bool { !candidates.isEmpty }
    }

    private var cache: [String: Snapshot] = [:]

    func snapshot(for target: HandlerTarget) async -> Snapshot {
        if let hit = cache[target.key] { return hit }
        // Compute off the actor: `await` releases isolation, so concurrent
        // misses (e.g. a TaskGroup warming a whole category) run their Launch
        // Services queries in parallel instead of serializing on the actor. A
        // rare duplicate compute is harmless — same input, same result.
        let snapshot = await Self.compute(target)
        cache[target.key] = snapshot
        return snapshot
    }

    nonisolated private static func compute(_ target: HandlerTarget) async -> Snapshot {
        Snapshot(
            candidates: LaunchServicesManager.candidates(for: target),
            current: LaunchServicesManager.currentDefault(for: target)
        )
    }

    func invalidate(_ target: HandlerTarget) {
        cache[target.key] = nil
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
