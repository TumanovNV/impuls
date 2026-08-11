import SwiftUI

/// Three sentences shown over the panel the first few times it is opened.
///
/// Nothing about this panel announces itself. It opens on a hover of a black
/// strip that looks like part of the hardware, it holds nine modules chosen
/// from two rails, and the global shortcut lands on a search field that is not
/// visible until it does. A user who is never told any of that concludes the
/// app is a music widget and removes it — which is what the feedback said.
///
/// Deliberately inside the panel rather than in a window of its own: a separate
/// window would have to be dismissed before the thing it describes could be
/// tried, and the gestures being described only exist here.
struct OnboardingOverlay: View {
    @AppStorage(Self.storageKey) private var completed = false
    @State private var step = 0

    static let storageKey = "impuls.onboarding.v1.completed"

    private struct Step {
        let symbol: String
        let title: String
        let detail: String
    }

    private var steps: [Step] {
        [
            Step(
                symbol: "cursorarrow.rays",
                title: localized("Hover the notch to open"),
                detail: localized("Move the pointer onto the strip at the top of the screen. Move it away and the panel folds back.")
            ),
            Step(
                symbol: "square.grid.2x2",
                title: localized("Modules live on the rails"),
                detail: localized("The columns of icons on both sides switch modules. Rest on one for a moment — a pointer passing through changes nothing.")
            ),
            Step(
                symbol: "tray.and.arrow.down",
                title: localized("Drop files, press the shortcut"),
                detail: localized("Drag a file onto the panel to put it on the shelf. The global shortcut opens search over your clipboard, snippets and notes.")
            ),
        ]
    }

    var body: some View {
        if !completed {
            card
                .transition(.opacity)
                .animation(Theme.motion(Theme.contentAnimation), value: step)
        }
    }

    private var card: some View {
        let current = steps[min(step, steps.count - 1)]
        return VStack(spacing: Theme.Space.s) {
            Image(systemName: current.symbol)
                .font(Theme.Glyph.hero)
                .foregroundStyle(Theme.secondary)

            Text(current.title)
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(Theme.primary)

            Text(current.detail)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.s) {
                // Dots, plus a written position for anyone who cannot see them.
                HStack(spacing: Theme.Space.xs) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index == step ? Theme.primary : Theme.surfaceHover)
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(localized("Step %d of %d", step + 1, steps.count))

                Spacer(minLength: Theme.Space.m)

                Button(localized("Skip")) { finish() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.tertiary)

                Button(step == steps.count - 1 ? localized("Done") : localized("Next")) {
                    if step == steps.count - 1 {
                        finish()
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Size.touchTarget)
                .background(
                    Capsule().fill(Theme.surfaceHover)
                )
                .contentShape(Capsule())
            }
            .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.l)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.panelBackground)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Getting started"))
    }

    private func finish() {
        completed = true
    }
}
