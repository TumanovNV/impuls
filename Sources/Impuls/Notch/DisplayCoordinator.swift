import AppKit

/// Keeps the set of live display surfaces in step with the displays that are
/// actually connected, and remembers which one Impuls is currently on.
///
/// It owns presentation only. It has no reference to the view model, no store
/// and no timer, so there is no path through it that could produce a second
/// copy of a shared service — which is what the old `rebuild()` did on every
/// screen-parameter notification.
@MainActor
final class DisplayCoordinator {
    /// What one reconciliation actually did, so the controller can react to the
    /// two cases that matter — a display appearing, and the active one going
    /// away — without diffing anything itself.
    struct Reconciliation {
        var added: [UInt32] = []
        var removed: [UInt32] = []
        var updated: [UInt32] = []
        var activeWasRemoved = false

        var changedTopology: Bool { !added.isEmpty || !removed.isEmpty }
    }

    private(set) var surfaces: [UInt32: any NotchSurfacing] = [:]
    /// Display order from the topology, so callers iterate deterministically.
    private(set) var order: [UInt32] = []
    private(set) var activeDisplayID: UInt32?

    var activeSurface: (any NotchSurfacing)? {
        guard let activeDisplayID else { return nil }
        return surfaces[activeDisplayID]
    }

    var allSurfaces: [any NotchSurfacing] { order.compactMap { surfaces[$0] } }

    func surface(for displayID: UInt32) -> (any NotchSurfacing)? { surfaces[displayID] }

    /// Matches a fresh set of geometries against the live surfaces: keeps what
    /// is unchanged, updates what moved, creates only what is new, and disposes
    /// of what is gone.
    ///
    /// The factory is passed per call rather than stored, so the coordinator
    /// never holds a closure back to the controller that owns it.
    @discardableResult
    func reconcile(
        geometries: [NotchGeometry],
        makeSurface: (NotchGeometry) -> any NotchSurfacing
    ) -> Reconciliation {
        var result = Reconciliation()
        let fresh = geometries.map(\.display.id)
        let change = DisplayTopologyChange.between(previous: order, next: fresh)

        for displayID in change.removed {
            surfaces.removeValue(forKey: displayID)?.teardown()
            result.removed.append(displayID)
        }

        for geometry in geometries {
            let displayID = geometry.display.id
            if let existing = surfaces[displayID] {
                if existing.geometry != geometry {
                    existing.update(geometry: geometry)
                    result.updated.append(displayID)
                }
            } else {
                surfaces[displayID] = makeSurface(geometry)
                result.added.append(displayID)
            }
        }

        order = fresh

        if let activeDisplayID, result.removed.contains(activeDisplayID) {
            self.activeDisplayID = nil
            result.activeWasRemoved = true
        }
        return result
    }

    /// Moves activation, dropping it from the surface that had it first. Returns
    /// the surface that lost it, which is the one whose keyboard claim the
    /// controller has to ignore from here on.
    @discardableResult
    func activate(_ displayID: UInt32) -> (any NotchSurfacing)? {
        guard displayID != activeDisplayID, let target = surfaces[displayID] else { return nil }
        let previous = activeSurface
        activeDisplayID = displayID
        // The new surface is activated before the old one is stood down, so the
        // window losing key status is already the inactive one by the time its
        // resign notification arrives.
        target.setActive(true)
        previous?.setActive(false)
        return previous
    }

    func teardown() {
        for surface in surfaces.values { surface.teardown() }
        surfaces.removeAll()
        order.removeAll()
        activeDisplayID = nil
    }
}
