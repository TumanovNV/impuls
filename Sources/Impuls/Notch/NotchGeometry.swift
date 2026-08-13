import AppKit

/// Physical description of the notch (or a synthetic anchor on a display
/// without one) plus every derived rect the panel needs, all in screen
/// coordinates, all relative to one display's own frame.
///
/// It resolves no screen of its own any more. A geometry is built for a
/// `DisplayDescriptor` handed to it, which is what lets several of them exist
/// at once — one per display — and what lets every arrangement in the test
/// suite be described rather than plugged in.
struct NotchGeometry: Equatable {
    let display: DisplayDescriptor
    /// Size of the physical notch, or of the strip the header leaves clear on a
    /// display without one.
    let notchSize: CGSize
    /// Horizontal centre of the notch, in global screen coordinates.
    let notchCenterX: CGFloat
    /// True when the display actually has a notch cut into it.
    let isPhysical: Bool
    /// The expanded panel, already clamped to what this display can show.
    let expandedSize: CGSize

    /// Slack around the panel so the concave shoulders and shadow are not clipped.
    static let windowPadding = NSEdgeInsets(top: 0, left: 40, bottom: 44, right: 40)

    /// The smallest layout the panel is actually designed for.
    ///
    /// It is Compact, and that is not a round number picked for comfort. At the
    /// 32 pt camera housing of a notched MacBook, Compact's 208 pt is exactly
    /// `RailMetrics.comfortablePanelHeight`: the height at which the fullest
    /// rail — five icons, the nine modules split 5/4 — still gets its designed
    /// 28 pt buttons. One point less and the rail starts shrinking towards
    /// `railButtonMin`; far enough below and an icon is clipped.
    /// `NotchGeometryTests` asserts where each of those lines is.
    ///
    /// An earlier draft floored at 320 × 120 on the theory that a clipped panel
    /// beats one hanging off the screen. That was wrong twice over: 120 pt
    /// clips the rail on any Mac, and the floor is not somewhere ordinary
    /// hardware goes — every mode the suite checks, from 640 × 480 up, holds
    /// Compact without clamping. Virtual, remote and future displays are not
    /// promised anything here beyond this: below Compact the layout stops
    /// shrinking, the panel is centred, and the shadow rather than the content
    /// is what leaves the screen.
    static let minimumExpandedSize = AdaptivePanelLayout.compact

    /// What a display without a cutout pretends the notch is, for the header
    /// gap only. The visible collapsed anchor is far smaller — see
    /// `collapsedSize`.
    private static let syntheticNotchWidth: CGFloat = 180

    /// Size of the visible body while collapsed.
    ///
    /// A display with a cutout fills the cutout. A display without one gets a
    /// deliberately small tab: it is the only thing standing between the user
    /// and their menu bar, so it takes 12 pt of height rather than the 24 the
    /// header pretends to. Wide enough to read as a deliberate anchor and to
    /// hit without aiming; nowhere near the 180 pt a fake MacBook cutout would
    /// have covered.
    var collapsedSize: CGSize {
        isPhysical ? notchSize : CGSize(width: min(120, display.frame.width), height: 12)
    }

    init(display: DisplayDescriptor, requestedExpandedSize: CGSize) {
        self.display = display

        if display.hasPhysicalNotch,
           let left = display.auxiliaryLeftWidth,
           let right = display.auxiliaryRightWidth {
            let width = max(0, display.frame.width - left - right)
            notchSize = CGSize(width: width, height: display.safeAreaTop)
            notchCenterX = display.frame.minX + left + width / 2
            isPhysical = true
        } else {
            // No cutout: leave a gap the size of a typical one in the header, so
            // the expanded panel reads the same on every display, and centre it.
            notchSize = CGSize(
                width: min(Self.syntheticNotchWidth, display.frame.width),
                height: max(display.menuBarHeight, 24)
            )
            notchCenterX = display.frame.midX
            isPhysical = false
        }

        expandedSize = Self.clamped(requestedExpandedSize, to: display)
    }

