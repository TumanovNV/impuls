import AppKit
import ApplicationServices
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
    @Published private(set) var accessibility: State = .notRequested
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
        accessibility = AXIsProcessTrusted() ? .allowed : .notRequested
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

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    func requestMusicAutomation() {
        let apps = PlayerApp.allCases.filter(\.isInstalled)
        requestMusicAutomation(apps, at: 0)
    }

    func openCalendarSettings() {
        openSettings("Privacy_Calendars")
    }

    func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
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
        let apps = PlayerApp.allCases.filter(\.isInstalled)
        guard !apps.isEmpty else {
            musicAutomation = .restricted
            return
        }

        var statuses: [AutomationAuthorization] = []
        let group = DispatchGroup()
        for app in apps {
            group.enter()
            PlayerBridge.automationAuthorization(for: app, prompt: false) { authorization in
                statuses.append(authorization)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if statuses.contains(.denied) {
                self.musicAutomation = .denied
            } else if statuses.contains(.notDetermined) {
                self.musicAutomation = .notRequested
            } else if statuses.allSatisfy({ $0 == .allowed }) {
                self.musicAutomation = .allowed
            } else {
                self.musicAutomation = .restricted
            }
        }
    }

    private func requestMusicAutomation(_ apps: [PlayerApp], at index: Int) {
        guard index < apps.count else {
            refreshMusicAutomation()
            return
        }
        PlayerBridge.automationAuthorization(for: apps[index], prompt: true) { [weak self] _ in
            self?.requestMusicAutomation(apps, at: index + 1)
        }
    }
}
