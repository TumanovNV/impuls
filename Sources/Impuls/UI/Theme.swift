import AppKit
import SwiftUI

/// The panel's design system.
///
/// Every size, radius, spacing step, colour and animation curve in the panel is
/// named here. Before this file carried scales, the numbers lived at the call
/// sites: 114 font declarations across 21 distinct point sizes, eight corner
/// radii and nineteen spacing values, none of them on a grid. A value invented
/// where it is used cannot be reviewed, and a panel assembled from unreviewed
/// values stops looking like one thing.
enum Theme {

    // MARK: - Accessibility
    //
    // Read fresh on every access rather than cached. These are user settings
    // that change while the app is running, and a cached copy would keep the
    // panel on whatever the setting was at launch.

    /// Movement that exists only as decoration must stop when this is on.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Blurred materials become an opaque canvas when this is on.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// Surfaces and separators step up a rung when this is on.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    // No `differentiateWithoutColor` here. It was declared during this pass and
    // then found to have nothing to apply to: every state in the panel that is
    // tinted also changes shape. The copy marks swap the glyph
    // (`justCopied ? "checkmark" : item.symbol`), the pin swaps `pin`/`pin.fill`,
    // the shelf status swaps triangle for check, the clipboard pause button
    // changes its own text, and the one remaining tint — the green commit mark
    // in the snippet editor — sits on a button that is already `.disabled`, so
    // the state reaches assistive technology through the trait rather than the
    // hue. A setting-reader with no reader is worse than no reader at all: it
    // reads as a guarantee the panel does not actually make.

    // MARK: - Motion

    static let openAnimation = Animation.spring(response: 0.27, dampingFraction: 0.82)
    static let contentAnimation = Animation.easeOut(duration: 0.16)
    /// Pane switching: the outgoing pane leaves faster than the incoming one
    /// arrives, so the two are never both half-visible for long.
    static let paneAnimation = Animation.easeOut(duration: 0.18)
    static let paneIn = Animation.easeOut(duration: 0.20).delay(0.04)
    static let paneOut = Animation.easeIn(duration: 0.12)
    static let artworkAnimation = Animation.easeOut(duration: 0.28)

    /// Passes an animation through, or drops it when Reduce Motion is on.
    ///
    /// Returns an Optional because that is what both `withAnimation` and
    /// `.animation(_:value:)` accept, and `nil` is precisely "apply the change
    /// without animating it" — the state still updates, it just arrives at once.
    static func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// A repeating animation has no honest non-animated form: it exists only to
    /// move. Callers use this to decide whether to draw the moving version at
    /// all, rather than to slow it down.
    static var allowsRepeatingMotion: Bool { !reduceMotion }

    // MARK: - Shape

    static let collapsedTopRadius: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 9
    static let openTopRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 22

    /// Corner radii for everything inside the panel. Three rungs: controls and
    /// rows, cards and fields, artwork and drop zones.
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// Spacing and padding, on a 4 pt grid. `hair` is the one deliberate
    /// exception — it separates a title from the line under it, where 4 pt
    /// already reads as a gap.
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// Row and control heights.
    enum Size {
        static let row: CGFloat = 26
        static let rowDetailed: CGFloat = 32
        /// A text field and the bar that stands in for one: the Actions and
        /// Snippets search rows, the Snippets add-editor, the New Note button.
        ///
        /// Deliberately its own name rather than a second use of `row`, even
        /// though the two agree today. They are different roles that happen to
        /// share a number, and whoever changes the height of a list row next
        /// should have to decide about fields on purpose rather than drag them
        /// along. The three were 26, 28 and 24 before this token existed.
        static let input: CGFloat = 26
        /// Footer strips: the shortest thing in the panel, and the one that has
        /// to give way first when the pane is squeezed.
        static let footer: CGFloat = 24
        /// A standalone button that is not in a row.
        static let control: CGFloat = 28
        /// Smallest square that still reads as a target for a glyph-only button.
        static let touchTarget: CGFloat = 22

