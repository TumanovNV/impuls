import SwiftUI

/// Placeholder shown while artwork is on its way. The system publishes the new
/// title before it has fetched the new cover, so without this the panel would
/// sit on an empty grey square for a moment on every track change.
struct SkeletonBox: View {
    var cornerRadius: CGFloat = Theme.Radius.large
    @State private var sweep = false

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
                    .opacity(Theme.allowsRepeatingMotion ? 1 : 0)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            guard Theme.allowsRepeatingMotion else { return }
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
    @State private var up = false

    private let low: [CGFloat] = [4, 7, 5]
    private let high: [CGFloat] = [10, 3, 8]

    /// Whether the bars travel. Never whether they are up.
    private var moves: Bool { isAnimating && Theme.allowsRepeatingMotion }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Theme.tertiary)
                    .frame(width: 2, height: up ? high[index] : low[index])
                    .animation(
                        moves
                            ? .easeInOut(duration: 0.44)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.12)
                            : Theme.motion(.easeOut(duration: 0.2)),
                        value: up
                    )
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityHidden(true)
        .onAppear { up = isAnimating }
        .onChange(of: isAnimating) { _, playing in up = playing }
    }
}
