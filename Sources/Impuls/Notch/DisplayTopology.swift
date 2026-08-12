import CoreGraphics
import Foundation

/// Everything Impuls needs to know about one display, and nothing that ties it
/// to AppKit.
///
/// The panel used to be built straight from an `NSScreen`, which made the whole
/// layer untestable: verifying that a display to the left with a negative `minX`
/// lands correctly required a second physical monitor plugged in the right way
/// round. A descriptor is a value, so the same arrangement is three lines in a
/// test. `ScreenDisplaySource` is the only place that produces one.
struct DisplayDescriptor: Equatable, Identifiable, Sendable {
    /// `CGDirectDisplayID`. Stable while the display stays connected, which is
    /// exactly as long as a surface for it exists.
    let id: UInt32
    let name: String
    /// Global screen coordinates, in points. May start anywhere: a display to
    /// the left of the primary one has a negative `minX`, one below it a
    /// negative `minY`.
    let frame: CGRect
    /// Height of the camera housing. Non-zero only on a display that has one.
    let safeAreaTop: CGFloat
    /// Widths of the usable strips either side of a physical notch.
    let auxiliaryLeftWidth: CGFloat?
    let auxiliaryRightWidth: CGFloat?
    let menuBarHeight: CGFloat
    /// Read for reporting only. Layout is decided in logical points, never in
    /// pixels — a 5K display and a 1080p display of the same physical size want
    /// the same panel, and scaling by pixel count would give them different ones.
    let backingScale: CGFloat
    /// The display the menu bar belongs to; its frame origin is the origin of
    /// the global coordinate space.
    let isPrimary: Bool
    /// Set when this display mirrors another one. A secondary mirror is not an
    /// independent workspace and must not get its own Impuls.
    let mirrorSourceID: UInt32?

    init(
        id: UInt32,
        name: String,
        frame: CGRect,
        safeAreaTop: CGFloat = 0,
        auxiliaryLeftWidth: CGFloat? = nil,
        auxiliaryRightWidth: CGFloat? = nil,
        menuBarHeight: CGFloat = 24,
        backingScale: CGFloat = 2,
        isPrimary: Bool = false,
        mirrorSourceID: UInt32? = nil
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
        self.menuBarHeight = menuBarHeight
        self.backingScale = backingScale
        self.isPrimary = isPrimary
        self.mirrorSourceID = mirrorSourceID
    }

    /// True only for a display with a real camera housing cut into it. Both
    /// auxiliary strips are required: the inset alone says there is something
    /// at the top, the strips say where it is.
    var hasPhysicalNotch: Bool {
        safeAreaTop > 0 && auxiliaryLeftWidth != nil && auxiliaryRightWidth != nil
    }
}

/// Which displays the user wants Impuls on.
enum DisplayPreference: Equatable, Sendable {
    /// Impuls is available on every display and opens on the one being used.
    case allDisplays
    /// Impuls exists on one display only, whatever else is connected.
    case single(UInt32)

    /// `nil` has meant "the display Impuls picked for you" since the setting
    /// existed, and what it picked was always the notched one. From 1.4.7 it
    /// means every display, which is what users who never opened Settings were
    /// asking for in #34.
    init(selectedDisplayID: UInt32?) {
        if let selectedDisplayID {
            self = .single(selectedDisplayID)
        } else {
            self = .allDisplays
        }
    }
}

/// The set of displays Impuls presents itself on, after mirrors have been
/// folded together and the user's preference applied.
struct DisplayTopology: Equatable {
    let displays: [DisplayDescriptor]

    static let empty = DisplayTopology(displays: [])

    init(displays: [DisplayDescriptor]) {
        self.displays = displays
    }

    /// Folds a raw list of connected displays into the surfaces Impuls should
    /// own.
    ///
    /// Order is deterministic — primary first, then left to right, then top to
    /// bottom, then by identifier — so a reconciliation never reorders surfaces
    /// merely because the system enumerated the same displays differently.
    static func resolve(
        from descriptors: [DisplayDescriptor],
        preference: DisplayPreference
    ) -> DisplayTopology {
        let independent = deduplicatingMirrors(descriptors)
        let selected: [DisplayDescriptor]
        switch preference {
        case .allDisplays:
            selected = independent
        case .single(let id):
            let match = independent.filter { $0.id == id }
            // A display that has been unplugged must not take Impuls with it.
            // Settings clears the stale identifier on the same notification;
            // this keeps the app on screen in between.
            selected = match.isEmpty ? independent : match
        }
        return DisplayTopology(displays: selected.sorted(by: isOrderedBefore))
    }

