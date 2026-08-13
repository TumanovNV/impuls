import XCTest
@testable import ImpulsCore

/// The panel must never put anything readable or clickable off the display it
/// belongs to, whatever preset was chosen and wherever that display sits in the
/// global coordinate space.
final class NotchGeometryTests: XCTestCase {

    /// Checked for each arrangement below rather than written out per case.
    ///
    /// The *content* has to be on screen. The window is larger than the content
    /// by `windowPadding` — transparent slack for the shoulders and the shadow —
    /// and that slack is allowed to hang over the edge; it is what stops a
    /// display from shrinking a panel it could otherwise show in full.
    private func assertContentIsOnDisplay(
        _ geometry: NotchGeometry,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = geometry.display.frame
        let padding = NotchGeometry.windowPadding

        for size in [geometry.expandedSize, geometry.collapsedSize] {
            let content = geometry.contentScreenRect(for: size)
            XCTAssertGreaterThanOrEqual(content.minX, frame.minX, "content off the left edge", file: file, line: line)
            XCTAssertLessThanOrEqual(content.maxX, frame.maxX, "content off the right edge", file: file, line: line)
            XCTAssertGreaterThanOrEqual(content.minY, frame.minY, "content off the bottom edge", file: file, line: line)
            XCTAssertEqual(content.maxY, frame.maxY + 2, accuracy: 0.001, "content hangs from the top edge", file: file, line: line)
        }

        // Only decoration may overhang, and only by as much as there is.
        let window = geometry.windowFrame
        XCTAssertGreaterThanOrEqual(window.minX, frame.minX - padding.left - 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(window.maxX, frame.maxX + padding.right + 0.001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(window.minY, frame.minY - padding.bottom - 0.001, file: file, line: line)
        XCTAssertEqual(window.maxY, frame.maxY, accuracy: 0.001, "the panel hangs from the top edge", file: file, line: line)

        // The hover targets belong to this display too, or a pointer on one
        // screen would open the panel on another.
        XCTAssertGreaterThanOrEqual(geometry.hoverRect.minX, frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(geometry.hoverRect.maxX, frame.maxX, file: file, line: line)
        XCTAssertEqual(geometry.warmZone.minX, frame.minX, file: file, line: line)
        XCTAssertEqual(geometry.warmZone.width, frame.width, file: file, line: line)
        XCTAssertGreaterThanOrEqual(geometry.warmZone.minY, frame.minY, file: file, line: line)
    }

    func testEveryPresetStaysOnEveryArrangement() {
        let displays = [
            DisplayFixtures.macBook(),
            DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440)),
            DisplayFixtures.plain(id: 3, origin: CGPoint(x: -1920, y: -300), size: CGSize(width: 1920, height: 1080)),
            DisplayFixtures.plain(id: 4, origin: CGPoint(x: 0, y: 982), size: CGSize(width: 3008, height: 1692)),
            DisplayFixtures.plain(id: 5, origin: CGPoint(x: -1180, y: -820), size: CGSize(width: 1180, height: 820)),
            DisplayFixtures.plain(id: 6, origin: .zero, size: CGSize(width: 1024, height: 768)),
        ]

        for display in displays {
            for preset in SettingsStore.PanelSize.allCases {
                let geometry = NotchGeometry(
                    display: display,
                    requestedExpandedSize: preset.expandedSize(for: display)
                )
                assertContentIsOnDisplay(geometry)
            }
        }
    }

    // MARK: - The minimum, derived rather than guessed

    /// The floor is Compact because Compact is the smallest layout the panel is
    /// built for — and, at the tallest header any Mac has, it is exactly the
    /// height at which the fullest rail still gets its designed button size.
    func testCompactIsExactlyTheHeightTheFullestRailNeeds() {
        // A 14-inch MacBook Pro's camera housing, the tallest header in play.
        let header: CGFloat = 32

        XCTAssertEqual(
            RailMetrics.comfortablePanelHeight(headerHeight: header),
            AdaptivePanelLayout.compact.height,
            "Compact is the smallest panel in which nine modules still get 28 pt rail buttons"
        )
        XCTAssertEqual(NotchGeometry.minimumExpandedSize, AdaptivePanelLayout.compact)
    }

    /// Headers Impuls actually meets: the 24 pt synthetic strip a display
    /// without a cutout gets, and the 32 pt camera housing of a notched
    /// MacBook. At both, every preset gives the fullest rail its designed size.
    func testTheFullestRailIsUnsqueezedAtEveryPresetOnTheHeadersMacsHave() {
        for header in [24, 32] as [CGFloat] {
            for preset in [
                AdaptivePanelLayout.compact,
                AdaptivePanelLayout.standard,
                AdaptivePanelLayout.large,
            ] {
                let available = preset.height - header - Theme.Space.m
                let button = RailMetrics.buttonHeight(available: available, count: RailMetrics.tallestRailCount)

                XCTAssertEqual(
                    button,
                    Theme.Size.railButtonMax,
                    "a \(Int(header)) pt header in a \(Int(preset.height)) pt panel must not squeeze the rail"
                )
            }
        }
    }

    /// A future Mac with a taller housing is not a cliff. Past 32 pt the rail
    /// starts shrinking towards `railButtonMin`, which is a smaller icon and
    /// not a clipped one — and it keeps fitting until the header is more than
    /// twice anything Apple has shipped.
    func testATallerHeaderShrinksTheRailInsteadOfClippingIt() {
        let smallest = AdaptivePanelLayout.compact.height

        for header in stride(from: CGFloat(24), through: 72, by: 4) {
            let available = smallest - header - Theme.Space.m
            let button = RailMetrics.buttonHeight(available: available, count: RailMetrics.tallestRailCount)

            XCTAssertGreaterThanOrEqual(button, Theme.Size.railButtonMin, "header \(Int(header))")
            XCTAssertLessThanOrEqual(
                RailMetrics.contentHeight(forButtonHeight: button, count: RailMetrics.tallestRailCount),
                available + 0.001,
                "the rail must fit the content area, not merely stop being drawn — header \(Int(header))"
            )
        }
    }

    /// The floor that replaced 320 × 120 is not reachable on hardware. macOS
    /// will not set a display mode below 640 × 480, and Compact fits inside it.
    func testTheFloorIsUnreachableOnAnyDisplayMacOSWillSet() {
        let smallestModes = [
            CGSize(width: 640, height: 480),
            CGSize(width: 800, height: 600),
            CGSize(width: 1024, height: 768),
            CGSize(width: 1280, height: 800),
        ]

        for mode in smallestModes {
            let display = DisplayFixtures.plain(id: 2, origin: .zero, size: mode)
            let geometry = NotchGeometry(
                display: display,
                requestedExpandedSize: SettingsStore.PanelSize.automatic.expandedSize(for: display)
            )

            // Whatever Automatic asked for, it is what the panel gets: the
            // floor never has to step in, and neither does the clamp.
            XCTAssertEqual(
                geometry.expandedSize,
                AdaptivePanelLayout.expandedSize(forDisplayWidth: mode.width),
                "\(Int(mode.width))×\(Int(mode.height)) holds its adaptive preset unclamped"
            )
            XCTAssertGreaterThanOrEqual(geometry.expandedSize.width, NotchGeometry.minimumExpandedSize.width)
            XCTAssertGreaterThanOrEqual(geometry.expandedSize.height, NotchGeometry.minimumExpandedSize.height)
            assertContentIsOnDisplay(geometry)
            // And the rail is comfortable in it, header included.
            let available = geometry.expandedSize.height - geometry.notchSize.height - Theme.Space.m
            XCTAssertEqual(
                RailMetrics.buttonHeight(available: available, count: RailMetrics.tallestRailCount),
                Theme.Size.railButtonMax
            )
        }
    }

    func testADisplayBelowTheFloorKeepsTheDesignedLayoutAndOverhangsEvenly() {
        // Smaller than any mode macOS will set; the floor is what answers.
        let tiny = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 300, height: 200))

