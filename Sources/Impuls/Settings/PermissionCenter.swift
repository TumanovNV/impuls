import AppKit
import EventKit
import UserNotifications

@MainActor
final class PermissionCenter: ObservableObject {
    enum State: Equatable {
        case allowed
        case denied
        case notRequested
        case restricted
        /// The target application is not on this Mac, so there is no TCC state
        /// to report and nothing to request.
        case notInstalled
        /// The application is installed but closed, so macOS cannot answer what
        /// the Automation state is. Distinct from `restricted`, which claims a
        /// policy block the user cannot lift; this one clears by itself as soon
        /// as the application is opened.
        case appNotRunning

        var title: String {
            switch self {
            case .allowed: return localized("Allowed")
            case .denied: return localized("Denied")
            case .notRequested: return localized("Not Requested")
            case .restricted: return localized("Restricted")
            case .notInstalled: return localized("Not Installed")
            case .appNotRunning: return localized("Not Running")
            }
        }
    }

    @Published private(set) var calendar: State = .notRequested
    @Published private(set) var appleMusicAutomation: State = .notRequested
    @Published private(set) var spotifyAutomation: State = .notRequested
    @Published private(set) var notifications: State = .notRequested

    private let eventStore = EKEventStore()

    func refresh() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: calendar = .allowed
        case .denied: calendar = .denied
        case .restricted, .writeOnly: calendar = .restricted
        case .notDetermined: calendar = .notRequested
        @unknown default: calendar = .restricted
        }
        refreshAutomation(for: .music)
        refreshAutomation(for: .spotify)

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: self.notifications = .allowed
                case .denied: self.notifications = .denied
                case .notDetermined: self.notifications = .notRequested
                @unknown default: self.notifications = .restricted
                }
            }
        }
    }

    func requestCalendar() {
        eventStore.requestFullAccessToEvents { [weak self] _, error in
            if let error { NSLog("Impuls: Calendar permission request failed: \(error.localizedDescription)") }
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAutomation(for app: PlayerApp) {
        guard app.isInstalled else { return }
        PlayerBridge.automationAuthorization(for: app, prompt: true) { [weak self] _ in
            self?.refreshAutomation(for: app)
        }
    }

    func requestNotifications() {
        Task { [weak self] in
            guard let self else { return }
            let current = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            guard current == .notDetermined else {
                refresh()
                return
            }
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                NSLog("Impuls: Notifications permission request failed: \(error.localizedDescription)")
            }
            refresh()
        }
    }

    func openCalendarSettings() {
        openSettings("Privacy_Calendars")
    }

    func openAutomationSettings() {
        openSettings("Privacy_Automation")
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func refreshAutomation(for app: PlayerApp) {
        // Resolved before TCC is consulted at all, so an app that is simply not
        // on this Mac can never be reported as a policy restriction — and no
        // Automation query is made for it.
        guard app.isInstalled else {
            setAutomation(Self.missingAppState, for: app)
            return
        }
        PlayerBridge.automationAuthorization(for: app, prompt: false) { [weak self] authorization in
            guard let self else { return }
            self.updateAutomation(authorization, for: app)
        }
    }

    /// The row state for a target application that is not installed. No TCC
    /// query is made for it, so it has no authorization to map.
    static let missingAppState: State = .notInstalled

    /// Pure so every row state can be proven without invoking Automation,
    /// installing an app or depending on what happens to be running.
    static func automationState(for authorization: AutomationAuthorization) -> State {
        switch authorization {
        case .allowed: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notRequested
        case .restricted: return .restricted
        case .undeterminedAppNotRunning: return .appNotRunning
        }
    }

    /// Kept separate from the TCC query so tests can prove target-app state
    /// isolation without invoking Automation or depending on an installed app.
    func updateAutomation(_ authorization: AutomationAuthorization, for app: PlayerApp) {
        setAutomation(Self.automationState(for: authorization), for: app)
    }

    private func setAutomation(_ state: State, for app: PlayerApp) {
        switch app {
        case .music: appleMusicAutomation = state
        case .spotify: spotifyAutomation = state
        }
    }
}
