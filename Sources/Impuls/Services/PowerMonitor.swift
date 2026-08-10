import Foundation

@MainActor
final class PowerMonitor: ObservableObject {
    @Published private(set) var snapshot = PowerSnapshot.unavailableDesktop

    private let provider: PowerSourceProviding
    private let observer: PowerSourceObserving?
    private var timer: Timer?
    private var isEnabled = false
    private var isActive = false
    private var isStarted = false

    init() {
        let provider = IOKitPowerSourceProvider()
        self.provider = provider
        observer = provider
    }

    init(provider: PowerSourceProviding) {
        self.provider = provider
        observer = provider as? PowerSourceObserving
    }

    /// The module setting is the ownership boundary: disabled means neither
    /// IOKit observation nor a live timer exists in this process.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        enabled ? start() : stop()
    }

    func start() {
        guard isEnabled, !isStarted else { return }
        isStarted = true
        refresh()
        observer?.startObserving { [weak self] in self?.refresh() }
        if isActive { startTimer() }
    }

    func stop() {
        stopTimer()
        observer?.stopObserving()
        isStarted = false
        isActive = false
    }

    /// Fast refreshes are useful only while a person can see changing current,
    /// voltage and power. Source changes still arrive by IOKit notification
    /// while the module is enabled but the panel is folded.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        guard isStarted, active else {
            stopTimer()
            return
        }
        refresh()
        startTimer()
    }

    func refresh() {
        guard isStarted else { return }
        let fresh = provider.snapshot()
        if fresh != snapshot { snapshot = fresh }
    }

    var isLiveMonitoring: Bool { timer != nil }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