    /// Mirrored displays share one workspace, so they get one Impuls.
    ///
    /// Two independent checks, because macOS reports mirroring two ways. A
    /// display driven as a mirror names its source, and that is the reliable
    /// signal. Software mirroring can instead surface as two displays occupying
    /// the very same rectangle — which extended desktops never do, since macOS
    /// will not lay two of them on the same coordinates.
    private static func deduplicatingMirrors(
        _ descriptors: [DisplayDescriptor]
    ) -> [DisplayDescriptor] {
        let present = Set(descriptors.map(\.id))
        let sources = descriptors.filter { descriptor in
            guard let mirrored = descriptor.mirrorSourceID else { return true }
            // Keep a mirror whose source is not itself connected: dropping it
            // would leave the user with no Impuls at all.
            return !present.contains(mirrored) && mirrored != descriptor.id
        }

        var byFrame: [String: DisplayDescriptor] = [:]
        var order: [String] = []
        for descriptor in sources {
            let key = "\(descriptor.frame.minX)|\(descriptor.frame.minY)|\(descriptor.frame.width)|\(descriptor.frame.height)"
            guard let existing = byFrame[key] else {
                byFrame[key] = descriptor
                order.append(key)
                continue
            }
            // The primary display wins the tie; otherwise the lower identifier,
            // so the choice does not depend on enumeration order.
            if descriptor.isPrimary || (!existing.isPrimary && descriptor.id < existing.id) {
                byFrame[key] = descriptor
            }
        }
        return order.compactMap { byFrame[$0] }
    }

    private static func isOrderedBefore(_ lhs: DisplayDescriptor, _ rhs: DisplayDescriptor) -> Bool {
        if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
        if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
        if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY > rhs.frame.minY }
        return lhs.id < rhs.id
    }

    var displayIDs: [UInt32] { displays.map(\.id) }

    func display(id: UInt32) -> DisplayDescriptor? {
        displays.first { $0.id == id }
    }

    /// The display a screen point belongs to.
    ///
    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `maxY` whenever it is thrown at the top of a display — which is
    /// how one reaches the notch. The top edge therefore counts as inside, the
    /// same allowance `NotchGeometry` makes for its own rects.
    func display(containing point: CGPoint) -> DisplayDescriptor? {
        displays.first { descriptor in
            point.x >= descriptor.frame.minX
                && point.x < descriptor.frame.maxX
                && point.y >= descriptor.frame.minY
                && point.y <= descriptor.frame.maxY
        }
    }

    /// Where Impuls should appear when something asks for it without naming a
    /// display — the global shortcut, a wake-up, or the removal of the display
    /// it was on.
    ///
    /// The pointer comes first because it is where the user is working. Then
    /// the display macOS considers active, which is the one holding keyboard
    /// focus and the right answer when the pointer sits on a display Impuls is
    /// not allowed on. The primary display is the last resort.
    func preferredActiveDisplay(
        pointerLocation: CGPoint?,
        mainDisplayID: UInt32?
    ) -> DisplayDescriptor? {
        if let pointerLocation, let hit = display(containing: pointerLocation) { return hit }
        if let mainDisplayID, let main = display(id: mainDisplayID) { return main }
        if let primary = displays.first(where: \.isPrimary) { return primary }
        return displays.first
    }
}

/// What changed between two topologies.
///
/// Hot-plugging is the whole reason this is a value rather than a diff done
/// inline: a monitor arriving must add one surface, a monitor leaving must
/// remove one, and everything else must be left exactly as it was — the same
/// windows, the same tab, the same typed text. Expressing that as data is what
/// lets the test suite plug and unplug displays without any hardware.
struct DisplayTopologyChange: Equatable {
    var added: [UInt32] = []
    var removed: [UInt32] = []
    var retained: [UInt32] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    static func between(previous: [UInt32], next: [UInt32]) -> DisplayTopologyChange {
        let previousIDs = Set(previous)
        let nextIDs = Set(next)
        return DisplayTopologyChange(
            added: next.filter { !previousIDs.contains($0) },
            removed: previous.filter { !nextIDs.contains($0) },
            retained: next.filter { previousIDs.contains($0) }
        )
    }
}

/// The three proven panel presets, and the rule that picks one from a display.
///
/// Deliberately not a scale factor. Every size, radius and font in `Theme.swift`
/// is tuned against these three layouts; multiplying the SwiftUI hierarchy by a
/// display's pixel count would invalidate all of it and produce a panel that is
/// merely large rather than one that fits. Choosing among layouts that are known
/// to work cannot do that.
enum AdaptivePanelLayout {
    static let compact = CGSize(width: 560, height: 208)
    static let standard = CGSize(width: 620, height: 208)
    static let large = CGSize(width: 700, height: 232)

    /// Logical points, never pixels. A 27" 5K display running at its default
    /// 2560 pt and the same panel on a 1440p monitor are the same working
    /// surface, and Retina must not make the panel bigger.
    ///
    /// The thresholds sit either side of the built-in displays on purpose:
    /// every MacBook, from the 13" at 1470 pt to the 16" at 1728 pt, lands on
    /// Standard, which is what it has always had. Below 1280 pt — an old
    /// 1280×800 panel, a small Sidecar iPad, a heavily scaled projector —
    /// Compact leaves room either side. A desktop monitor at 1920 pt or more
    /// gets Large.
    static func expandedSize(forDisplayWidth width: CGFloat) -> CGSize {
        if width < 1280 { return compact }
        if width < 1800 { return standard }
        return large
    }
}