    /// The panel has to fit the display it is on, whichever preset asked for it.
    ///
    /// Automatic already chooses by width, but a manual Large on a small
    /// external monitor, or any preset on a heavily scaled display, can still
    /// ask for more than there is.
    ///
    /// Measured against the display's own frame and not against the frame less
    /// the window padding, because those 40 pt either side and 44 pt below are
    /// transparent slack for the concave shoulders and the shadow. Nothing the
    /// user can read or click lives there. Requiring the slack to be on screen
    /// would shrink the panel on a display that could have shown all of it, to
    /// keep a shadow nobody would have missed. The content fits; the decoration
    /// may hang over the edge.
    private static func clamped(_ size: CGSize, to display: DisplayDescriptor) -> CGSize {
        CGSize(
            width: max(minimumExpandedSize.width, min(size.width, display.frame.width)),
            height: max(minimumExpandedSize.height, min(size.height, display.frame.height))
        )
    }

    // MARK: - Derived frames

    var windowSize: CGSize {
        CGSize(
            width: expandedSize.width + Self.windowPadding.left + Self.windowPadding.right,
            height: expandedSize.height + Self.windowPadding.bottom
        )
    }

    /// Panel frame in global screen coordinates, flush with the top of its
    /// display.
    ///
    /// Kept inside the display horizontally. On both real cases — a physical
    /// notch, which is centred, and a synthetic anchor, which we centre — the
    /// clamp changes nothing. It exists for the display narrower than the panel
    /// plus its shoulders, where the window is centred and overhangs evenly
    /// instead of hanging off one side.
    var windowFrame: CGRect {
        let size = windowSize
        var x = notchCenterX - size.width / 2
        if size.width <= display.frame.width {
            x = min(max(x, display.frame.minX), display.frame.maxX - size.width)
        } else {
            x = display.frame.midX - size.width / 2
        }
        return CGRect(
            x: x,
            y: display.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// `CGRect.contains` treats `maxY` as exclusive, and the pointer parks on
    /// exactly `display.frame.maxY` whenever it is thrown at the top of the
    /// display — which is precisely how one reaches the notch. Every rect that
    /// touches the top edge is grown past it so that position counts as inside.
    private func includingTopEdge(_ rect: CGRect) -> CGRect {
        guard rect.maxY >= display.frame.maxY else { return rect }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Rect the content occupies inside the window, in screen coordinates.
    func contentScreenRect(for size: CGSize) -> CGRect {
        includingTopEdge(contentRect(for: size).offsetBy(dx: windowFrame.minX, dy: windowFrame.minY))
    }

    /// Rect the content occupies inside the window, in AppKit window coordinates.
    func contentRect(for size: CGSize) -> CGRect {
        CGRect(
            x: (windowSize.width - size.width) / 2,
            y: windowSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Hover target while collapsed, in global screen coordinates. Slightly
    /// larger than the anchor so the panel opens just before the pointer lands,
    /// and no larger — this rect is the only part of the top of the display
    /// that behaves differently from the menu bar.
    var hoverRect: CGRect {
        let size = isPhysical
            ? CGSize(width: collapsedSize.width + 12, height: collapsedSize.height + 4)
            : CGSize(width: collapsedSize.width + 20, height: 18)
        return includingTopEdge(CGRect(
            x: notchCenterX - size.width / 2,
            y: display.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ))
    }

    /// Band along the top of this display in which pointer sampling runs at
    /// full rate. Deep enough that a pointer heading for the notch is always
    /// noticed before it arrives, and never deeper than the display.
    var warmZone: CGRect {
        let depth = min(260, display.frame.height)
        return includingTopEdge(CGRect(
            x: display.frame.minX,
            y: display.frame.maxY - depth,
            width: display.frame.width,
            height: depth
        ))
    }

    /// Area that keeps the panel open while expanded, in global screen coordinates.
    var expandedHoverRect: CGRect {
        let frame = windowFrame
        let width = expandedSize.width + 24
        return includingTopEdge(CGRect(
            x: frame.midX - width / 2,
            y: display.frame.maxY - expandedSize.height - 12,
            width: width,
            height: expandedSize.height + 12
        ))
    }
}
