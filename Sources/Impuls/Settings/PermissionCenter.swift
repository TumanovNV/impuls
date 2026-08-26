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

        var title: String {
            switch self {
            case .allowed: return localized("Allowed")
            case .denied: return localized("Denied")
            case .notRequested: return localized("Not Requested")
            case .restricted: return localized("Restricted")
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
        guard app.isInstalled else {
            setAutomation(.restricted, for: app)
            return
        }
        PlayerBridge.automationAuthorization(for: app, prompt: false) { [weak self] authorization in
            guard let self else { return }
            self.updateAutomation(authorization, for: app)
        }
    }

    /// Kept separate from the TCC query so tests can prove target-app state
    /// isolation without invoking Automation or depending on an installed app.
    func updateAutomation(_ authorization: AutomationAuthorization, for app: PlayerApp) {
        let state: State = switch authorization {
            case .allowed: .allowed
            case .denied: .denied
            case .notDetermined: .notRequested
            case .restricted: .restricted
        }
        setAutomation(state, for: app)
    }

    private func setAutomation(_ state: State, for app: PlayerApp) {
        switch app {
        case .music: appleMusicAutomation = state
        case .spotify: spotifyAutomation = state
        }
    }
}
