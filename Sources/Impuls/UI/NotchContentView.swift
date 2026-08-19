import SwiftUI

struct PanelContentAvailability: Equatable {
    let isExpanded: Bool

    var acceptsHitTesting: Bool { isExpanded }
    var isAccessibilityHidden: Bool { !isExpanded }
}

struct NotchContentView: View {
    let vm: NotchViewModel
    /// This display's half of the state. The shared view model says whether
    /// Impuls is expanded; the surface says whether it is expanded *here*.
    /// Exactly one surface is active, so two panels cannot stand open at once —
    /// not by convention, but because the view has no way to draw the second.
    @ObservedObject var surface: NotchSurfaceState

    @ViewBuilder
    var body: some View {
        if surface.isActive {
            ActiveNotchContentView(
                vm: vm,
                geometry: surface.geometry,
                isOpen: surface.isExpanded,
                hasMountedContent: surface.hasMountedContent,
                motion: surface.motionPlan
            )
        } else {
            CollapsedNotchContentView(geometry: surface.geometry)
        }
    }
}

/// Inactive displays observe presentation only. They deliberately do not
/// observe the shared view model, so a media tick or device refresh for the one
/// open panel cannot invalidate every collapsed NSHostingView.
private struct CollapsedNotchContentView: View {
    let geometry: NotchGeometry

