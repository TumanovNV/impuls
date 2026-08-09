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
        case future

        var title: String {
            switch self {
            case .allowed: return localized("Allowed")
            case .denied: return localized("Denied")
            case .notRequested: return localized("Not Requested")
            case .restricted: return localized("Restricted")
            case .future: return localized("Planned")
            }
        }
    }

    @Published private(set) var calendar: State = .notRequested
    @Published private(set) var musicAutomation: State = .notRequested
    @Published private(set) var notifications: State = .future

    private let eventStore = EKEventStore()

    func refresh() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: calendar = .allowed
        case .denied: calendar = .denied
        case .restricted, .writeOnly: calendar = .restricted
        case .notDetermined: calendar = .notRequested
        @unknown default: calendar = .restricted
        }
        refreshMusicAutomation()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional: self.notifications = .allowed
                case .denied: self.notifications = .denied
                case .notDetermined: self.notifications = .future
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

    func requestMusicAutomation() {
        PlayerBridge.automationAuthorization(for: .music, prompt: true) { [weak self] _ in
            self?.refreshMusicAutomation()
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

    private func refreshMusicAutomation() {
        guard PlayerApp.music.isInstalled else {
            musicAutomation = .restricted
            return
        }
        PlayerBridge.automationAuthorization(for: .music, prompt: false) { [weak self] authorization in
            guard let self else { return }
            switch authorization {
            case .allowed: self.musicAutomation = .allowed
            case .denied: self.musicAutomation = .denied
            case .notDetermined: self.musicAutomation = .notRequested
            case .restricted: self.musicAutomation = .restricted
            }
        }
    }
}
