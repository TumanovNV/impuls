import AppKit
import Sparkle

private let impulsUpdateFeedURLString =
    "https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml"

/// Owns Impuls' explicit network-consent boundary while Sparkle handles the
/// authenticated download, atomic replacement, relaunch, and temporary-file
/// cleanup for application updates.
@MainActor
final class UpdateService {
    enum Consent: String, Sendable {
        case unknown, allowed, denied
    }

    private static let decisionRecordedKey = "updates.consentDecisionRecorded"
    private static let legacyConsentKey = "updates.networkConsent"

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        migrateLegacyConsentIfNeeded()
    }

    var consent: Consent {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.decisionRecordedKey) else { return .unknown }
        return updaterController.updater.automaticallyChecksForUpdates ? .allowed : .denied
    }

    var canCheckForUpdates: Bool {
        consent != .allowed || updaterController.updater.canCheckForUpdates
    }

    func requestConsentIfNeeded() {
        guard consent == .unknown,
              ProcessInfo.processInfo.environment["CI"] != "true" else { return }

        let alert = NSAlert()
        alert.messageText = localized("Allow Impuls to check for updates?")
        alert.informativeText = localized("If allowed, Impuls contacts only its signed GitHub update channel. It sends no notes, clipboard contents, files, calendar data, analytics, device identifiers, or system profile. An update is downloaded and installed only after your action.")
        alert.addButton(withTitle: localized("Allow Update Checks"))
        alert.addButton(withTitle: localized("Do Not Check"))

        let allowed = alert.runModal() == .alertFirstButtonReturn
        setNetworkAccess(allowed)
        if allowed, updaterController.updater.canCheckForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
    }

    func setNetworkAccess(_ allowed: Bool) {
        UserDefaults.standard.set(true, forKey: Self.decisionRecordedKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyConsentKey)
        updaterController.updater.automaticallyChecksForUpdates = allowed
    }

    func checkForUpdates() {
        guard consent == .allowed else {
            showOfflineAlert()
            return
        }
        updaterController.updater.checkForUpdates()
    }

    private func migrateLegacyConsentIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.decisionRecordedKey),
              let legacy = Self.legacyConsent(from: defaults.string(forKey: Self.legacyConsentKey)) else {
            return
        }

        updaterController.updater.automaticallyChecksForUpdates = legacy == .allowed
        defaults.set(true, forKey: Self.decisionRecordedKey)
        defaults.removeObject(forKey: Self.legacyConsentKey)
    }

    private func showOfflineAlert() {
        let alert = NSAlert()
        alert.messageText = localized("Update Checks Are Off")
        alert.informativeText = localized("Impuls is not allowed to access the internet. Enable update checks from the menu bar, then try again.")
        alert.runModal()
    }

    nonisolated static func isAllowedFeedURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https"
            && url.host == "github.com"
            && url.port == nil
            && url.path == "/TumanovNV/impuls/releases/latest/download/appcast.xml"
            && url.query == nil
            && url.fragment == nil
            && url.user == nil
            && url.password == nil
            && url.absoluteString == impulsUpdateFeedURLString
    }

    nonisolated static func legacyConsent(from rawValue: String?) -> Consent? {
        guard let rawValue,
              let consent = Consent(rawValue: rawValue),
              consent != .unknown else { return nil }
        return consent
    }
}
