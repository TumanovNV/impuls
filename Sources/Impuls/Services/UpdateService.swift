import AppKit

/// A data-task delegate is used instead of the completion-handler API so the
/// response budget is enforced while bytes arrive. A completion-handler task
/// would buffer an unknown-length response in full before Impuls could reject
/// it.
private final class UpdateSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct TaskState {
        var accumulator: BoundedDataAccumulator
        let completion: (Data?, URLResponse?, Error?) -> Void
    }

    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func register(
        _ task: URLSessionDataTask,
        completion: @escaping (Data?, URLResponse?, Error?) -> Void
    ) {
        lock.lock()
        states[task.taskIdentifier] = TaskState(
            accumulator: BoundedDataAccumulator(maximumBytes: maximumResponseBytes),
            completion: completion
        )
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(UpdateService.isAllowedAPIURL(request.url) ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              UpdateService.isAllowedAPIURL(http.url) else {
            finish(dataTask, data: nil, response: response, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > Int64(maximumResponseBytes) {
            finish(dataTask, data: nil, response: response, error: BoundedDataError.limitExceeded)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var state = states[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        do {
            try state.accumulator.append(data)
            states[dataTask.taskIdentifier] = state
            lock.unlock()
        } catch {
            states.removeValue(forKey: dataTask.taskIdentifier)
            lock.unlock()
            dataTask.cancel()
            state.completion(nil, dataTask.response, error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        state.completion(error == nil ? state.accumulator.data : nil, task.response, error)
    }

    private func finish(
        _ task: URLSessionDataTask,
        data: Data?,
        response: URLResponse?,
        error: Error
    ) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        state?.completion(data, response, error)
    }
}

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
        case responseTooLarge
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
            case .responseTooLarge:
                return localized("The update server response was unexpectedly large.")
            case .server(let statusCode):
                return localized("The update server returned HTTP status %d.", statusCode)
            }
        }
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }

    private static let consentKey = "updates.networkConsent"
    private static let releaseURL = URL(string: "https://api.github.com/repos/TumanovNV/impuls/releases/latest")!
    private static let maximumResponseBytes = 512 * 1_024

    private let sessionDelegate: UpdateSessionDelegate
    private let session: URLSession
    private var activeTask: URLSessionDataTask?
    private var checkGeneration = 0

    init() {
        let delegate = UpdateSessionDelegate(maximumResponseBytes: Self.maximumResponseBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldUsePipelining = true
        sessionDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

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
        if !allowed {
            checkGeneration += 1
            activeTask?.cancel()
            activeTask = nil
        }
    }

    func checkForUpdates(silentWhenCurrent: Bool = false) {
        guard consent == .allowed else {
            showOfflineAlert()
            return
        }
        guard activeTask == nil else { return }

        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Impuls/\(Bundle.main.shortVersion)", forHTTPHeaderField: "User-Agent")

        checkGeneration += 1
        let generation = checkGeneration
        let task = session.dataTask(with: request)
        sessionDelegate.register(task) { data, response, error in
            let result: Result<Release, Error>
            do {
                if error is BoundedDataError { throw UpdateError.responseTooLarge }
                if let error { throw error }
                guard let http = response as? HTTPURLResponse,
                      Self.isAllowedAPIURL(http.url) else {
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
                guard Self.isAllowedReleaseURL(release.htmlURL, tagName: release.tagName) else {
                    throw UpdateError.invalidResponse
                }
                result = .success(release)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.checkGeneration == generation else { return }
                self.activeTask = nil
                self.present(result, silentWhenCurrent: silentWhenCurrent)
            }
        }
        activeTask = task
        task.resume()
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

    nonisolated static func isAllowedAPIURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https"
            && url.host == "api.github.com"
            && url.port == nil
            && url.path == "/repos/TumanovNV/impuls/releases/latest"
            && url.query == nil
            && url.fragment == nil
            && url.user == nil
            && url.password == nil
    }

    nonisolated static func isAllowedReleaseURL(_ url: URL, tagName: String? = nil) -> Bool {
        guard url.scheme == "https",
              url.host == "github.com",
              url.port == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return false }

        let components = url.pathComponents
        guard components.count == 6,
              components[1] == "TumanovNV",
              components[2] == "impuls",
              components[3] == "releases",
              components[4] == "tag",
              !components[5].isEmpty else { return false }
        return tagName == nil || components[5] == tagName
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidate = semanticVersion(candidate),
              let current = semanticVersion(current) else { return false }
        for index in candidate.indices {
            if candidate[index] != current[index] {
                return candidate[index] > current[index]
            }
        }
        return false
    }

    private nonisolated static func semanticVersion(_ value: String) -> [Int]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(3)
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = Int(component),
                  number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }
}
