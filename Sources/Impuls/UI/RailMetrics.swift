import CoreGraphics

/// How much room the module rail needs, and how tall its buttons may be.
///
/// Extracted from `NotchContentView` so the panel's smallest honest size is
/// arithmetic rather than an opinion. `NotchGeometry` clamps the panel to the
/// display it appears on, and "how small is too small" has to be answerable
/// from the layout itself: the rail is the tallest thing in the panel, so the
/// rail is what decides.
enum RailMetrics {
    /// The worst case the panel has to survive: every module enabled. Nine
    /// modules split 5/4 (`NotchViewModel.leftRailTabs`), so five is the number
    /// that has to fit.
    static let tallestRailCount = (NotchViewModel.Tab.allCases.count + 1) / 2

    /// How tall one rail icon may be, given the height the content area has.
    ///
    /// Both rails are measured against the longer of the two and told the same
    /// answer. Sizing each rail to its own contents would be worse than the
    /// overflow it replaces: the shorter rail's icons would come out larger
    /// than the longer rail's, and a rail is supposed to read as one row of
    /// equals.
    ///
    /// A margin is taken off both ends before anything is divided. Fitting to
    /// the raw height is what let the rail sit flush against the header above
    /// and the panel edge below — it fit, but only in the sense that nothing
    /// was clipped, and an icon touching the rim reads as an overflow that
    /// happened to stop in time.
    static func buttonHeight(available: CGFloat, count: Int) -> CGFloat {
        let count = CGFloat(max(count, 1))
        let usable = available - 2 * Theme.Space.xs
        guard usable > 0 else { return Theme.Size.railButtonMax }
        let fitted = (usable - Theme.Space.xs * (count - 1)) / count
        return min(Theme.Size.railButtonMax, max(Theme.Size.railButtonMin, fitted.rounded(.down)))
    }

    /// Content height at which the rail's buttons reach a given height exactly.
    /// The inverse of `buttonHeight`, and the reason the panel's minimum can be
    /// derived instead of guessed.
    static func contentHeight(forButtonHeight buttonHeight: CGFloat, count: Int) -> CGFloat {
        let count = CGFloat(max(count, 1))
        return buttonHeight * count + Theme.Space.xs * (count - 1) + 2 * Theme.Space.xs
    }

    /// Smallest panel height at which the fullest rail still gets buttons at
    /// their designed size — not merely their smallest legible one.
    ///
    /// The header is the display's notch, which differs per Mac, so it is a
    /// parameter rather than a constant. The bottom padding is the content
    /// area's own.
    static func comfortablePanelHeight(headerHeight: CGFloat, count: Int = tallestRailCount) -> CGFloat {
        headerHeight + Theme.Space.m + contentHeight(forButtonHeight: Theme.Size.railButtonMax, count: count)
    }

    /// Smallest panel height at which the fullest rail still fits at all, with
    /// its buttons at `Theme.Size.railButtonMin`. Below this an icon is clipped.
    static func minimumPanelHeight(headerHeight: CGFloat, count: Int = tallestRailCount) -> CGFloat {
        headerHeight + Theme.Space.m + contentHeight(forButtonHeight: Theme.Size.railButtonMin, count: count)
    }

    /// Width the two rails and the padding around them consume, leaving the
    /// remainder to the pane. See `NotchContentView.content`.
    static let chromeWidth: CGFloat =
        2 * Theme.Space.m          // the content area's horizontal padding
        + 2 * Theme.Size.railWidth // both rails
        + 2 * Theme.Space.m        // the stack's spacing either side of the pane
}
