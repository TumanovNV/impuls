import SwiftUI

/// The Stay Awake strip at the foot of Power Center.
///
/// One row, three controls and a state readout, sitting under whichever Power
/// layout is showing. It is a strip rather than a card because Power Center was
/// not redesigned for it: the battery hero, the desktop hero and the device
/// navigator all keep the space they had, and this takes one row underneath
/// them at every preset.
///
/// The strip owns no assertion and no timer. It reads `StayAwakeService` and
/// sends it commands; the mode outlives this view, so folding the panel or
/// switching modules leaves the Mac awake exactly as the person asked.
struct PowerStayAwakeBar: View {
    @ObservedObject var stayAwake: StayAwakeService

    /// Whether this Mac is running on its own battery right now.
    ///
    /// Read from the snapshot `PowerMonitor` already publishes. There is no
    /// second power source and no new poll for this: a desktop Mac never
    /// reports it, so the caution never appears on one.
    let isOnBattery: Bool

    @FocusState private var focusedControl: Control?
    @State private var hoveredControl: Control?

    private enum Control: Hashable {
        case mode
        case display
    }

    /// Tall enough for two lines of caption in the status column, which is what
    /// "27 min left" plus the battery caution needs. Fixed rather than
    /// content-sized so the hero above it does not resize when the mode
    /// changes.
    private static let rowHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            modeChip
            durationMenu
            displayChip
            Spacer(minLength: Theme.Space.xs)
            status
        }
        .frame(height: Self.rowHeight)
        .padding(.horizontal, Theme.Space.xs)
        .animation(Theme.motion(Theme.contentAnimation), value: stayAwake.isActive)
    }

    // MARK: - Mode

    /// The quick control. One press turns the mode on with the duration already
    /// showing beside it, and one press turns it off again — the feature is not
    /// buried behind a menu or in Settings.
    private var modeChip: some View {
        Button {
            if stayAwake.isActive {
                stayAwake.turnOff()
            } else {
                stayAwake.turnOn(for: stayAwake.duration)
            }
        } label: {
            HStack(spacing: Theme.Space.xs + 1) {
                Image(systemName: stayAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(Theme.Glyph.medium)
                Text(localized("Stay Awake"))
                    .font(Theme.Typo.labelSemibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(stayAwake.isActive ? Theme.primary : Theme.secondary)
            .padding(.horizontal, Theme.Space.s)
            .frame(height: Theme.Size.touchTarget)
            .background(chipBackground(isOn: stayAwake.isActive, control: .mode))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .mode)
        .notchFocusRing(focusedControl == .mode, cornerRadius: Theme.Size.touchTarget / 2)
        .onHover { hovering in note(hovering: hovering, control: .mode) }
        .help(stayAwake.isActive ? localized("Turn Off") : localized("Stay Awake"))
        .accessibilityLabel(localized("Stay Awake"))
        .accessibilityValue(stayAwake.isActive ? localized("Enabled") : localized("Disabled"))
        .accessibilityHint(localized("Keeps this Mac from going to sleep"))
        .accessibilityAddTraits(stayAwake.isActive ? [.isSelected] : [])
    }

    // MARK: - Duration

    /// Choosing a duration while the mode is off turns it on with that
    /// duration, so picking "2 Hours" is one action rather than two. Choosing
    /// one while it is already on replaces the deadline without touching the
    /// assertion underneath.
    private var durationMenu: some View {
        Menu {
            ForEach(StayAwakeDuration.allCases) { option in
                Button {
                    stayAwake.turnOn(for: option)
                } label: {
                    if option == stayAwake.duration, stayAwake.isActive {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
            if stayAwake.isActive {
                Divider()
                Button(localized("Turn Off")) { stayAwake.turnOff() }
            }
        } label: {
            HStack(spacing: Theme.Space.xs - 1) {
                Text(stayAwake.duration.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.Glyph.chevron)
                    .foregroundStyle(Theme.tertiary)
            }
            .font(Theme.Typo.labelSemibold)
            .foregroundStyle(stayAwake.isActive ? Theme.secondary : Theme.tertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(localized("Duration"))
        .accessibilityValue(stayAwake.duration.title)
    }

    // MARK: - Display

    /// A separate, explicit choice. It is off at every activation and it is
    /// disabled while the mode is off, because "keep the display awake" with
    /// Stay Awake switched off would describe a state that does not exist —
    /// the display assertion only ever accompanies this mode's lease.
    private var displayChip: some View {
        Button {
            stayAwake.setKeepsDisplayAwake(!stayAwake.keepsDisplayAwake)
        } label: {
            Image(systemName: stayAwake.keepsDisplayAwake ? "sun.max.fill" : "sun.max")
                .font(Theme.Glyph.medium)
                .foregroundStyle(displayForeground)
                .frame(width: Theme.Size.touchTarget + 6, height: Theme.Size.touchTarget)
                .background(chipBackground(isOn: stayAwake.keepsDisplayAwake, control: .display))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!stayAwake.isActive)
        .focused($focusedControl, equals: .display)
        .notchFocusRing(focusedControl == .display, cornerRadius: Theme.Size.touchTarget / 2)
        .onHover { hovering in note(hovering: hovering, control: .display) }
        .help(localized("Keep Display Awake"))
        .accessibilityLabel(localized("Keep Display Awake"))
        .accessibilityValue(stayAwake.keepsDisplayAwake ? localized("Enabled") : localized("Disabled"))
        .accessibilityHint(localized("Also keeps the screen from turning off"))
        .accessibilityAddTraits(stayAwake.keepsDisplayAwake ? [.isSelected] : [])
    }

    private var displayForeground: Color {
        guard stayAwake.isActive else { return Theme.tertiary }
        return stayAwake.keepsDisplayAwake ? Theme.primary : Theme.secondary
    }

    // MARK: - Status

    /// The remaining-time readout repaints on a minute schedule, and only while
    /// a timed mode is actually running with this pane on screen. There is no
    /// process-wide timer behind the label: an untimed mode, an inactive mode
    /// and a folded panel all schedule nothing at all.
    @ViewBuilder
    private var status: some View {
        if stayAwake.isActive, stayAwake.duration.seconds != nil {
            TimelineView(.everyMinute) { _ in statusColumn }
        } else {
            statusColumn
        }
    }

    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let headline = statusHeadline {
                Text(headline)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(stayAwake.failure == nil ? Theme.secondary : Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let caution = batteryCaution {
                Text(caution)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .multilineTextAlignment(.trailing)
        .help(accessibilityStatus)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityStatus)
    }

    /// A failure outranks everything else: if the assertion could not be
    /// created there is nothing truthful to say about remaining time, and the
    /// mode is off.
    private var statusHeadline: String? {
        if let failure = stayAwake.failure { return failure.message }
        guard stayAwake.isActive else { return nil }
        guard let minutes = stayAwake.remainingMinutes else {
            return localized("Your Mac will stay awake")
        }
        return localized("Remaining %@", PowerTimeFormatter.string(for: .minutes(minutes)))
    }

    /// Neutral, and never a blocker. It states a fact about running on battery
    /// and nothing more — no modal, no confirmation, no disabled control.
    /// A Mac with no battery never reports `isOnBattery`, so a Mac mini or
    /// Studio never shows it.
    private var batteryCaution: String? {
        guard stayAwake.isActive, isOnBattery, stayAwake.failure == nil else { return nil }
        return localized("On battery this uses more power")
    }

    private var accessibilityStatus: String {
        [statusHeadline, batteryCaution].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: - Chrome

    /// The same three-state fill the Device Navigator rows use, so an engaged
    /// control here reads the way a selected device does rather than
    /// introducing a second visual language inside one pane.
    private func chipBackground(isOn: Bool, control: Control) -> some View {
        let fill: Color
        if isOn {
            fill = Theme.selection
        } else if hoveredControl == control {
            fill = Theme.surfaceHover
        } else {
            fill = Theme.surface
        }
        return Capsule()
            .fill(fill)
            .overlay(
                Capsule()
                    .strokeBorder(isOn ? Theme.selectionStroke : Color.clear, lineWidth: Theme.selectionStrokeWidth)
                    .allowsHitTesting(false)
            )
    }

    private func note(hovering: Bool, control: Control) {
        if hovering {
            hoveredControl = control
        } else if hoveredControl == control {
            hoveredControl = nil
        }
    }
}
