import AppKit
import SwiftUI

enum OnboardingPresentationDecision: Equatable {
    case full
    case whatsNew
    case none
}

/// Kept pure so an update cannot accidentally replay the first-run tour just
/// because a future settings field is missing or malformed.
enum OnboardingEligibility {
    static func decision(
        hasSettingsSnapshot: Bool,
        completedLegacyTour: Bool,
        completedCurrentTour: Bool,
        seenVersion: String?,
        currentVersion: String
    ) -> OnboardingPresentationDecision {
        let isFreshInstall = !hasSettingsSnapshot && !completedLegacyTour
        if isFreshInstall && !completedCurrentTour { return .full }
        guard !isFreshInstall, seenVersion != currentVersion else { return .none }
        return .whatsNew
    }
}

enum OnboardingTelemetryOfferEligibility {
    static func shouldShow(
        presentation: OnboardingPresentationDecision,
        consent: VersionTelemetryService.Consent,
        offerWasShown: Bool
    ) -> Bool {
        switch presentation {
        case .full:
            return true
        case .whatsNew:
            return consent == .unknown && !offerWasShown
        case .none:
            return false
        }
    }
}

/// Versioned onboarding state deliberately lives beside Settings rather than in
/// the panel. An update can identify itself without replaying a first-run tour,
/// and a person can reopen the complete tour later from Settings.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private enum Presentation {
        case full
        case whatsNew
    }

    static let completedKey = "impuls.onboarding.v2.completed"
    static let seenVersionKey = "impuls.onboarding.v2.seenVersion"
    static let telemetryOfferKey = "impuls.onboarding.1.4.11.telemetryOfferShown"

    private let settings: SettingsStore
    private let defaults: UserDefaults
    private let versionTelemetryService: VersionTelemetryService
    private let onOpenSettings: () -> Void
    private var window: NSWindow?
    private var activePresentation: Presentation?

    init(
        settings: SettingsStore,
        defaults: UserDefaults,
        versionTelemetryService: VersionTelemetryService,
        onOpenSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.defaults = defaults
        self.versionTelemetryService = versionTelemetryService
        self.onOpenSettings = onOpenSettings
    }

    func presentIfNeeded() {
        guard window == nil, let presentation = automaticPresentation else { return }
        show(presentation)
    }

    func showFullTour() {
        show(.full)
    }

    private var automaticPresentation: Presentation? {
        switch OnboardingEligibility.decision(
            hasSettingsSnapshot: defaults.data(forKey: SettingsStore.storageKey) != nil,
            completedLegacyTour: defaults.bool(forKey: "impuls.onboarding.v1.completed"),
            completedCurrentTour: defaults.bool(forKey: Self.completedKey),
            seenVersion: defaults.string(forKey: Self.seenVersionKey),
            currentVersion: Bundle.main.shortVersion
        ) {
        case .full: return .full
        case .whatsNew: return .whatsNew
        case .none: return nil
        }
    }

    private func show(_ presentation: Presentation) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let flow = OnboardingFlow(
            presentation: presentation == .full ? .full : .whatsNew,
            settings: settings,
            telemetryService: versionTelemetryService,
            showsTelemetryOffer: OnboardingTelemetryOfferEligibility.shouldShow(
                presentation: presentation == .full ? .full : .whatsNew,
                consent: versionTelemetryService.consent,
                offerWasShown: defaults.bool(forKey: Self.telemetryOfferKey)
            ),
            onTelemetryOffer: { [weak self] in
                self?.defaults.set(true, forKey: Self.telemetryOfferKey)
            },
            onFinish: { [weak self] selectedPresentation in
                self?.finish(selectedPresentation)
            },
            onOpenSettings: onOpenSettings
        )
        let hosting = NSHostingController(rootView: flow)
        let window = NSWindow(contentViewController: hosting)
        window.title = localized("Welcome to Impuls")
        window.minSize = NSSize(width: 620, height: 520)
        window.setContentSize(NSSize(width: 680, height: 560))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window
        activePresentation = presentation
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finish(_ presentation: OnboardingFlow.Presentation) {
        if presentation == .full {
            defaults.set(true, forKey: Self.completedKey)
        }
        defaults.set(Bundle.main.shortVersion, forKey: Self.seenVersionKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing an automatic update note should not make the full tour come
        // back. A first-run window closed with its standard close button is
        // also an explicit dismissal, so it must act like Skip rather than
        // trapping a person in the same tour at every launch.
        if activePresentation == .full {
            defaults.set(true, forKey: Self.completedKey)
        }
        defaults.set(Bundle.main.shortVersion, forKey: Self.seenVersionKey)
        window = nil
        activePresentation = nil
    }
}

