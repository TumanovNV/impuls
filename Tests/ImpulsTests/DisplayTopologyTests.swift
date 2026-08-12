import XCTest
@testable import ImpulsCore

/// Synthetic display arrangements.
///
/// The point of `DisplayDescriptor` is that none of this needs hardware: a
/// MacBook with a 4K monitor above it and an iPad to the left on Sidecar is
/// three values, so CI verifies arrangements no build machine will ever have.
enum DisplayFixtures {
    /// 14-inch MacBook Pro: 1512 × 982 pt, 32 pt camera housing, 180 pt notch.
    static func macBook(
        id: UInt32 = 1,
        origin: CGPoint = .zero,
        size: CGSize = CGSize(width: 1512, height: 982),
        isPrimary: Bool = true
    ) -> DisplayDescriptor {
        let aux = (size.width - 180) / 2
        return DisplayDescriptor(
            id: id,
            name: "Built-in Display",
            frame: CGRect(origin: origin, size: size),
            safeAreaTop: 32,
            auxiliaryLeftWidth: aux,
            auxiliaryRightWidth: aux,
            backingScale: 2,
            isPrimary: isPrimary
        )
    }

    /// Any display without a camera housing: an external monitor, an older
    /// MacBook, or an iPad running as a Sidecar extended display. Impuls does
    /// not distinguish them, and neither does this fixture.
    static func plain(
        id: UInt32,
        name: String = "Display",
        origin: CGPoint,
        size: CGSize,
        isPrimary: Bool = false,
        backingScale: CGFloat = 2,
        mirrorSourceID: UInt32? = nil
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id,
            name: name,
            frame: CGRect(origin: origin, size: size),
            backingScale: backingScale,
            isPrimary: isPrimary,
            mirrorSourceID: mirrorSourceID
        )
    }
}

final class DisplayTopologyTests: XCTestCase {

    // MARK: - Arrangements

    func testMacBookAloneKeepsItsPhysicalNotch() {
        let macBook = DisplayFixtures.macBook()
        let topology = DisplayTopology.resolve(from: [macBook], preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [1])
        XCTAssertTrue(macBook.hasPhysicalNotch)

        let geometry = NotchGeometry(display: macBook, requestedExpandedSize: AdaptivePanelLayout.standard)
        XCTAssertTrue(geometry.isPhysical)
        XCTAssertEqual(geometry.notchSize, CGSize(width: 180, height: 32))
        XCTAssertEqual(geometry.notchCenterX, 756)
        XCTAssertEqual(geometry.collapsedSize, CGSize(width: 180, height: 32))
    }

    func testExternalDisplayGetsASmallSyntheticAnchorRatherThanAFakeCutout() {
        let monitor = DisplayFixtures.plain(
            id: 2,
            name: "Studio Display",
            origin: CGPoint(x: 1512, y: 0),
            size: CGSize(width: 2560, height: 1440)
        )
        XCTAssertFalse(monitor.hasPhysicalNotch)

        let geometry = NotchGeometry(display: monitor, requestedExpandedSize: AdaptivePanelLayout.large)

        XCTAssertFalse(geometry.isPhysical)
        // Small, branded, and nothing like a 180 pt MacBook cutout.
        XCTAssertEqual(geometry.collapsedSize, CGSize(width: 120, height: 12))
        // The header still leaves a notch-sized gap so the expanded panel reads
        // the same on every display.
        XCTAssertEqual(geometry.notchSize.width, 180)
        XCTAssertEqual(geometry.notchCenterX, monitor.frame.midX)
        // The hover target is barely larger than the anchor: the rest of the
        // top of the display still belongs to the menu bar.
        XCTAssertEqual(geometry.hoverRect.width, 140)
        XCTAssertLessThanOrEqual(geometry.hoverRect.height, 20)
    }