        static let railWidth: CGFloat = 30
        /// The rail's button height is not a constant: it is fitted to the
        /// height the panel actually has. See `NotchContentView.railButtonHeight`.
        ///
        /// A fixed height was the bug behind icons falling out of the panel.
        /// What the rail has to live in is the panel height less the header and
        /// the bottom padding, and the header is the display's notch — 32 pt on
        /// a 14-inch MacBook Pro, more on other models, so the figure is not one
        /// number to design against. Six icons at a fixed 24 pt with 4 pt gaps
        /// need exactly the 164 pt that the standard preset happens to have
        /// there: it fit on some Macs and clipped the sixth icon on others, and
        /// raising the button to 28 pt for the sake of hit targets clipped it
        /// everywhere. Fitting the height, and splitting the rails evenly so
        /// five is the number to fit rather than six, is what removed the
        /// dependence on a number the app does not control.
        static let railButtonMax: CGFloat = 28
        /// Below this the rail would be denser than it is legible; it is better
        /// to let the last icon go than to keep shrinking.
        static let railButtonMin: CGFloat = 20
    }

    // MARK: - Type
    //
    // Six sizes, no more. Weight and monospaced digits vary within a size; the
    // size itself does not. Nothing here is below 10 pt: 10 is the smallest
    // text macOS itself ships, and the panel used to go down to 6.

    enum Typo {
        /// Battery percentage. The one number a glance is aimed at.
        static let hero = Font.system(size: 28, weight: .semibold).monospacedDigit()
        /// Section hero on a pane that has no single number.
        static let display = Font.system(size: 21, weight: .semibold)
        /// Track title, meeting title.
        static let title = Font.system(size: 15, weight: .semibold)
        /// Body copy and text editors.
        static let body = Font.system(size: 12)
        static let bodyStrong = Font.system(size: 12, weight: .medium)
        static let bodyDigits = Font.system(size: 12, weight: .semibold).monospacedDigit()
        /// The panel's workhorse: list rows, fields, buttons.
        static let label = Font.system(size: 11)
        static let labelStrong = Font.system(size: 11, weight: .medium)
        static let labelSemibold = Font.system(size: 11, weight: .semibold)
        /// Secondary detail, counters, footers.
        static let caption = Font.system(size: 10)
        static let captionStrong = Font.system(size: 10, weight: .medium)
        static let captionSemibold = Font.system(size: 10, weight: .semibold)
        static let captionDigits = Font.system(size: 10, weight: .medium).monospacedDigit()
        static let captionMono = Font.system(size: 10, weight: .medium).monospaced()
        /// Upper-cased headings. Always paired with `tracking(0.8)`.
        static let overline = Font.system(size: 10, weight: .semibold)
    }

    /// Glyph sizes. Kept apart from the type scale because an SF Symbol at
    /// 10 pt is not the same visual weight as text at 10 pt, and because an
    /// icon carries no reading load — it may go smaller than text may.
    enum Glyph {
        /// Disclosure marks. The one place a glyph may go below the type scale,
        /// because it carries direction and nothing else.
        static let chevron = Font.system(size: 8, weight: .semibold)
        static let medium = Font.system(size: 12, weight: .medium)
        static let large = Font.system(size: 18, weight: .light)
        static let largeStrong = Font.system(size: 18, weight: .medium)
        /// Empty-state and permission-prompt symbols.
        static let hero = Font.system(size: 22, weight: .light)
        static let heroStrong = Font.system(size: 22, weight: .medium)
        /// Stands in for missing artwork, at the size of the artwork itself.
        static let artwork = Font.system(size: 28, weight: .light)
    }

    // MARK: - Colour
    //
    // Semantic throughout. The panel supplies the dark or light canvas; a
    // control must never assume that canvas is black.

    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    /// Resting fill of a row, card or field.
    ///
    /// This used to be `quaternaryLabelColor.opacity(0.58)`. `quaternaryLabelColor`
    /// carries roughly a tenth of an alpha to begin with, so multiplying it left
    /// about 6% — and that 6% was the only thing on screen saying a clipboard row
    /// was a control at all. It is now the full quaternary rung, and steps up
    /// again under Increase Contrast.
    static var surface: Color {
        increaseContrast
            ? Color(nsColor: .tertiaryLabelColor).opacity(0.55)
            : Color(nsColor: .quaternaryLabelColor)
    }