    var body: some View {
        NotchShape(
            topRadius: Theme.collapsedTopRadius,
            bottomRadius: Theme.collapsedBottomRadius
        )
        .fill(Color.black)
        .frame(
            width: geometry.collapsedSize.width + 2 * Theme.collapsedTopRadius,
            height: geometry.collapsedSize.height
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// The active surface keeps a final-size shell even while collapsed. The live
/// pane mounts only when expanded (some panes intentionally do work on appear),
/// but it is immediately proposed the final geometry: animation progress never
/// becomes a new layout proposal to the rails or pane hierarchy.
private struct ActiveNotchContentView: View {
    let vm: NotchViewModel
    let geometry: NotchGeometry
    let isOpen: Bool
    let hasMountedContent: Bool
    let motion: Theme.PanelMotionPlan
    @Environment(\.colorScheme) private var colorScheme
    private var envelopeSize: CGSize {
        CGSize(
            width: geometry.expandedSize.width + 2 * Theme.openTopRadius,
            height: geometry.expandedSize.height
        )
    }
    private var transitionGeometry: NotchTransitionGeometry {
        NotchTransitionGeometry(
            collapsedSize: geometry.collapsedSize,
            expandedSize: geometry.expandedSize
        )
    }

    var body: some View {
        let availability = PanelContentAvailability(isExpanded: isOpen)
        let reveal = NotchTransitionShape(
            geometry: transitionGeometry,
            progress: isOpen ? 1 : 0
        )

        ZStack(alignment: .top) {
            Color.black
            Theme.panelBackground
                .opacity(isOpen ? 1 : 0)

            ZStack {
                if hasMountedContent {
                    ZStack {
                        Theme.panelCanvas()
                            .allowsHitTesting(false)
                        ExpandedPanelContent(vm: vm, geometry: geometry)
                    }
                    .opacity(isOpen ? 1 : 0)
                    .animation(motion.contentAnimation(opening: isOpen), value: isOpen)
                }
            }
            // The wrapper changes immediately. An outgoing transition may
            // still be visible for a few frames, but it cannot retain a hidden
            // hit target or duplicate VoiceOver controls while it fades.
            .allowsHitTesting(availability.acceptsHitTesting)
            .accessibilityHidden(availability.isAccessibilityHidden)
        }
        .frame(width: envelopeSize.width, height: envelopeSize.height, alignment: .top)
        // Changing Reduce Motion while a transition is in flight replaces the
        // animatable mask at its semantic endpoint. That cancels the old
        // spatial transaction instead of letting its remaining frames travel.
        .mask(reveal.id(motion.reducesMotion))
        .shadow(
            color: .black.opacity(isOpen ? (colorScheme == .dark ? 0.5 : 0.2) : 0),
            radius: 18,
            y: 8
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(motion.geometryAnimation(opening: isOpen), value: isOpen)
    }

}

/// The only subtree that observes the shared model. It does not exist while
/// collapsed, so the idle active surface is as cheap as every inactive one and
/// hidden pane lifecycle hooks never run before the panel is visible.
private struct ExpandedPanelContent: View {
    @ObservedObject var vm: NotchViewModel
    let geometry: NotchGeometry

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(width: geometry.expandedSize.width, height: geometry.expandedSize.height, alignment: .top)
        .clipped()
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            Text(vm.title(for: vm.tab).uppercased())
                .font(Theme.Typo.overline)
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, Theme.Space.l)
                .id(vm.tab)
                .transition(.opacity)
                // The pane heading is announced by the rail button that
                // selected it; repeating it here would make VoiceOver read
                // the module name twice on every switch.
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Color.clear.frame(width: geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            trailing
                .padding(.trailing, Theme.Space.l)
                .transition(.opacity)
        }
        .frame(height: geometry.notchSize.height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch vm.tab {
        case .actions:
            EmptyView()
        case .media:
            HStack(spacing: Theme.Space.xs + 2) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.tertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                vm.media.isPlaying
                    ? localized("Playing in %@", vm.media.sourceName)
                    : vm.media.sourceName
            )
        case .shelf:
            counter(vm.shelf.items.count, noun: localized("files on the shelf"))
        case .clipboard:
            counter(vm.clipboard.items.count, noun: localized("clipboard entries"))
        case .snippets:
            counter(vm.snippets.items.count, noun: localized("snippets"))
        case .calendar:
            if let next = vm.calendar.next {
                Text(CalendarPane.countdown(to: next, from: vm.calendar.now))
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(next.isRunning ? Theme.primary.opacity(0.8) : Theme.tertiary)
            }
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .notes:
            NotesCounter(notes: vm.notes)
        case .power:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int, noun: String) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(Theme.Typo.captionDigits)
                .foregroundStyle(Theme.tertiary)
                .accessibilityLabel("\(value) \(noun)")
        }
    }

    // MARK: - Body

    private var content: some View {
        GeometryReader { geo in
            let buttonHeight = railButtonHeight(available: geo.size.height)
            // An empty rail is not rendered at all rather than rendered empty.
            // A `Rail` with no tabs still claimed its 30 pt of width plus the
            // stack's 12 pt of spacing, and still announced itself to
            // VoiceOver as a container with nothing in it. With a single
            // module enabled that was 42 pt of the panel spent on nothing.
            HStack(spacing: Theme.Space.m) {
                if !vm.leftRailTabs.isEmpty {
                    Rail(vm: vm, tabs: vm.leftRailTabs, side: .leading, buttonHeight: buttonHeight)
                }
                panes
                if !vm.rightRailTabs.isEmpty {
                    Rail(vm: vm, tabs: vm.rightRailTabs, side: .trailing, buttonHeight: buttonHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
    }

    /// How tall one rail icon may be, given the height this panel actually has.
    /// The arithmetic lives in `RailMetrics`, where the panel's minimum size is
    /// derived from the same numbers.
    private func railButtonHeight(available: CGFloat) -> CGFloat {
        RailMetrics.buttonHeight(
            available: available,
            count: max(vm.leftRailTabs.count, vm.rightRailTabs.count)
        )
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(paneTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Under Reduce Motion the panes still replace each other, but they do it
    /// by crossing over rather than by scaling: a scale is travel, an opacity
    /// change is not.
    private var paneTransition: AnyTransition {
        guard Theme.allowsRepeatingMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.97))
                .animation(Theme.paneIn),
            removal: .opacity
                .combined(with: .scale(scale: 1.02))
                .animation(Theme.paneOut)
        )
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .actions:
            ActionsPane(
                actions: vm.actions,
                clipboard: vm.clipboard,
                snippets: vm.snippets,
                notes: vm.notes,
                wantsKeyboard: $vm.wantsKeyboard,
                perform: { vm.perform($0, on: $1) }
            )
        case .media:
            MediaPane(media: vm.media)
        case .shelf:
            ShelfPane(shelf: vm.shelf, tools: vm.fileTools, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard)
        case .calendar:
            CalendarPane(calendar: vm.calendar)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, wantsKeyboard: $vm.wantsKeyboard)
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $vm.wantsKeyboard)
        case .notes:
            NotesPane(notes: vm.notes, wantsKeyboard: $vm.wantsKeyboard)
        case .power:
            PowerPane(power: vm.power, devices: vm.devices, settings: vm.settings)
        }
    }
}

/// Watches the note store itself rather than reading through the view model:
/// notes are born and deleted inside the pane while this counter is on
/// screen, and the view model deliberately does not forward keystroke-driven
/// stores.
private struct NotesCounter: View {
    @ObservedObject var notes: NoteStore

