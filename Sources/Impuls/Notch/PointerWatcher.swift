import AppKit

/// One display's worth of pointer geometry.
struct PointerZone: Equatable {
    let displayID: UInt32
    /// Entering this opens the panel on this display. Empty when hover
    /// activation is off.
    var openRect: CGRect
    /// Leaving this closes the panel, once this display is the one the pointer
    /// is considered to be in.
    var closeRect: CGRect
    /// Where this display's surface takes clicks. Everywhere else its window
    /// must let them through, so this doubles as the `ignoresMouseEvents`
    /// trigger for that window.
    var interactiveRect: CGRect
    /// Band along the top of this display that switches sampling to full rate.
    var warmZone: CGRect
}

/// Drives hover state by sampling the pointer position on a timer.
///
/// Event monitors are not usable here. A global `NSEvent` monitor never sees
/// events delivered to this app's own windows, and a local monitor only fires
/// while the app is active — which an `.accessory` app never is. That makes
/// hover depend on which window happens to sit under the pointer. Sampling
/// `NSEvent.mouseLocation` is independent of event routing, so it behaves
/// identically everywhere, at the cost of one cursor-position read per frame.
///
/// One watcher serves every display. A second monitor adds four rectangles to
/// `zones`, not a second 60 Hz timer: the cost of asking where the pointer is
/// does not depend on how many displays might care about the answer, and N
/// samplers reading the same global position would be N copies of one fact.
@MainActor
final class PointerWatcher {
    /// One entry per display Impuls is present on, in the coordinator's order.
    var zones: [PointerZone] = []

    /// Where the pointer is. Injected so the routing between displays can be
    /// exercised without moving a real mouse across real monitors.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    /// Keeps a surface interactive while a drag is being tracked on it, even if
    /// the pointer wanders outside its `interactiveRect` mid-session.
    var isDragging: (UInt32) -> Bool = { _ in false }
    /// Whether the panel is expanded right now. Read, not assumed: this watcher
    /// tracks where the pointer is, and the panel is opened and closed by other
    /// things too — a drag, the menu bar, a tab that wants the keyboard.
    var isPanelOpen: () -> Bool = { false }
    /// A shortcut-only configuration does not use the pointer as an open/close
    /// authority. The panel stays up until its shortcut or Escape is pressed.
    var tracksPanelExit = true
    /// A keyboard-opened panel must not disappear merely because the pointer
    /// is still in the document where the shortcut was pressed.
    var keepsOpenWithoutPointer: () -> Bool = { false }

    /// Short enough to feel immediate, long enough that a pointer sweeping
    /// across the top of the screen does not trigger the panel.
    var openDelay: TimeInterval = 0.05
    var closeDelay: TimeInterval = 0.32

    /// Hysteresis: how far below a warm band the pointer must fall to cool down.
    var coolMargin: CGFloat = 80
    /// How long the pointer may stand still before sampling drops to the idle
    /// rate wherever it stands. Movement re-warms on the next idle tick.
    var restThreshold: TimeInterval = 3

    private let fastInterval: TimeInterval = 1.0 / 60
    private let idleInterval: TimeInterval = 1.0 / 8

    /// `(inside, displayID)`. The display is the one the pointer entered, and
    /// is `nil` when the pointer left everything.
    var onChange: ((Bool, UInt32?) -> Void)?
    /// `(displayID, interactive)`, raised per display as it changes.
    var onInteractiveChange: ((UInt32, Bool) -> Void)?

    private(set) var isInside = false
    /// Which display the pointer is currently considered to be inside. Only one
    /// can be, which is the same rule that keeps one panel expanded.
    private(set) var insideDisplayID: UInt32?

    private var timer: Timer?
    /// The transition being waited out, and since when. Held together so that a
    /// pointer that changes its mind — leaving one display's notch for
    /// another's — restarts the clock instead of inheriting it.
    private var pending: (target: UInt32?, since: Date)?
    private var interactiveByDisplay: [UInt32: Bool] = [:]
    private var isWarm = false
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var lastMovedAt = Date.distantPast