    /// Hovered or selected fill. Always visibly above `surface`.
    static var surfaceHover: Color {
        increaseContrast
            ? Color(nsColor: .secondaryLabelColor).opacity(0.45)
            : Color(nsColor: .tertiaryLabelColor).opacity(0.55)
    }

    static var hairline: Color {
        increaseContrast
            ? Color(nsColor: .tertiaryLabelColor)
            : Color(nsColor: .separatorColor)
    }

    static let panelBackground = Color(nsColor: .windowBackgroundColor)
    static let onPrimary = Color(nsColor: .windowBackgroundColor)

    static var selection: Color {
        Color.accentColor.opacity(increaseContrast ? 0.30 : 0.16)
    }

    static var selectionStroke: Color {
        Color.accentColor.opacity(increaseContrast ? 0.85 : 0.48)
    }

    /// Focus ring for controls inside the panel.
    ///
    /// The panel deliberately suppresses AppKit's own focus ring — it is drawn
    /// for a key window and this panel is usually not one — but suppressing it
    /// and drawing nothing in its place left the panel with no keyboard
    /// affordance whatsoever.
    static let focusRing = Color.accentColor

    // MARK: - Panel canvas

    /// What fills the expanded panel.
    ///
    /// A blurred material rather than a flat `windowBackgroundColor`: this is a
    /// surface that hangs over arbitrary content, and an opaque fill reads as a
    /// hole cut in the screen. Reduce Transparency turns it back into the flat
    /// canvas, which is exactly what that setting is for.
    ///
    /// `NSVisualEffectView` rather than SwiftUI's `.ultraThinMaterial`: the
    /// panel is borderless, non-opaque and never key, and only the AppKit view
    /// lets us ask for `.behindWindow` blending explicitly. On macOS 26 and
    /// later the system renders these materials with its own Liquid Glass
    /// treatment, so this is also the forward-compatible choice — adopting
    /// `glassEffect` directly would require building against the macOS 26 SDK,
    /// which this project does not yet do.
    @ViewBuilder
    static func panelCanvas() -> some View {
        if reduceTransparency {
            panelBackground
        } else {
            VisualEffectCanvas(material: .hudWindow)
        }
    }
}

/// AppKit's blurred backdrop, as a SwiftUI layer.
struct VisualEffectCanvas: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // `.active` and not `.followsWindowActiveState`: this panel is
        // deliberately never the active window, and following that state would
        // leave the material permanently in its inactive, washed-out form.
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Flat button used for every control in the panel.
///
/// It draws its own focus ring: `.plain` and this style both suppress AppKit's,
/// and until now nothing replaced it, so a keyboard user had no way to see
/// where they were.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = Theme.Size.control
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        // The body is a real `View` rather than the configuration decorated in
        // place: `@Environment` declared on a `ButtonStyle` is never updated,
        // because a style is not a view and SwiftUI does not install a
        // dependency on it. Reading the focus state one level down works.
        StyleBody(configuration: configuration, size: size, prominent: prominent)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let prominent: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(prominent ? Theme.Typo.title : Theme.Typo.label)
                .foregroundStyle(Theme.primary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Theme.focusRing, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Circle())
                .animation(Theme.motion(.easeOut(duration: 0.12)), value: configuration.isPressed)
        }
    }
}

extension View {
    /// Tracks hover without triggering layout changes in the parent.
    func onHoverChange(_ action: @escaping (Bool) -> Void) -> some View {
        onHover(perform: action)
    }

    /// Draws the panel's focus ring around a control that is not a
    /// `NotchButtonStyle` button — a row, a field, a card.
    func notchFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.small) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.focusRing, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

func formatTime(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