    func testMacBookWithOneExternalDisplayKeepsBoth() {
        let displays = [
            DisplayFixtures.macBook(),
            DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440)),
        ]

        let topology = DisplayTopology.resolve(from: displays, preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [1, 2])
        XCTAssertEqual(topology.display(id: 1)?.hasPhysicalNotch, true)
        XCTAssertEqual(topology.display(id: 2)?.hasPhysicalNotch, false)
    }

    func testTwoExternalDisplaysOnADesktopMacBothGetASurface() {
        let displays = [
            DisplayFixtures.plain(id: 7, name: "Left", origin: CGPoint(x: -2560, y: 0), size: CGSize(width: 2560, height: 1440), isPrimary: false),
            DisplayFixtures.plain(id: 8, name: "Right", origin: .zero, size: CGSize(width: 2560, height: 1440), isPrimary: true),
        ]

        let topology = DisplayTopology.resolve(from: displays, preference: .allDisplays)

        // Primary first, then left to right.
        XCTAssertEqual(topology.displayIDs, [8, 7])
    }

    func testThreeDisplaysAreOrderedDeterministically() {
        let displays = [
            DisplayFixtures.plain(id: 3, name: "Above", origin: CGPoint(x: 0, y: 982), size: CGSize(width: 1920, height: 1080)),
            DisplayFixtures.plain(id: 2, name: "Left", origin: CGPoint(x: -1920, y: 0), size: CGSize(width: 1920, height: 1080)),
            DisplayFixtures.macBook(),
        ]

        let first = DisplayTopology.resolve(from: displays, preference: .allDisplays)
        let second = DisplayTopology.resolve(from: displays.reversed(), preference: .allDisplays)

        XCTAssertEqual(first.displayIDs, [1, 2, 3])
        XCTAssertEqual(first.displayIDs, second.displayIDs, "enumeration order must not reorder surfaces")
    }

    func testDisplayToTheRightIsFoundByAPointerInsideIt() {
        let macBook = DisplayFixtures.macBook()
        let right = DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440))
        let topology = DisplayTopology.resolve(from: [macBook, right], preference: .allDisplays)

        XCTAssertEqual(topology.display(containing: CGPoint(x: 3000, y: 700))?.id, 2)
        XCTAssertEqual(topology.display(containing: CGPoint(x: 700, y: 500))?.id, 1)
    }

    func testDisplayToTheLeftWithANegativeOriginIsHandled() {
        let macBook = DisplayFixtures.macBook()
        let left = DisplayFixtures.plain(id: 2, origin: CGPoint(x: -1920, y: 0), size: CGSize(width: 1920, height: 1080))
        let topology = DisplayTopology.resolve(from: [macBook, left], preference: .allDisplays)

        XCTAssertEqual(topology.display(containing: CGPoint(x: -1000, y: 400))?.id, 2)
        // Nothing assumes minX == 0: the panel is placed from this display's
        // own frame, so it sits in negative coordinates too.
        let geometry = NotchGeometry(display: left, requestedExpandedSize: AdaptivePanelLayout.large)
        XCTAssertEqual(geometry.windowFrame.midX, left.frame.midX)
        XCTAssertLessThan(geometry.windowFrame.minX, 0)
        XCTAssertGreaterThanOrEqual(geometry.windowFrame.minX, left.frame.minX)
    }

    func testDisplayAboveThePrimaryOneIsHandled() {
        let macBook = DisplayFixtures.macBook()
        let above = DisplayFixtures.plain(id: 2, origin: CGPoint(x: 0, y: 982), size: CGSize(width: 1920, height: 1080))
        let topology = DisplayTopology.resolve(from: [macBook, above], preference: .allDisplays)

        XCTAssertEqual(topology.display(containing: CGPoint(x: 900, y: 1500))?.id, 2)
        let geometry = NotchGeometry(display: above, requestedExpandedSize: AdaptivePanelLayout.large)
        XCTAssertEqual(geometry.windowFrame.maxY, above.frame.maxY, "the panel hangs from its own display's top edge")
    }

    func testDisplayBelowThePrimaryOneWithANegativeYIsHandled() {
        let macBook = DisplayFixtures.macBook()
        let below = DisplayFixtures.plain(id: 2, origin: CGPoint(x: 0, y: -1080), size: CGSize(width: 1920, height: 1080))
        let topology = DisplayTopology.resolve(from: [macBook, below], preference: .allDisplays)

        XCTAssertEqual(topology.display(containing: CGPoint(x: 900, y: -500))?.id, 2)
        let geometry = NotchGeometry(display: below, requestedExpandedSize: AdaptivePanelLayout.standard)
        XCTAssertEqual(geometry.windowFrame.maxY, 0)
        XCTAssertLessThan(geometry.windowFrame.minY, 0)
    }

    func testDisplaysWithDifferentLogicalResolutionsEachGetTheirOwnGeometry() {
        let small = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 1280, height: 800), backingScale: 1)
        let retina = DisplayFixtures.plain(id: 3, origin: CGPoint(x: 1280, y: 0), size: CGSize(width: 1280, height: 800), backingScale: 2)

        let a = NotchGeometry(display: small, requestedExpandedSize: AdaptivePanelLayout.standard)
        let b = NotchGeometry(display: retina, requestedExpandedSize: AdaptivePanelLayout.standard)

        // Identical logical size, different backing scale: the panel is the
        // same. Retina must never make the interface bigger.
        XCTAssertEqual(a.expandedSize, b.expandedSize)
        XCTAssertEqual(a.windowFrame.width, b.windowFrame.width)
        XCTAssertNotEqual(a.windowFrame.minX, b.windowFrame.minX)
    }

    // MARK: - Adaptive size

    func testAutomaticChoosesCompactOnASmallDisplay() {
        let display = DisplayFixtures.plain(id: 2, origin: .zero, size: CGSize(width: 1024, height: 768))
        XCTAssertEqual(AdaptivePanelLayout.expandedSize(forDisplayWidth: display.frame.width), AdaptivePanelLayout.compact)
    }

    func testAutomaticChoosesStandardOnEveryBuiltInMacBookDisplay() {
        for width in [1470, 1512, 1710, 1728] as [CGFloat] {
            XCTAssertEqual(
                AdaptivePanelLayout.expandedSize(forDisplayWidth: width),
                AdaptivePanelLayout.standard,
                "a \(Int(width)) pt built-in display keeps the size it has always had"
            )
        }
    }

    func testAutomaticChoosesLargeOnADesktopMonitor() {
        for width in [1920, 2560, 3008] as [CGFloat] {
            XCTAssertEqual(AdaptivePanelLayout.expandedSize(forDisplayWidth: width), AdaptivePanelLayout.large)
        }
    }

    func testAutomaticIsResolvedPerDisplayWithinOneTopology() async {
        await MainActor.run {
            let macBook = DisplayFixtures.macBook()
            let monitor = DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440))
            let size = SettingsStore.PanelSize.automatic

            XCTAssertEqual(size.expandedSize(for: macBook), AdaptivePanelLayout.standard)
            XCTAssertEqual(size.expandedSize(for: monitor), AdaptivePanelLayout.large)
            // A fixed preset stays fixed wherever it opens.
            XCTAssertEqual(SettingsStore.PanelSize.compact.expandedSize(for: monitor), AdaptivePanelLayout.compact)
        }
    }

    // MARK: - Hot plug

    func testHotPlugAddingADisplayLeavesEveryExistingSurfaceAlone() {
        let before = DisplayTopology.resolve(from: [DisplayFixtures.macBook()], preference: .allDisplays)
        let sidecar = DisplayFixtures.plain(id: 9, name: "iPad", origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 1180, height: 820))
        let after = DisplayTopology.resolve(from: [DisplayFixtures.macBook(), sidecar], preference: .allDisplays)

        let change = DisplayTopologyChange.between(previous: before.displayIDs, next: after.displayIDs)

        XCTAssertEqual(change.added, [9])
        XCTAssertEqual(change.removed, [])
        XCTAssertEqual(change.retained, [1], "the display that did not move keeps its surface")
    }

    func testHotPlugRemovingADisplayRemovesOnlyThatSurface() {
        let sidecar = DisplayFixtures.plain(id: 9, name: "iPad", origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 1180, height: 820))
        let before = DisplayTopology.resolve(from: [DisplayFixtures.macBook(), sidecar], preference: .allDisplays)
        let after = DisplayTopology.resolve(from: [DisplayFixtures.macBook()], preference: .allDisplays)

        let change = DisplayTopologyChange.between(previous: before.displayIDs, next: after.displayIDs)

        XCTAssertEqual(change.removed, [9])
        XCTAssertEqual(change.added, [])
        XCTAssertEqual(change.retained, [1])
    }

    func testTheActiveDisplayGoingAwayFallsBackToOneThatIsStillThere() {
        let macBook = DisplayFixtures.macBook()
        let sidecar = DisplayFixtures.plain(id: 9, name: "iPad", origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 1180, height: 820))
        let before = DisplayTopology.resolve(from: [macBook, sidecar], preference: .allDisplays)
        let after = DisplayTopology.resolve(from: [macBook], preference: .allDisplays)

        let change = DisplayTopologyChange.between(previous: before.displayIDs, next: after.displayIDs)
        XCTAssertTrue(change.removed.contains(9), "Impuls was expanded on the iPad that just disconnected")

        // The pointer is still reported where the vanished display used to be.
        // Nothing there contains it any more, so the choice falls through to
        // the display macOS reports as active, then to the primary one.
        XCTAssertNil(after.display(containing: CGPoint(x: 2000, y: 700)))
        XCTAssertEqual(
            after.preferredActiveDisplay(pointerLocation: CGPoint(x: 2000, y: 700), mainDisplayID: nil)?.id,
            1
        )
    }

    // MARK: - Mirroring

    func testMirroredDisplaysProduceOneSurface() {
        let macBook = DisplayFixtures.macBook()
        let mirror = DisplayFixtures.plain(
            id: 2,
            name: "Projector",
            origin: .zero,
            size: macBook.frame.size,
            mirrorSourceID: 1
        )

        let topology = DisplayTopology.resolve(from: [macBook, mirror], preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [1], "a mirror set is one workspace, so it gets one Impuls")
    }

    func testSoftwareMirroringReportedAsTwoIdenticalFramesAlsoCollapses() {
        let primary = DisplayFixtures.plain(id: 1, name: "Primary", origin: .zero, size: CGSize(width: 1920, height: 1080), isPrimary: true)
        let twin = DisplayFixtures.plain(id: 2, name: "Twin", origin: .zero, size: CGSize(width: 1920, height: 1080))

        let topology = DisplayTopology.resolve(from: [twin, primary], preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [1], "the primary display wins the tie, whatever the enumeration order")
    }

    func testExtendedDesktopIsNotMistakenForMirroring() {
        let primary = DisplayFixtures.plain(id: 1, name: "Primary", origin: .zero, size: CGSize(width: 1920, height: 1080), isPrimary: true)
        let extended = DisplayFixtures.plain(id: 2, name: "Extended", origin: CGPoint(x: 1920, y: 0), size: CGSize(width: 1920, height: 1080))

        let topology = DisplayTopology.resolve(from: [primary, extended], preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [1, 2])
    }

    func testAMirrorWhoseSourceIsNotConnectedIsStillShown() {
        let orphan = DisplayFixtures.plain(
            id: 5,
            origin: .zero,
            size: CGSize(width: 1920, height: 1080),
            isPrimary: true,
            mirrorSourceID: 99
        )

        let topology = DisplayTopology.resolve(from: [orphan], preference: .allDisplays)

        XCTAssertEqual(topology.displayIDs, [5], "dropping it would leave the user with no Impuls at all")
    }

    // MARK: - Preference

    func testExplicitSingleDisplayPreferenceKeepsImpulsOnThatDisplayOnly() {
        let displays = [
            DisplayFixtures.macBook(),
            DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440)),
            DisplayFixtures.plain(id: 3, origin: CGPoint(x: -1920, y: 0), size: CGSize(width: 1920, height: 1080)),
        ]

        let topology = DisplayTopology.resolve(from: displays, preference: .single(2))

        XCTAssertEqual(topology.displayIDs, [2])
        // A pointer on a display Impuls is not allowed on does not summon it
        // there; the chosen display answers instead.
        XCTAssertNil(topology.display(containing: CGPoint(x: 700, y: 500)))
        XCTAssertEqual(
            topology.preferredActiveDisplay(pointerLocation: CGPoint(x: 700, y: 500), mainDisplayID: 1)?.id,
            2
        )
    }

    func testASingleDisplayPreferenceForSomethingUnpluggedDoesNotHideImpuls() {
        let displays = [DisplayFixtures.macBook()]

        let topology = DisplayTopology.resolve(from: displays, preference: .single(404))

        XCTAssertEqual(topology.displayIDs, [1])
    }

    func testAllDisplaysPreferenceOpensWhereverThePointerIs() {
        let displays = [
            DisplayFixtures.macBook(),
            DisplayFixtures.plain(id: 2, origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 2560, height: 1440)),
        ]
        let topology = DisplayTopology.resolve(from: displays, preference: .allDisplays)

        // The pointer decides.
        XCTAssertEqual(
            topology.preferredActiveDisplay(pointerLocation: CGPoint(x: 3000, y: 900), mainDisplayID: 1)?.id,
            2,
            "the shortcut opens Impuls on the monitor being worked on, not on the notched display"
        )
        // Then the display macOS reports as active.
        XCTAssertEqual(
            topology.preferredActiveDisplay(pointerLocation: nil, mainDisplayID: 2)?.id,
            2
        )
        // Then the primary display.
        XCTAssertEqual(
            topology.preferredActiveDisplay(pointerLocation: nil, mainDisplayID: nil)?.id,
            1
        )
    }

    func testAPointerOnTheVeryTopEdgeStillBelongsToItsDisplay() {
        let macBook = DisplayFixtures.macBook()
        let topology = DisplayTopology.resolve(from: [macBook], preference: .allDisplays)

        // Throwing the pointer at the top of the screen parks it on maxY, which
        // `CGRect.contains` calls outside. That position is how one reaches the
        // notch, so it has to count.
        XCTAssertEqual(topology.display(containing: CGPoint(x: 756, y: macBook.frame.maxY))?.id, 1)
    }

    func testNoDisplaysAtAllIsNotACrash() {
        let topology = DisplayTopology.resolve(from: [], preference: .allDisplays)

        XCTAssertTrue(topology.displays.isEmpty)
        XCTAssertNil(topology.preferredActiveDisplay(pointerLocation: .zero, mainDisplayID: 1))
    }

    // MARK: - Preference migration

    func testSettingsWrittenBeforeMultiDisplaySupportMeanEveryDisplay() throws {
        // A 1.4.5 settings blob: no display chosen, three presets only.
        let json = """
        {
          "hotKey": "optionSpace",
          "activationMode": "hoverAndShortcut",
          "openDelay": "short",
          "panelSize": "standard",
          "modules": [{"tab": "actions", "isEnabled": true}],
          "saveClipboardImages": true
        }
        """

        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(decoded.selectedDisplayID)
        XCTAssertEqual(decoded.panelSize, .standard, "an existing manual preset is not silently replaced")
        XCTAssertEqual(DisplayPreference(selectedDisplayID: decoded.selectedDisplayID), .allDisplays)
    }

    func testAnExplicitlyChosenDisplaySurvivesTheUpgrade() throws {
        let json = """
        {
          "hotKey": "optionSpace",
          "activationMode": "hoverAndShortcut",
          "openDelay": "short",
          "panelSize": "large",
          "selectedDisplayID": 69733382,
          "modules": [{"tab": "actions", "isEnabled": true}],
          "saveClipboardImages": true
        }
        """

        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.selectedDisplayID, 69_733_382)
        XCTAssertEqual(decoded.panelSize, .large)
        XCTAssertEqual(DisplayPreference(selectedDisplayID: decoded.selectedDisplayID), .single(69_733_382))
    }

    func testAnUnknownPanelPresetCostsThePresetAndNothingElse() throws {
        let json = """
        {
          "hotKey": "controlSpace",
          "activationMode": "shortcutOnly",
          "openDelay": "deliberate",
          "panelSize": "gigantic",
          "modules": [{"tab": "notes", "isEnabled": true}],
          "saveClipboardImages": false,
          "persistClipboardHistory": true
        }
        """

        let decoded = try JSONDecoder().decode(ImpulsSettingsSnapshot.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.panelSize, .standard)
        XCTAssertEqual(decoded.hotKey, .controlSpace)
        XCTAssertEqual(decoded.activationMode, .shortcutOnly)
        XCTAssertTrue(decoded.persistClipboardHistory)
    }

    func testAutomaticRoundTripsThroughStorage() async throws {
        try await MainActor.run {
            let suite = "io.tumanov.impuls.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let first = SettingsStore(defaults: defaults)
            first.panelSize = .automatic
            first.selectedDisplayID = nil

            let second = SettingsStore(defaults: defaults)
            XCTAssertEqual(second.panelSize, .automatic)
            XCTAssertEqual(second.displayPreference, .allDisplays)
        }
    }
}
