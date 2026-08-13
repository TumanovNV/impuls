import SwiftUI

/// The panel silhouette: concave shoulders that melt into the top edge of the
/// display, straight sides, rounded bottom. The body is inset by `topRadius`
/// on both sides, so the containing frame must be that much wider.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func resolvedRadii(in rect: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let top = max(0, min(topRadius, rect.width / 2, rect.height))
        let bottom = max(0, min(bottomRadius, rect.width / 2 - top, rect.height - top))
        return (top, bottom)
    }

    func path(in rect: CGRect) -> Path {
        let radii = resolvedRadii(in: rect)
        let tr = radii.top
        // The 12 pt synthetic anchor is shallower than its nominal two radii.
        // Keep each vertical side monotonic rather than letting the lower line
        // cross back above the shoulder on the first animation frame.
        let br = radii.bottom
        let left = rect.minX + tr
        let right = rect.maxX - tr

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + tr),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - br))
        path.addQuadCurve(
            to: CGPoint(x: left + br, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - br, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - br),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + tr))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// A panel silhouette moving inside the already-final window envelope.
///
/// The old transition animated the parent width and height. That fed every
/// intermediate size back into GeometryReader, the rails and the active pane,
/// turning one visual expansion into a full layout pass on every display tick.
/// This shape changes only its path. Content is laid out once at the final
/// expanded geometry and revealed through the path, so animation progress can
/// never become a new layout proposal.
struct NotchTransitionGeometry: Equatable {
    let collapsedSize: CGSize
    let expandedSize: CGSize

    func bodyFrame(in envelope: CGRect, progress suppliedProgress: CGFloat) -> CGRect {
        let progress = min(1, max(0, suppliedProgress))
        let width = collapsedSize.width + (expandedSize.width - collapsedSize.width) * progress
        let height = collapsedSize.height + (expandedSize.height - collapsedSize.height) * progress
        return CGRect(
            x: envelope.midX - width / 2,
            y: envelope.minY,
            width: width,
            height: height
        )
    }

    func topRadius(progress suppliedProgress: CGFloat) -> CGFloat {
        let progress = min(1, max(0, suppliedProgress))
        return Theme.collapsedTopRadius
            + (Theme.openTopRadius - Theme.collapsedTopRadius) * progress
    }

    func bottomRadius(progress suppliedProgress: CGFloat) -> CGFloat {
        let progress = min(1, max(0, suppliedProgress))
        return Theme.collapsedBottomRadius
            + (Theme.openBottomRadius - Theme.collapsedBottomRadius) * progress
    }
}

struct NotchTransitionShape: Shape {
    let geometry: NotchTransitionGeometry
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body = geometry.bodyFrame(in: rect, progress: progress)
        let topRadius = geometry.topRadius(progress: progress)
        let silhouette = CGRect(
            x: body.minX - topRadius,
            y: body.minY,
            width: body.width + 2 * topRadius,
            height: body.height
        )
        return NotchShape(
            topRadius: topRadius,
            bottomRadius: geometry.bottomRadius(progress: progress)
        ).path(in: silhouette)
    }
}
