import XCTest
@testable import ImpulsCore

final class PanelTransitionTests: XCTestCase {
    func testReduceMotionRekeysAndStopsRepeatingEqualizerMotion() {
        let moving = RepeatingMotionPhase(isAnimating: true, reducesMotion: false)
        let reduced = RepeatingMotionPhase(isAnimating: true, reducesMotion: true)

        XCTAssertTrue(moving.moves)
        XCTAssertFalse(reduced.moves)
        XCTAssertNotEqual(moving, reduced, "the live tree must replace and cancel repeatForever")
    }

    func testNormalMotionHasOneMonotonicPlanAndAQuickerClose() {
        let plan = Theme.PanelMotionPlan.make(reducesMotion: false)

        XCTAssertFalse(plan.reducesMotion)
        XCTAssertEqual(plan.openDuration, 0.22)
        XCTAssertEqual(plan.closeDuration, 0.16)
        XCTAssertEqual(plan.contentCloseDuration, 0.16)
        XCTAssertLessThan(plan.closeDuration, plan.openDuration)
        XCTAssertNotNil(plan.geometryAnimation(opening: true))
        XCTAssertNotNil(plan.geometryAnimation(opening: false))
        XCTAssertNotNil(plan.contentAnimation(opening: true))
    }

    func testReduceMotionRemovesGeometryTravelAndControllerDelay() {
        let plan = Theme.PanelMotionPlan.make(reducesMotion: true)

        XCTAssertTrue(plan.reducesMotion)
        XCTAssertEqual(plan.openDuration, 0)
        XCTAssertEqual(plan.closeDuration, 0)
        XCTAssertEqual(plan.contentCloseDuration, 0.08)
        XCTAssertNil(plan.geometryAnimation(opening: true))
        XCTAssertNil(plan.geometryAnimation(opening: false))
        XCTAssertNotNil(plan.contentAnimation(opening: true), "a short opacity change may remain without spatial travel")
    }

    func testTransitionKeepsTheTopAndCentreFixedAtEverySample() {
        let geometry = NotchTransitionGeometry(
            collapsedSize: CGSize(width: 120, height: 12),
            expandedSize: AdaptivePanelLayout.large
        )
        let envelope = CGRect(x: 40, y: 0, width: 724, height: 252)

        for progress in stride(from: CGFloat(0), through: 1, by: 0.05) {
            let frame = geometry.bodyFrame(in: envelope, progress: progress)
            XCTAssertEqual(frame.minY, envelope.minY, accuracy: 0.0001)
            XCTAssertEqual(frame.midX, envelope.midX, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(frame.width, 120)
            XCTAssertLessThanOrEqual(frame.width, AdaptivePanelLayout.large.width)
            XCTAssertGreaterThanOrEqual(frame.height, 12)
            XCTAssertLessThanOrEqual(frame.height, AdaptivePanelLayout.large.height)
        }
    }

    func testTransitionEndpointsAreTheResolvedPresetWithoutAnIntermediateLayout() {
        let geometry = NotchTransitionGeometry(
            collapsedSize: CGSize(width: 180, height: 32),
            expandedSize: AdaptivePanelLayout.standard
        )
        let envelope = CGRect(origin: .zero, size: CGSize(width: 644, height: 208))

        XCTAssertEqual(geometry.bodyFrame(in: envelope, progress: -1).size, CGSize(width: 180, height: 32))
        XCTAssertEqual(geometry.bodyFrame(in: envelope, progress: 2).size, AdaptivePanelLayout.standard)
        XCTAssertEqual(geometry.topRadius(progress: 0), Theme.collapsedTopRadius)
        XCTAssertEqual(geometry.topRadius(progress: 1), Theme.openTopRadius)
        XCTAssertEqual(geometry.bottomRadius(progress: 0), Theme.collapsedBottomRadius)
        XCTAssertEqual(geometry.bottomRadius(progress: 1), Theme.openBottomRadius)
    }

    func testEverySampleHasMonotonicSidesEvenForTheShallowSyntheticAnchor() {
        let geometry = NotchTransitionGeometry(
            collapsedSize: CGSize(width: 120, height: 12),
            expandedSize: AdaptivePanelLayout.large
        )
        let envelope = CGRect(origin: .zero, size: CGSize(width: 724, height: 252))

        for progress in stride(from: CGFloat(0), through: 1, by: 0.005) {
            let body = geometry.bodyFrame(in: envelope, progress: progress)
            let top = geometry.topRadius(progress: progress)
            let silhouette = CGRect(
                x: body.minX - top,
                y: body.minY,
                width: body.width + 2 * top,
                height: body.height
            )
            let radii = NotchShape(
                topRadius: top,
                bottomRadius: geometry.bottomRadius(progress: progress)
            ).resolvedRadii(in: silhouette)

            XCTAssertLessThanOrEqual(radii.top + radii.bottom, silhouette.height + 0.0001)
        }
    }

    func testOnlyExpandedContentIsInteractiveOrVisibleToAccessibility() {
        let collapsed = PanelContentAvailability(isExpanded: false)
        let expanded = PanelContentAvailability(isExpanded: true)

        XCTAssertFalse(collapsed.acceptsHitTesting)
        XCTAssertTrue(collapsed.isAccessibilityHidden)
        XCTAssertTrue(expanded.acceptsHitTesting)
        XCTAssertFalse(expanded.isAccessibilityHidden)
    }
}
