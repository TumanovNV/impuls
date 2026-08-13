import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = Theme.Radius.large
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    // Semantic rather than white: the panel follows the user's
                    // appearance, and a white sweep over a light canvas is
                    // invisible. `primary` at a low alpha reads as a highlight
                    // in dark mode and as a shadow in light — both say "busy".
                    LinearGradient(
                        colors: [.clear, Theme.primary.opacity(0.10), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.55)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.55)
                    // Reduce Motion keeps the placeholder, drops the travel:
                    // the shape still says "not loaded yet", which is the
                    // information. The sweep was only ever the decoration.
                    .opacity(reduceMotion ? 0 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            updateSweep(reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, reduced in updateSweep(reduceMotion: reduced) }
    }

    private func updateSweep(reduceMotion: Bool) {
        if reduceMotion {
            withAnimation(nil) { sweep = false }
        } else {
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                sweep = true
            }
        }
    }
}

/// Three bars that breathe while something is playing — a glanceable "live"
/// marker next to the source name.
///
/// Under Reduce Motion the bars stop but do not disappear: they hold the
/// playing shape at rest, so the marker still distinguishes playing from
/// paused. A perpetually moving element beside a text label is exactly what
/// that setting exists to remove.
///
/// The split that makes that true: `up` is the state and follows `isAnimating`
/// alone, while `moves` chooses only the curve that carries `up` to its new
/// value. Folding the setting into the state instead — `up = moves` — is what
/// this used to do, and it left both states resting on the same low shape, so
/// Reduce Motion removed the information along with the movement.
struct EqualizerBars: View {
    var isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let low: [CGFloat] = [4, 7, 5]
    private let high: [CGFloat] = [10, 3, 8]
    private var phase: RepeatingMotionPhase {
        RepeatingMotionPhase(isAnimating: isAnimating, reducesMotion: reduceMotion)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                EqualizerBar(
                    low: low[index],
                    high: high[index],
                    phase: phase,
                    delay: Double(index) * 0.12
                )
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityHidden(true)
        // The identity contains Reduce Motion and playback state. A runtime
        // toggle therefore removes the old repeatForever transaction and
        // constructs fresh static or moving bars with fresh @State.
        .id(phase)
    }
}

struct RepeatingMotionPhase: Hashable {
    let isAnimating: Bool
    let reducesMotion: Bool
    var moves: Bool { isAnimating && !reducesMotion }
}

private struct EqualizerBar: View {
    let low: CGFloat
    let high: CGFloat
    let phase: RepeatingMotionPhase
    let delay: TimeInterval
    @State private var raised = false

    var body: some View {
        Capsule()
            .fill(Theme.tertiary)
            .frame(width: 2, height: raised ? high : low)
            .onAppear {
                if phase.moves {
                    withAnimation(
                        .easeInOut(duration: 0.44)
                            .repeatForever(autoreverses: true)
                            .delay(delay)
                    ) {
                        raised = true
                    }
                } else {
                    raised = phase.isAnimating
                }
            }
    }
}
