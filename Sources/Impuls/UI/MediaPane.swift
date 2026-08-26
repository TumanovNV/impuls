import SwiftUI

struct MediaPane: View {
    @ObservedObject var media: MediaController

    @State private var scrubHover = false
    @State private var scrubbing: Double?

    private let blockHeight: CGFloat = 100

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            sourceBar
            if let track = media.track {
                player(track)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Source selection

    private var sourceBar: some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                Section(localized("Recommended")) {
                    ForEach(MusicProviderCatalog.recommended()) { source in
                        sourceMenuItem(source)
                    }
                }
                Section(localized("All Services")) {
                    ForEach(MusicProviderCatalog.allServices) { source in
                        sourceMenuItem(source)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: media.selectedSource.symbol)
                    Text(media.selectedSource.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Theme.Glyph.chevron)
                        .foregroundStyle(Theme.tertiary)
                }
                .font(Theme.Typo.labelSemibold)
                .foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 6)

            if media.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
            }

            Button(action: media.openSelectedSource) {
                Image(systemName: media.selectedSource.isWeb ? "globe" : "arrow.up.forward.app")
                    .font(Theme.Typo.captionSemibold)
            }
            .buttonStyle(NotchButtonStyle(size: 24))
            .help(media.selectedSource.isWeb ? localized("Open Web Player") : localized("Open %@", media.sourceName))
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private func sourceMenuItem(_ source: MusicSource) -> some View {
        Button {
            media.selectSource(source)
        } label: {
            if media.selectedSource == source {
                Label(source.displayName, systemImage: "checkmark")
            } else {
                Text(source.displayName)
            }
        }
    }

    // MARK: - Player

    private func player(_ track: MediaController.Track) -> some View {
        HStack(spacing: Theme.Space.l) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(Theme.Typo.title)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .accessibilityLabel("\(track.title), \(subtitle(for: track))")
                Text(subtitle(for: track))
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.top, Theme.Space.hair)
                    .accessibilityHidden(true)

                Spacer(minLength: 4)
                controls
                Spacer(minLength: 4)
                if media.duration > 0 {
                    scrubber
                } else {
                    Text(media.sourceName)
                        .font(Theme.Typo.captionStrong)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: blockHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.motion(Theme.artworkAnimation), value: track.key)
    }

    private func subtitle(for track: MediaController.Track) -> String {
        var parts = [track.artist]
        if !track.album.isEmpty, track.album != track.title { parts.append(track.album) }
        let subtitle = parts.filter { !$0.isEmpty }.joined(separator: " — ")
        return subtitle.isEmpty ? media.sourceName : subtitle
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.surface)
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: media.selectedSource.symbol)
                    .font(Theme.Glyph.artwork)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 9, y: 4)
        .accessibilityHidden(true)
        .animation(Theme.motion(Theme.artworkAnimation), value: media.artwork)
    }

    // MARK: - Scrubber

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard media.duration > 0 else { return 0 }
        return min(max(media.position / media.duration, 0), 1)
    }

    private var scrubber: some View {
        HStack(spacing: Theme.Space.s) {
            Text(formatTime(progress * media.duration))
                .frame(width: 30, alignment: .leading)

            GeometryReader { geo in
                let width = geo.size.width
                let filled = width * progress
                let height: CGFloat = scrubHover ? 6 : 4

                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface).frame(height: height)
                    Capsule()
                        .fill(Theme.primary.opacity(0.9))
                        .frame(width: filled, height: height)
                    if scrubHover {
                        Circle()
                            .fill(Theme.primary)
                            .frame(width: 11, height: 11)
                            .offset(x: min(max(filled - 5.5, 0), max(0, width - 11)))
                            .shadow(color: .black.opacity(0.35), radius: 3)
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { scrubHover = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            scrubbing = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard width > 0 else { return }
                            let target = min(max(value.location.x / width, 0), 1)
                            media.seek(to: media.duration * target)
                            scrubbing = nil
                        }
                )
                .animation(Theme.motion(Theme.contentAnimation), value: scrubHover)
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(localized("Playback position"))
            .accessibilityValue(
                localized("%@ of %@", formatTime(progress * media.duration), formatTime(media.duration))
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                // Five seconds a press: the same step the arrow keys give in
                // every system player, and small enough to land on a word.
                let step: TimeInterval = 5
                switch direction {
                case .increment: media.seek(to: min(media.duration, media.position + step))
                case .decrement: media.seek(to: max(0, media.position - step))
                @unknown default: break
                }
            }

            Text(formatTime(media.duration))
                .frame(width: 30, alignment: .trailing)
        }
        .font(Theme.Typo.captionDigits)
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: - Transport

    private var controls: some View {
        HStack(spacing: Theme.Space.l + 2) {
            Button { media.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(NotchButtonStyle(size: Theme.Size.control))
                .disabled(!media.capabilities.canPrevious)
                .accessibilityLabel(localized("Previous Track"))
                .help(localized("Previous Track"))
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(NotchButtonStyle(size: 36, prominent: true))
            .disabled(!media.capabilities.canPlayPause)
            .accessibilityLabel(media.isPlaying ? localized("Pause") : localized("Play"))
            .help(media.isPlaying ? localized("Pause") : localized("Play"))
            Button { media.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(NotchButtonStyle(size: Theme.Size.control))
                .disabled(!media.capabilities.canNext)
                .accessibilityLabel(localized("Next Track"))
                .help(localized("Next Track"))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 6) {
            if media.emptyReason == .webPlayerLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: media.accessIssue == nil ? media.selectedSource.symbol : "hand.raised")
                    .font(Theme.Glyph.hero)
                    .foregroundStyle(Theme.tertiary)
            }

            if let issue = media.accessIssue {
                Text(localized("Allow Automation access to read %@.", issue.app.displayName))
                    .font(Theme.Typo.labelStrong)
                    .foregroundStyle(Theme.secondary)
                Button(
                    issue.authorization == .notDetermined ? localized("Allow") : localized("Open Settings"),
                    action: media.resolveAutomationAccess
                )
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Text(emptyMessage)
                    .font(Theme.Typo.labelStrong)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                HStack(spacing: 7) {
                    if media.emptyReason != .nativeNotInstalled {
                        Button(primaryEmptyActionTitle, action: primaryEmptyAction)
                            .buttonStyle(.borderedProminent)
                    }
                    if media.emptyReason == .nativeUnreadable {
                        Button(localized("Open Settings"), action: media.openAutomationSettings)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch media.emptyReason {
        case .nativeNotInstalled:
            return localized("%@ is not installed.", media.sourceName)
        case .nativeNotRunning:
            return localized("Open %@ and start a track.", media.sourceName)
        case .nativeIdle:
            return localized("%@ is open, but no track is playing.", media.sourceName)
        case .nativeUnreadable:
            return localized("%@ is playing, but its track data could not be read.", media.sourceName)
        case .webPlayerNotOpen:
            return localized("Open the selected web player to sign in and choose music.")
        case .webPlayerLoading:
            return localized("Connecting to the selected web player…")
        case .webPlayerIdle:
            return localized("Choose a track in %@.", media.sourceName)
        case .webPlayerFailed:
            guard let error = media.webPlayerError else {
                return localized("%@ could not be loaded.", media.sourceName)
            }
            return localized("%@ could not be loaded: %@", media.sourceName, error)
        }
    }

    private var primaryEmptyActionTitle: String {
        switch media.emptyReason {
        case .nativeNotInstalled:
            return ""
        case .nativeNotRunning, .nativeIdle:
            return localized("Open %@", media.sourceName)
        case .nativeUnreadable:
            return localized("Try Again")
        case .webPlayerNotOpen:
            return localized("Open Web Player")
        case .webPlayerLoading, .webPlayerIdle:
            return localized("Show Web Player")
        case .webPlayerFailed:
            return localized("Try Again")
        }
    }

    private func primaryEmptyAction() {
        switch media.emptyReason {
        case .nativeUnreadable, .webPlayerFailed:
            media.retry()
        case .nativeNotInstalled:
            break
        case .nativeNotRunning, .nativeIdle, .webPlayerNotOpen, .webPlayerLoading, .webPlayerIdle:
            media.openSelectedSource()
        }
    }
}