        let geometry = NotchGeometry(display: tiny, requestedExpandedSize: AdaptivePanelLayout.compact)

        XCTAssertEqual(geometry.expandedSize, NotchGeometry.minimumExpandedSize)
        XCTAssertEqual(geometry.windowFrame.midX, tiny.frame.midX, "centred, so it overhangs evenly")
        XCTAssertEqual(geometry.collapsedSize.width, 120)
    }

    // MARK: - Clamping

    func testLargeIsClampedOnADisplayNarrowerThanIt() {
        let cramped = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 640, height: 480))

        let geometry = NotchGeometry(display: cramped, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertEqual(geometry.expandedSize.width, 640, "clamped to the display, not to the display less the shadow")
        XCTAssertEqual(geometry.expandedSize.height, AdaptivePanelLayout.large.height)
        assertContentIsOnDisplay(geometry)
    }

    func testAShortDisplayClampsTheHeight() {
        let short = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 1600, height: 220))

        let geometry = NotchGeometry(display: short, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertEqual(geometry.expandedSize.height, 220)
        XCTAssertEqual(geometry.expandedSize.width, AdaptivePanelLayout.large.width)
        assertContentIsOnDisplay(geometry)
    }

    func testADisplayThatHoldsThePanelIsNotClampedForTheSakeOfTheShadow() {
        // 700 pt of panel and 80 pt of slack do not both fit in 720 pt. The
        // panel does, so it is not shrunk — only the shadow is clipped.
        let display = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 720, height: 600))

        let geometry = NotchGeometry(display: display, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertEqual(geometry.expandedSize, AdaptivePanelLayout.large)
        assertContentIsOnDisplay(geometry)
    }

    func testTheCollapsedAnchorNeverOutgrowsAVeryNarrowDisplay() {
        let sliver = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 100, height: 400))

        let geometry = NotchGeometry(display: sliver, requestedExpandedSize: AdaptivePanelLayout.compact)

        XCTAssertEqual(geometry.collapsedSize.width, 100)
        XCTAssertEqual(geometry.notchSize.width, 100)
    }

    // MARK: - Placement

    func testTheExpandedHoverRectFollowsTheWindowAndNotTheRawNotchCentre() {
        let display = DisplayFixtures.plain(id: 2, origin: CGPoint(x: -2560, y: 0), size: CGSize(width: 2560, height: 1440))
        let geometry = NotchGeometry(display: display, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertEqual(geometry.expandedHoverRect.midX, geometry.windowFrame.midX, accuracy: 0.001)
        XCTAssertGreaterThan(geometry.expandedHoverRect.width, geometry.expandedSize.width)
    }

    func testTwoDisplaysProduceHoverTargetsThatDoNotOverlap() {
        let macBook = DisplayFixtures.macBook()
        let monitor = DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440))

        let a = NotchGeometry(display: macBook, requestedExpandedSize: AdaptivePanelLayout.standard)
        let b = NotchGeometry(display: monitor, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertFalse(a.hoverRect.intersects(b.hoverRect))
        XCTAssertFalse(a.warmZone.intersects(b.warmZone))
        XCTAssertFalse(a.expandedHoverRect.intersects(b.expandedHoverRect))
    }

    func testGeometryIsEqualOnlyWhenNothingThePanelUsesHasMoved() {
        let display = DisplayFixtures.macBook()
        let first = NotchGeometry(display: display, requestedExpandedSize: AdaptivePanelLayout.standard)
        let same = NotchGeometry(display: display, requestedExpandedSize: AdaptivePanelLayout.standard)
        let resized = NotchGeometry(display: display, requestedExpandedSize: AdaptivePanelLayout.large)
        let moved = NotchGeometry(
            display: DisplayFixtures.macBook(origin: CGPoint(x: 0, y: 200)),
            requestedExpandedSize: AdaptivePanelLayout.standard
        )

        // Screen-parameter notifications fire for plenty of reasons that leave
        // the panel exactly where it was; those must not rebuild anything.
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, resized)
        XCTAssertNotEqual(first, moved)
    }

    func testTheWarmBandIsNeverDeeperThanItsDisplay() {
        let shallow = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 1280, height: 200))

        let geometry = NotchGeometry(display: shallow, requestedExpandedSize: AdaptivePanelLayout.compact)

        XCTAssertEqual(geometry.warmZone.minY, 0)
        XCTAssertLessThanOrEqual(geometry.warmZone.height, shallow.frame.height + 2)
    }
}
