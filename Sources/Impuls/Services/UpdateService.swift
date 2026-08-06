import AppKit

@MainActor
final class UpdateService {
    enum Consent: String {
        case unknown, allowed, denied
    }

    private enum UpdateError: LocalizedError {
        case channelUnavailable
        case accessDenied
        case rateLimited
        case invalidResponse
        case server(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .channelUnavailable:
                return localized("The public update channel is not available yet. Please try again later.")
            case .accessDenied:
                return localized("GitHub denied access to the update channel.")
            case .rateLimited:
                return localized("GitHub temporarily limited update checks. Please try again later.")
            case .invalidResponse:
                return localized("The update server returned an invalid response.")
            case .server(let statusCode):
                return localized("The update server returned HTTP status %d.", statusCode)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let name: String?
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name, body
        }
    }

    private static let consentKey = "updates.networkConsent"
    private static let releaseURL = URL(string: "https://api.github.com/repos/TumanovNV/impuls/releases/latest")!

    var consent: Consent {
        get { Consent(rawValue: UserDefaults.standard.string(forKey: Self.consentKey) ?? "") ?? .unknown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.consentKey) }
    }

    func requestConsentIfNeeded() {
        guard consent == .unknown,
              ProcessInfo.processInfo.environment["CI"] != "true" else { return }

        let alert = NSAlert()
        alert.messageText = localized("Allow Impuls to check for updates?")
        alert.informativeText = localized("If allowed, Impuls contacts only GitHub Releases to check the current version. It sends no notes, clipboard contents, files, calendar data, analytics, or device identifiers. Updates are never downloaded without your action.")
        alert.addButton(withTitle: localized("Allow Update Checks"))
        alert.addButton(withTitle: localized("Stay Offline"))
        consent = alert.runModal() == .alertFirstButtonReturn ? .allowed : .denied

        if consent == .allowed {
            checkForUpdates(silentWhenCurrent: true)
        }
    }

    func setNetworkAccess(_ allowed: Bool) {
        consent = allowed ? .allowed : .denied
    }

    func checkForUpdates(silentWhenCurrent: Bool = false) {
        guard consent == .allowed else {
            showOfflineAlert()
            return
        }

        var request = URLRequest(url: Self.releaseURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Impuls/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release, Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse else {
                    throw UpdateError.invalidResponse
                }

                switch http.statusCode {
                case 200:
                    break
                case 404:
                    throw UpdateError.channelUnavailable
                case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
                    throw UpdateError.rateLimited
                case 401, 403:
                    throw UpdateError.accessDenied
                default:
                    throw UpdateError.server(statusCode: http.statusCode)
                }

                guard let data else { throw UpdateError.invalidResponse }
                let release = try JSONDecoder().decode(Release.self, from: data)
                guard Self.isAllowedReleaseURL(release.htmlURL) else {
                    throw UpdateError.invalidResponse
                }
                result = .success(release)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                self?.present(result, silentWhenCurrent: silentWhenCurrent)
            }
        }.resume()
    }

    private func present(_ result: Result<Release, Error>, silentWhenCurrent: Bool) {
        switch result {
        case .failure(let error):
            guard !silentWhenCurrent else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = localized("Could Not Check for Updates")
            alert.informativeText = error.localizedDescription
            alert.runModal()

        case .success(let release):
            let available = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Self.isNewer(available, than: Bundle.main.shortVersion) else {
                guard !silentWhenCurrent else { return }
                let alert = NSAlert()
                alert.messageText = localized("Impuls Is Up to Date")
                alert.informativeText = localized("You are using the latest available version.")
                alert.runModal()
                return
            }

            let alert = NSAlert()
            alert.messageText = localized("Impuls %@ Is Available", available)
            let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            alert.informativeText = notes.isEmpty
                ? localized("A newer version is available. Nothing will be downloaded until you continue.")
                : String(notes.prefix(1_500))
            alert.addButton(withTitle: localized("Open Download Page"))
            alert.addButton(withTitle: localized("Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    private func showOfflineAlert() {
        let alert = NSAlert()
        alert.messageText = localized("Update Checks Are Off")
        alert.informativeText = localized("Impuls is not allowed to access the internet. You can enable update checks from the menu bar.")
        alert.runModal()
    }

    private static func isAllowedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com" else { return false }

        let expectedPrefix = "/TumanovNV/impuls/releases/"
        return url.path.hasPrefix(expectedPrefix)
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }
}
