import SwiftUI

struct CalendarPane: View {
    @ObservedObject var calendar: CalendarStore

    var body: some View {
        switch calendar.access {
        case .notRequested:
            permissionPrompt
        case .denied:
            deniedState
        case .failed(let message):
            failedState(message)
        case .granted:
            if let next = calendar.next {
                agenda(next: next)
            } else {
                emptyState
            }
        }
    }

    // MARK: - Agenda

    private func agenda(next: CalendarStore.Meeting) -> some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Space.s - 1) {
                        Circle()
                            .fill(Color(next.calendarColor))
                            .frame(width: 7, height: 7)
                        Text(next.title)
                            .font(Theme.Typo.title)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                    }
                    Text(subtitle(for: next))
                        .font(Theme.Typo.label)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .padding(.top, Theme.Space.xs)
                        .padding(.leading, Theme.Space.m + 2)

                    Spacer(minLength: 10)

                    if next.link != nil {
                        Button {
                            calendar.join(next)
                        } label: {
                            HStack(spacing: Theme.Space.xs + 2) {
                                Image(systemName: "video.fill").font(Theme.Typo.caption)
                                Text(next.provider.map { localized("Join · %@", $0) } ?? localized("Join"))
                                    .font(Theme.Typo.labelStrong)
                            }
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, Theme.Space.s - 1)
                            .background(
                                Capsule().fill(next.isRunning ? Theme.primary.opacity(0.92) : Theme.surfaceHover)
                            )
                            .foregroundStyle(next.isRunning ? Theme.onPrimary : Theme.primary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, Theme.Space.m + 2)
                        .accessibilityLabel(
                            next.provider.map { localized("Join %@ meeting", $0) } ?? localized("Join")
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(localized("Next meeting"))

                rest(width: restWidth(in: geo.size.width))
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.top, Theme.Space.xs)
    }

    /// Everything after the next meeting, as a column on the right.
    private func rest(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s - 1) {
            ForEach(calendar.upcoming.prefix(4)) { meeting in
                HStack(spacing: Theme.Space.s - 1) {
                    Circle()
                        .fill(Color(meeting.calendarColor))
                        .frame(width: 5, height: 5)
                    Text(Self.clock.string(from: meeting.start))
                        .font(Theme.Typo.captionDigits)
                        .foregroundStyle(Theme.secondary)
                        .frame(width: Self.clockColumnWidth, alignment: .leading)
                        .opacity(Foundation.Calendar.current.isDateInToday(meeting.start) ? 1 : 0.6)
                    Text(meeting.title)
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            if calendar.upcoming.isEmpty {
                Text("No other meetings this week")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .leading)
    }

    /// A share of the pane rather than a fixed 230 pt: at the compact preset
    /// that flat number was 41% of the width and at the large one 33%, so the
    /// same layout read as two different designs depending on a setting that
    /// was only ever meant to change the outer size.
    ///
    /// Taken from the geometry the pane is laid out in rather than measured
    /// into `@State`. Storing a measurement costs a frame — the first pass has
    /// nothing stored, draws at a fallback and then snaps — and the clamp
    /// already covers a degenerate proposal, so no fallback constant is needed.
    private func restWidth(in paneWidth: CGFloat) -> CGFloat {
        min(260, max(180, paneWidth * 0.42))
    }

    private func subtitle(for meeting: CalendarStore.Meeting) -> String {
        var parts = [Self.day(for: meeting.start)].compactMap { $0 }
        parts.append("\(Self.clock.string(from: meeting.start))–\(Self.clock.string(from: meeting.end))")
        if let provider = meeting.provider { parts.append(provider) }
        return parts.joined(separator: " · ").sentenceCased
    }

    /// Clock time in the user's own hour cycle.
    ///
    /// This was a literal `"HH:mm"`, which forced 24-hour on every Mac —
    /// including every Mac whose region shows 2:30 PM. `j` is the hour field
    /// that resolves against the locale instead of overriding it, so the same
    /// call now yields "14:30" or "2:30 PM" depending on the setting the user
    /// actually made. The pattern is deliberately not a translatable key: the
    /// choice belongs to the region, not to the language of the interface.
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()

    /// Width of the time column in the upcoming list.
    ///
    /// A 12-hour locale needs room for "10:35 PM" where a 24-hour one needs
    /// only "22:35". Measured from a reference evening time rather than
    /// guessed, so the column is right in both without being padded in either.
    static let clockColumnWidth: CGFloat = {
        // Its own formatter, not a borrowed reference to `clock`: DateFormatter
        // is a class, and pinning the time zone on the shared one to take a
        // measurement would leave every meeting time rendered in UTC.
        let probe = DateFormatter()
        probe.locale = Locale.current
        probe.setLocalizedDateFormatFromTemplate("jmm")
        probe.timeZone = TimeZone(secondsFromGMT: 0)
        let sample = probe.string(from: Date(timeIntervalSince1970: 81_300)) // 22:35 UTC
        return sample.count > 5 ? 58 : 36
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage)
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter
    }()

    /// Nothing for today — the time alone says it. A word for tomorrow, a full
    /// date for anything further out.
    static func day(for date: Date) -> String? {
        let calendar = Foundation.Calendar.current
        if calendar.isDateInToday(date) { return nil }
        if calendar.isDateInTomorrow(date) { return localized("tomorrow") }
        return weekday.string(from: date)
    }

    /// "Через 12 мин" / "Идёт сейчас" — shown in the panel header, on its own,
    /// so it is a label and starts with a capital in either language.
    static func countdown(to meeting: CalendarStore.Meeting, from now: Date) -> String {
        phrase(to: meeting, from: now).sentenceCased
    }

    /// The wording alone, lower-case as the languages have it. Kept apart from
    /// the capital so the same phrases could stand mid-sentence one day.
    private static func phrase(to meeting: CalendarStore.Meeting, from now: Date) -> String {
        if meeting.isRunning { return localized("now") }
        let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return localized("any moment") }
        if minutes < 60 { return localized("in %d min", minutes) }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? localized("in %d h", hours) : localized("in %d h %d min", hours, rest)
        }
        let days = hours / 24
        return days == 1 ? localized("tomorrow") : localized("in %d d", days)
    }

    // MARK: - States

    private var permissionPrompt: some View {
        VStack(spacing: Theme.Space.s + 1) {
            Image(systemName: "calendar")
                .font(Theme.Glyph.hero)
                .foregroundStyle(Theme.tertiary)
            Text("See your next meetings")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(Theme.secondary)
            Text("Impuls needs access to Calendar. It is used only for this tab,\nand calendar data stays on this Mac.")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
            // Padding and background belong inside the label: with .plain the
            // hit area is the label itself, so decorating the Button from the
            // outside leaves a capsule that only responds on its lettering.
            Button {
                calendar.requestAccess()
            } label: {
                Text("Allow")
                    .font(Theme.Typo.labelStrong)
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, Theme.Space.m + 2)
                    .padding(.vertical, Theme.Space.xs + 2)
                    .background(Capsule().fill(Theme.surfaceHover))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.hair)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedState: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(Theme.Glyph.hero)
                .foregroundStyle(Theme.tertiary)
            Text("Calendar access is off")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(Theme.secondary)
            Text("Settings → Privacy → Calendars")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
            permissionButton("Open Calendar Settings") {
                calendar.openPrivacySettings()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: Theme.Space.s - 1) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(Theme.Glyph.hero)
                .foregroundStyle(Theme.tertiary)
            Text("Could not request Calendar access")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(Theme.secondary)
            Text(message)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            permissionButton("Try Again") {
                calendar.requestAccess()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func permissionButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, Theme.Space.m + 1)
                .padding(.vertical, Theme.Space.xs + 1)
                .background(Capsule().fill(Theme.surfaceHover))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark.circle")
                .font(Theme.Glyph.hero)
                .foregroundStyle(Theme.tertiary)
            Text("No more meetings")
                .font(Theme.Typo.bodyStrong)
                .foregroundStyle(Theme.secondary)
            Text("Nothing on the calendar for the next day")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
