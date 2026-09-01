import Foundation

/// Stable module identifiers exposed to system automation.
///
/// This deliberately mirrors product concepts rather than view/controller types.
/// App Intents can ask for one of these values, but never receives the shared
/// `NotchViewModel`, clipboard contents, device identities, file paths, or other
/// private runtime state.
public enum ImpulsAutomationModule: String, CaseIterable, Sendable {
    case actions
    case media
    case shelf
    case clipboard
    case snippets
    case calendar
    case translate
    case notes
    case power
}

/// Small, stable failure surface for system automation.
///
/// Raw system errors, paths, identifiers and provider diagnostics must not cross
/// this boundary. The App Intents layer maps these cases to localized dialogs.
public enum ImpulsAutomationError: String, Error, Equatable, Sendable {
    case moduleUnavailable
    case invalidInput
    case operationUnavailable
    case permissionRequired
    case serviceUnavailable
    case unsupportedOperation
}

/// The single bridge from system automation into the already-running Impuls
/// composition root.
///
/// A Shortcut can launch the app from a terminated state before `AppDelegate`
/// has finished constructing the authoritative `NotchController`. Callers wait
/// for that existing runtime for a bounded period instead of constructing a
/// second controller, view model, display graph or storage graph.
@MainActor
public final class ImpulsAutomationRuntime {
    public static let shared = ImpulsAutomationRuntime()

    public static let readinessTimeout: TimeInterval = 5
    public static let maximumSnippetTextBytes = 64 * 1_024
    public static let maximumSnippetTextCharacters = 16_384
    public static let maximumSnippetLabelBytes = 4 * 1_024
    public static let maximumSnippetLabelCharacters = 160

    struct Dependencies {
        let show: @MainActor () -> Bool
        let open: @MainActor (ImpulsAutomationModule) -> Bool
        let addSnippet: @MainActor (_ label: String, _ text: String) -> Bool
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Dependencies?, Never>
        let timeout: DispatchWorkItem
    }

    private var dependencies: Dependencies?
    private var waiters: [UUID: Waiter] = [:]

    private init() {}

    /// Installs adapters around the app's one authoritative controller.
    /// Called only by `AppDelegate` after normal composition has completed.
    func install(controller: NotchController) {
        install(
            Dependencies(
                show: { [weak controller] in
                    guard let controller, controller.viewModel != nil else { return false }
                    controller.open()
                    return true
                },
                open: { [weak controller] module in
                    guard let controller, let viewModel = controller.viewModel else { return false }
                    guard let tab = Self.tab(for: module), viewModel.visibleTabs.contains(tab) else { return false }
                    if tab == .power {
                        controller.openPower()
                    } else {
                        controller.open(tab: tab)
                    }
                    return true
                },
                addSnippet: { [weak controller] label, text in
                    guard let snippets = controller?.viewModel?.snippets else { return false }
                    snippets.add(label: label, text: text)
                    return true
                }
            )
        )
    }

    /// Test seam. Production installs through `install(controller:)` only.
    func install(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        let ready = Array(waiters.values)
        waiters.removeAll()
        for waiter in ready {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: dependencies)
        }
    }

    /// Clears only the automation bridge. It does not tear down any owner.
    func reset() {
        dependencies = nil
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: nil)
        }
    }

    public func show() async throws {
        guard let dependencies = await resolveDependencies() else {
            throw ImpulsAutomationError.serviceUnavailable
        }
        guard dependencies.show() else {
            throw ImpulsAutomationError.serviceUnavailable
        }
    }

    public func open(module: ImpulsAutomationModule) async throws {
        guard let dependencies = await resolveDependencies() else {
            throw ImpulsAutomationError.serviceUnavailable
        }
        guard dependencies.open(module) else {
            throw ImpulsAutomationError.moduleUnavailable
        }
    }

    public func addSnippet(text: String, label: String? = nil) async throws {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty,
              cleanText.utf8.count <= Self.maximumSnippetTextBytes,
              cleanText.count <= Self.maximumSnippetTextCharacters,
              cleanLabel.utf8.count <= Self.maximumSnippetLabelBytes,
              cleanLabel.count <= Self.maximumSnippetLabelCharacters else {
            throw ImpulsAutomationError.invalidInput
        }

        guard let dependencies = await resolveDependencies() else {
            throw ImpulsAutomationError.serviceUnavailable
        }
        guard dependencies.addSnippet(cleanLabel, cleanText) else {
            throw ImpulsAutomationError.serviceUnavailable
        }
    }

    /// One bounded wait, no polling. An ordinary cold launch gets a chance to
    /// finish `AppDelegate` composition; a genuinely missing runtime fails with
    /// `serviceUnavailable` after the deadline.
    private func resolveDependencies() async -> Dependencies? {
        if let dependencies { return dependencies }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            if let dependencies {
                continuation.resume(returning: dependencies)
                return
            }

            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let waiter = self.waiters.removeValue(forKey: id) else { return }
                    waiter.continuation.resume(returning: nil)
                }
            }
            waiters[id] = Waiter(continuation: continuation, timeout: timeout)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.readinessTimeout,
                execute: timeout
            )
        }
    }

    private static func tab(for module: ImpulsAutomationModule) -> NotchViewModel.Tab? {
        switch module {
        case .actions: return .actions
        case .media: return .media
        case .shelf: return .shelf
        case .clipboard: return .clipboard
        case .snippets: return .snippets
        case .calendar: return .calendar
        case .translate: return .translate
        case .notes: return .notes
        case .power: return .power
        }
    }
}