    var body: some View {
        if !notes.notes.isEmpty {
            Text("\(notes.notes.count)")
                .font(Theme.Typo.captionDigits)
                .foregroundStyle(Theme.tertiary)
                .accessibilityLabel("\(notes.notes.count) \(localized("notes"))")
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    enum Side { case leading, trailing }

    @ObservedObject var vm: NotchViewModel
    /// Which icons this rail carries — there are two rails now, one per side.
    let tabs: [NotchViewModel.Tab]
    let side: Side
    /// Fitted by the parent so both rails agree. See `railButtonHeight`.
    let buttonHeight: CGFloat

    @State private var hovered: NotchViewModel.Tab?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ForEach(tabs) { tab in
                RailButton(
                    tab: tab,
                    title: vm.title(for: tab),
                    symbol: vm.symbol(for: tab),
                    isSelected: vm.tab == tab,
                    isHovered: hovered == tab,
                    height: buttonHeight,
                    select: { vm.select(tab) },
                    hover: { inside in
                        if inside {
                            hovered = tab
                        } else if hovered == tab {
                            hovered = nil
                        }
                    }
                )
            }
        }
        .frame(width: Theme.Size.railWidth)
        .frame(maxHeight: .infinity, alignment: .center)
        .animation(Theme.motion(Theme.contentAnimation), value: hovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            side == .leading ? localized("Modules, left rail") : localized("Modules, right rail")
        )
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            vm.select(hovered, requestKeyboard: false)
        }
    }
}

/// One rail icon.
///
/// Split out of `Rail` so it can own its focus state: a keyboard user has to be
/// able to see which module the panel would switch to, and `@FocusState` has to
/// live beside the control it describes.
private struct RailButton: View {
    let tab: NotchViewModel.Tab
    let title: String
    let symbol: String
    let isSelected: Bool
    let isHovered: Bool
    let height: CGFloat
    let select: () -> Void
    let hover: (Bool) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: select) {
            Image(systemName: symbol)
                .font(Theme.Glyph.medium)
                .frame(width: Theme.Size.railWidth, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(fill)
                )
                .foregroundStyle(isSelected ? Theme.primary : Theme.tertiary)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                // A render-time transform. Growing the frame instead would
                // re-lay out the rail on every hover, and layout that runs on
                // pointer movement is exactly the kind that shows up as a
                // stutter. Suppressed under Reduce Motion, where a fill change
                // already carries the same information.
                .scaleEffect(isHovered && Theme.allowsRepeatingMotion ? 1.15 : 1)
                .notchFocusRing(isFocused, cornerRadius: Theme.Radius.small)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .help(title)
        .onHover(perform: hover)
        // The icon is the whole label, so without this VoiceOver reads nine
        // anonymous buttons. `.isSelected` is what tells it which one is open.
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Theme.surfaceHover }
        return isHovered ? Theme.surface : .clear
    }
}