    func start() {
        schedule(warm: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    /// Drops the bookkeeping for a display that is no longer there, so a
    /// vanished Sidecar or unplugged monitor cannot be reported as the display
    /// the pointer is in.
    func forgetDisplay(_ displayID: UInt32) {
        interactiveByDisplay[displayID] = nil
        if insideDisplayID == displayID {
            insideDisplayID = nil
            isInside = false
        }
        if pending?.target == displayID { pending = nil }
    }

    /// Force the state, e.g. when the panel is toggled from the menu bar.
    func setInside(_ value: Bool, display: UInt32? = nil) {
        pending = nil
        isInside = value
        insideDisplayID = value ? display : nil
    }

    private func schedule(warm: Bool) {
        timer?.invalidate()
        isWarm = warm
        let interval = warm ? fastInterval : idleInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The idle timer may drift by half its beat: nothing it watches for
        // resolves faster than that, and the slack lets the system fold the
        // wake-up into others it was making anyway. The fast timer keeps its
        // precision — it is the one measuring dwell.
        timer.tolerance = warm ? interval / 4 : interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Full rate only for a pointer that is actually going somewhere near the
    /// top of some display; eight samples a second otherwise.
    ///
    /// Two conditions, both required. Place: any display's top band, or
    /// anywhere while the panel is open — with the same hysteresis as ever,
    /// now measured against the band the pointer is actually near rather than
    /// against a single screen's. Motion: the pointer must have moved recently,
    /// because a parked pointer is not on its way anywhere, however close to a
    /// notch it is parked. The menu bar, where cursors spend half their lives,
    /// lies entirely inside the band — place alone used to mean full rate for
    /// as long as one rested there. Movement is noticed on the next idle tick,
    /// 125 ms at worst, which is less than the dwell a hover has to survive
    /// anyway — so warming up is never the thing anybody is waiting on.
    private func updateRate(for point: CGPoint) {
        if point != lastPoint {
            lastPoint = point
            lastMovedAt = Date()
        }
        let moving = Date().timeIntervalSince(lastMovedAt) < restThreshold
        let near: Bool
        if isInside {
            near = true
        } else if isWarm {
            near = zones.contains { zone in
                CGRect(
                    x: zone.warmZone.minX,
                    y: zone.warmZone.minY - coolMargin,
                    width: zone.warmZone.width,
                    height: zone.warmZone.height + coolMargin
                ).contains(point)
            }
        } else {
            near = zones.contains { $0.warmZone.contains(point) }
        }
        let warm = near && moving
        guard warm != isWarm else { return }
        schedule(warm: warm)
    }

    /// The display whose surface the pointer is on, or `nil`.
    ///
    /// Asymmetric on purpose. Once the pointer is inside a display's panel it
    /// keeps it while it stays in that panel's generous close rect; only when
    /// it has left does another display's much smaller open rect get to claim
    /// it. Without that, sliding along the top edge from one monitor to the
    /// next would hand the panel back and forth.
    private func hit(at point: CGPoint) -> UInt32? {
        if isInside,
           let current = insideDisplayID,
           let zone = zones.first(where: { $0.displayID == current }),
           zone.closeRect.contains(point) {
            return current
        }
        return zones.first { !$0.openRect.isEmpty && $0.openRect.contains(point) }?.displayID
    }

    private func tick() {
        let point = pointerLocation()
        updateRate(for: point)
        updateInteractiveRegions(at: point)

        if isPanelOpen(), (!tracksPanelExit || keepsOpenWithoutPointer()) {
            pending = nil
            return
        }

        let target = hit(at: point)
        let inside = target != nil

        // Whether the panel is open and where the pointer is are two separate
        // facts, and only one of them is tracked here. They are supposed to
        // agree, but every path that opens the panel without the pointer —
        // a drop, the menu bar, a tab claiming the keyboard — is a chance for
        // them to come apart, and the shape that costs the user something is
        // always the same: a panel standing open with the mouse nowhere near
        // it, waiting for a hover that already happened. Whatever led there,
        // the pointer is the authority, so say so again.
        // A drag is the one time the panel is meant to stand open with the
        // pointer off it: it was opened to be dropped onto.
        if tracksPanelExit,
           !inside,
           !isInside,
           !isDraggingAnywhere(),
           !keepsOpenWithoutPointer(),
           isPanelOpen() {
            guard waited(for: nil, delay: closeDelay) else { return }
            onChange?(false, nil)
            return
        }

        // Standing still, on the same display, in the same state.
        guard inside != isInside || target != insideDisplayID else {
            pending = nil
            return
        }

        // Moving straight from one display's panel to another's notch is an
        // open, not a close: the delay that matters is the one for arriving.
        guard waited(for: target, delay: inside ? openDelay : closeDelay) else { return }
        isInside = inside
        insideDisplayID = target
        onChange?(inside, target)
    }

    /// True once the pending transition to `target` has stood for `delay`.
    private func waited(for target: UInt32?, delay: TimeInterval) -> Bool {
        guard let current = pending, current.target == target else {
            pending = (target: target, since: Date())
            return false
        }
        guard Date().timeIntervalSince(current.since) >= delay else { return false }
        pending = nil
        return true
    }

    private func isDraggingAnywhere() -> Bool {
        zones.contains { isDragging($0.displayID) }
    }

    /// Everything outside a surface's visible body must reach the app
    /// underneath, so each window is told separately whether the pointer is on
    /// the part of it that takes clicks.
    private func updateInteractiveRegions(at point: CGPoint) {
        for zone in zones {
            let interactive = isDragging(zone.displayID) || zone.interactiveRect.contains(point)
            guard interactiveByDisplay[zone.displayID] != interactive else { continue }
            interactiveByDisplay[zone.displayID] = interactive
            onInteractiveChange?(zone.displayID, interactive)
        }
    }
}