struct OnboardingFlow: View {
    enum Presentation: Equatable {
        case full
        case whatsNew
    }

    private enum Step: Int, CaseIterable {
        case welcome
        case features
        case menuBar
        case quickActions
        case permissions
        case privacy
        case ready
    }

    let presentation: Presentation
    @ObservedObject var settings: SettingsStore
    let telemetryService: VersionTelemetryService
    let showsTelemetryOffer: Bool
    let onTelemetryOffer: () -> Void
    let onFinish: (Presentation) -> Void
    let onOpenSettings: () -> Void
    @State private var step: Step = .welcome
    @State private var telemetryChoice: VersionTelemetryService.Consent = .unknown

    var body: some View {
        VStack(spacing: 0) {
            if presentation == .full {
                progress
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
            Divider()
            controls
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { telemetryChoice = telemetryService.consent }
    }

    @ViewBuilder
    private var content: some View {
        if presentation == .whatsNew {
            whatsNew
        } else {
            switch step {
            case .welcome: welcome
            case .features: features
            case .menuBar: menuBar
            case .quickActions: quickActions
            case .permissions: permissions
            case .privacy: privacy
            case .ready: ready
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                .accessibilityLabel(localized("Onboarding progress"))
                .accessibilityValue(localized("Step %d of %d", step.rawValue + 1, Step.allCases.count))
            Text(localized("Step %d of %d", step.rawValue + 1, Step.allCases.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var welcome: some View {
        OnboardingPage(
            symbol: "sparkles",
            title: localized("Welcome to Impuls"),
            detail: localized("A focused workspace around your Mac’s notch. Your files, notes, clipboard and preferences stay on this Mac.")
        )
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "square.grid.2x2",
                title: localized("Choose what helps today"),
                detail: localized("Impuls is a local toolkit. These are real modules you can turn on, arrange and open from the panel or Menu Bar.")
            )
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                ForEach(featureCards) { feature in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: feature.symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                        Text(feature.title).font(.headline)
                        Text(feature.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var menuBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "menubar.rectangle",
                title: localized("Make the Menu Bar yours"),
                detail: localized("Choose an initial workspace. You can change its status item, widgets and quick actions at any time in Settings → Menu Bar.")
            )
            Picker(localized("Menu Bar Preset"), selection: Binding(
                get: { settings.menuBarWorkspace.preset },
                set: { settings.applyMenuBarWorkspacePreset($0) }
            )) {
                ForEach(MenuBarWorkspacePreset.allCases.filter { $0 != .custom }) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.radioGroup)
            .accessibilityHint(localized("Sets an initial Menu Bar workspace without enabling any permission or network feature."))
            MenuBarWorkspacePreview(configuration: settings.menuBarWorkspace)
                .padding(.top, 2)
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "command",
                title: localized("Keep up to four actions close"),
                detail: localized("Select none to four quick actions. Their order is the order shown in the Menu Bar; the fixed footer remains available separately.")
            )
            ForEach(AppFeatureCatalog.quickActions) { action in
                quickActionRow(action)
            }
        }
    }

    private func quickActionRow(_ action: MenuBarQuickAction) -> some View {
        let selected = settings.menuBarWorkspace.quickActions.contains(action)
        let index = settings.menuBarWorkspace.quickActions.firstIndex(of: action)
        return HStack(spacing: 12) {
            Image(systemName: action.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(action.title)
            Spacer()
            Toggle(action.title, isOn: Binding(
                get: { selected },
                set: { enabled in
                    settings.updateMenuBarWorkspace { configuration in
                        if enabled {
                            guard configuration.quickActions.count < MenuBarWorkspaceConfiguration.maximumQuickActions else { return }
                            configuration.quickActions.append(action)
                        } else {
                            configuration.quickActions.removeAll { $0 == action }
                        }
                        configuration.preset = .custom
                    }
                }
            ))
            .labelsHidden()
            .disabled(!selected && settings.menuBarWorkspace.quickActions.count >= MenuBarWorkspaceConfiguration.maximumQuickActions)
            if let index {
                Button {
                    settings.updateMenuBarWorkspace { configuration in
                        guard index > 0 else { return }
                        configuration.quickActions.swapAt(index, index - 1)
                        configuration.preset = .custom
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .accessibilityLabel(localized("Move Up"))
                Button {
                    settings.updateMenuBarWorkspace { configuration in
                        guard index < configuration.quickActions.count - 1 else { return }
                        configuration.quickActions.swapAt(index, index + 1)
                        configuration.preset = .custom
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == settings.menuBarWorkspace.quickActions.count - 1)
                .accessibilityLabel(localized("Move Down"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var permissions: some View {
        OnboardingPage(
            symbol: "hand.raised",
            title: localized("Permissions stay in your control"),
            detail: localized("Impuls asks only when you use a related feature: Calendar for upcoming events, Automation for Apple Music controls, and notifications only for a future optional reminder. This tour never opens a system permission dialog.")
        )
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "lock.shield",
                title: localized("Help improve Impuls — only if you choose"),
                detail: localized("Version statistics are separate from feedback and updates. They are off until you explicitly allow them, and ‘Not now’ keeps the decision unknown so you can choose later.")
            )
            telemetryOffer
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "checkmark.circle",
                title: localized("You’re ready"),
                detail: localized("Open the panel from the Menu Bar, hover the notch when hover activation is enabled, or use your global shortcut. Reopen this tour from Settings → Menu Bar whenever you want a refresher.")
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("Your Menu Bar"))
                    .font(.headline)
                Text(localized("Preset: %@", settings.menuBarWorkspace.preset.title))
                Text(localized("Status Item: %@", settings.menuBarWorkspace.statusMode.title))
                Text(settings.menuBarWorkspace.quickActions.isEmpty
                    ? localized("Quick Actions: None")
                    : localized("Quick Actions: %@", settings.menuBarWorkspace.quickActions.map(\.title).joined(separator: ", ")))
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingPageHeader(
                symbol: "menubar.rectangle",
                title: localized("What’s new in Impuls 1.4.11"),
                detail: localized("The Menu Bar is now a configurable workspace: choose a status mode, one or two live widgets, and up to four quick actions. Existing settings and permissions were kept unchanged.")
            )
            Button(localized("Open Menu Bar Settings")) {
                onOpenSettings()
                onFinish(presentation)
            }
            .buttonStyle(.bordered)
            if showsTelemetryOffer {
                Divider()
                telemetryOffer
            }
        }
    }

    private var telemetryOffer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("If enabled, Impuls sends a pseudonymous installation identifier, the app version and the previous version only when it is already known."))
                .font(.callout)
            Text(localized("It never sends clipboard contents, notes, screenshots, files, calendar content, documents or feature-use history."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Link(localized("Read the Privacy Policy"), destination: URL(string: "https://tumanovnv.github.io/impuls/site-privacy.html")!)
                .accessibilityHint(localized("Opens the privacy policy in your default browser."))
            HStack(spacing: 12) {
                Button(localized("Not now")) {
                    telemetryChoice = .unknown
                    onTelemetryOffer()
                }
                .buttonStyle(.bordered)
                Button(localized("Allow Version Statistics")) {
                    telemetryChoice = .allowed
                    telemetryService.setConsent(.allowed)
                    onTelemetryOffer()
                }
                .buttonStyle(.bordered)
                .disabled(!telemetryService.isEndpointConfigured)
            }
            .controlSize(.large)
            Text(telemetryService.isEndpointConfigured
                ? localized("This choice changes no other setting. Impuls will use the configured collector only after you explicitly allow it.")
                : localized("Version statistics are unavailable in this local build because no collector endpoint is configured. You can still decide later in Settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack {
            if presentation == .full, step != .welcome {
                Button(localized("Back")) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if presentation == .full, step != .ready {
                Button(localized("Skip Tour")) { onFinish(presentation) }
                    .buttonStyle(.bordered)
            }
            Button(presentation == .whatsNew || step == .ready ? localized("Done") : localized("Continue")) {
                guard presentation == .full, step != .ready else {
                    onFinish(presentation)
                    return
                }
                step = Step(rawValue: step.rawValue + 1) ?? .ready
            }
            .buttonStyle(.bordered)
        }
    }

    private var featureCards: [AppFeature] { AppFeatureCatalog.all }
}

private struct OnboardingPage: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        OnboardingPageHeader(symbol: symbol, title: title, detail: detail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 50)
    }
}

private struct OnboardingPageHeader: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
