import Combine
import Foundation

/// How long the person asked their Mac to stay awake.
enum StayAwakeDuration: String, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case untilTurnedOff

    var id: String { rawValue }

    /// `nil` means there is no deadline at all — the mode ends when the person
    /// ends it, or when Impuls quits.
    var seconds: TimeInterval? {
        switch self {
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .untilTurnedOff: return nil
        }
    }

    var title: String {
        switch self {
        case .thirtyMinutes: return localized("30 Minutes")
        // Reuses the key the clipboard retention picker already ships. It is
        // the same phrase meaning the same hour; a second key spelled
        // identically would be a translation waiting to drift.
        case .oneHour: return localized("1 Hour")
        case .twoHours: return localized("2 Hours")
        case .untilTurnedOff: return localized("Until Turned Off")
        }
    }
}

/// What went wrong the last time the person asked for something.
///
/// Bounded and local. It says which of the two requests failed and nothing
/// else: the `IOReturn` behind it is a diagnosis for a developer, not a number
/// to put in front of somebody, and there is no permission to ask for because
/// `IOPMAssertionCreateWithName` requires none.
enum StayAwakeFailure: Equatable {
    case couldNotTurnOn
    case couldNotKeepDisplayAwake

    var message: String {
        switch self {
        case .couldNotTurnOn: return localized("Could not turn on Stay Awake.")
        case .couldNotKeepDisplayAwake: return localized("Could not keep the display awake.")
        }
    }
}

/// Monotonic time, as a dependency.
///
/// Deliberately not `Date`. A person who changes their Mac's clock — or a Mac
/// that corrects itself against a time server — must not thereby turn a
/// thirty-minute request into five minutes or into four hours. `ContinuousClock`
/// is the standard monotonic clock for this and needs nothing hand-rolled
/// underneath it.
///
/// Injected so the timed modes can be tested in milliseconds rather than in
/// hours; a test that waits out a real two-hour deadline is a test nobody runs.
protocol StayAwakeClock: Sendable {
    var now: ContinuousClock.Instant { get }
}

struct SystemStayAwakeClock: StayAwakeClock {
    var now: ContinuousClock.Instant { ContinuousClock.now }
}

/// The single delayed wake-up a timed mode is allowed to own.
///
/// There is no repeating timer anywhere in this feature: the OS assertion is
/// what keeps the Mac awake, so nothing has to be re-asserted on a cadence.
/// This exists only so that a mode with a deadline can end itself, and it holds
/// at most one scheduled item at a time.
@MainActor
protocol StayAwakeExpiryScheduling: AnyObject {
    /// Replaces whatever was scheduled before. There is never a second item.
    func schedule(after interval: TimeInterval, _ body: @escaping @MainActor () -> Void)
    func cancel()
}

/// The production scheduler: one `DispatchWorkItem` on the main queue.
///
/// The same shape `AppDelegate` already uses for its one deferred prompt — a
/// cancellable one-shot rather than a `Timer`, because there is nothing
/// repeating to express and a work item cancels cleanly.
@MainActor
final class MainQueueStayAwakeExpiryScheduler: StayAwakeExpiryScheduling {
    private var work: DispatchWorkItem?

    func schedule(after interval: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, interval), execute: item)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// The manual "Stay Awake" mode: one explicit user lease and nothing else.
///
/// **Ownership.** The mode owns exactly one `WakeLeaseToken`. Turning the mode
/// off releases that token and only that token, so it can never cancel a claim
/// some other part of the app is holding, and no other release can cancel this
/// one. Aggregation into physical assertions is `WakeLeaseRegistry`'s job.
///
/// **Runtime only.** Nothing here is persisted. Quitting Impuls with the mode
/// on and launching it again leaves the mode off, on purpose: an energy
/// decision this consequential has to be re-made deliberately rather than
/// restored behind the person's back. There is no `UserDefaults` key to restore
/// from, so there is nothing that could grow into one.
///
/// **Not owned by a view.** This object lives with the other shared services in
/// `NotchViewModel`, so closing the Power pane or folding the panel leaves the
/// mode running. The only things that end it are the person, the deadline they
/// chose, disabling the Power module, and the app terminating.
@MainActor
final class StayAwakeService: ObservableObject {
    /// Whether a lease is genuinely held right now. It becomes `true` only
    /// after the system has actually granted the assertion, so the interface
    /// cannot claim the Mac is being kept awake when it is not.
    @Published private(set) var isActive = false

    /// The duration currently in force, or the last one that took effect. It
    /// is not persisted and resets with the process.
    @Published private(set) var duration: StayAwakeDuration = .thirtyMinutes

    /// Whether this lease also asks for the display. Off at every activation.
    @Published private(set) var keepsDisplayAwake = false

    /// The last failure, cleared by the next deliberate action.
    @Published private(set) var failure: StayAwakeFailure?

    private let leases: WakeLeaseRegistry
    private let clock: StayAwakeClock
    private let scheduler: StayAwakeExpiryScheduling

    private var token: WakeLeaseToken?

    /// The monotonic instant a timed mode ends. The clock — never the
    /// scheduler — is the authority on whether the mode is over.
    private var deadline: ContinuousClock.Instant?

    /// Retires superseded expiries. A wake-up scheduled for the thirty-minute
    /// mode the person has since replaced with two hours must not be able to
    /// end the newer mode, and the same guard covers a wake-up already in the
    /// queue when the mode was turned off by hand.
    private var expiryGeneration: UInt64 = 0

    init(
        leases: WakeLeaseRegistry,
        clock: StayAwakeClock = SystemStayAwakeClock(),
        scheduler: StayAwakeExpiryScheduling? = nil
    ) {
        self.leases = leases
        self.clock = clock
        // Constructed here rather than as a default argument: the scheduler is
        // main-actor isolated, and a default argument is evaluated outside the
        // initialiser's isolation.
        self.scheduler = scheduler ?? MainQueueStayAwakeExpiryScheduler()
    }

    // MARK: - Commands

    /// Turns the mode on, or changes the duration of a mode already running.
    ///
    /// Changing the duration keeps the same lease: the existing physical
    /// assertion is neither duplicated nor re-created, and the old deadline is
    /// replaced rather than left to fire later against the new one.
    func turnOn(for requestedDuration: StayAwakeDuration) {
        failure = nil

        if token != nil {
            duration = requestedDuration
            scheduleExpiry()
            return
        }

        do {
            token = try leases.acquire([.systemIdleSleep])
        } catch {
            // Nothing was acquired, so nothing is claimed. `isActive` stays
            // false and the interface says the mode is off, which is the truth.
            failure = .couldNotTurnOn
            return
        }

        // Every activation starts with the display option off. It is a
        // separate, explicit choice, and inheriting it from a previous session
        // would keep somebody's screen lit because of a decision they made an
        // hour ago in a different context.
        keepsDisplayAwake = false
        duration = requestedDuration
        isActive = true
        scheduleExpiry()
    }

    /// The person's explicit "off". Cancels the deadline and releases this
    /// mode's lease.
    func turnOff() {
        cancelExpiry()
        if let token {
            leases.release(token)
        }
        token = nil
        isActive = false
        keepsDisplayAwake = false
        failure = nil
    }

    /// Adds or removes the display requirement on the lease that already exists.
    ///
    /// Only meaningful while the mode is on: there is no state in which the
    /// display is being held awake but Stay Awake is off, so the interface
    /// disables this control rather than offering a switch that does nothing.
    ///
    /// A failure here costs nothing that was already working. The registry
    /// creates before it releases and commits nothing until every creation has
    /// succeeded, so a display assertion that cannot be created leaves the
    /// system assertion in place and this flag where it was.
    func setKeepsDisplayAwake(_ enabled: Bool) {
        guard let token, isActive, keepsDisplayAwake != enabled else { return }
        failure = nil

        var requirements: Set<WakeRequirement> = [.systemIdleSleep]
        if enabled { requirements.insert(.displayIdleSleep) }

        do {
            try leases.update(token, to: requirements)
        } catch {
            failure = .couldNotKeepDisplayAwake
            return
        }
        keepsDisplayAwake = enabled
    }

    /// Process teardown. Idempotent.
    ///
    /// Unlike `turnOff()`, this also empties the registry: the process is
    /// going away, so every assertion it owns should go with it rather than
    /// waiting for macOS to reap them. Normal termination releases explicitly;
    /// an abnormal death — a crash or a `kill` — is covered by macOS itself,
    /// because a power assertion belongs to the process that created it and
    /// dies with it. The second is a backstop, not a substitute for the first.
    func shutdown() {
        cancelExpiry()
        if let token {
            leases.release(token)
        }
        token = nil
        isActive = false
        keepsDisplayAwake = false
        failure = nil
        leases.releaseAll()
    }

    // MARK: - Reading

    /// Seconds left, or `nil` when the mode is off or has no deadline.
    var remainingSeconds: TimeInterval? {
        guard isActive, let deadline else { return nil }
        return max(0, seconds(until: deadline))
    }

    /// Whole minutes left, rounded up so a mode that is still running never
    /// reads as "0 min".
    var remainingMinutes: Int? {
        guard let remainingSeconds else { return nil }
        return max(1, Int((remainingSeconds / 60).rounded(.up)))
    }

    // MARK: - Expiry

    private func scheduleExpiry() {
        cancelExpiry()
        guard let seconds = duration.seconds else { return }
        deadline = clock.now.advanced(by: .seconds(seconds))
        armExpiry()
    }

    private func armExpiry() {
        guard let deadline else { return }
        expiryGeneration += 1
        let generation = expiryGeneration
        scheduler.schedule(after: max(0, seconds(until: deadline))) { [weak self] in
            self?.handleExpiry(generation: generation)
        }
    }

    private func handleExpiry(generation: UInt64) {
        guard generation == expiryGeneration, isActive, let deadline else { return }

        // The scheduler is a wake-up hint; the monotonic clock decides. They
        // can disagree — a dispatch deadline does not advance while the Mac is
        // asleep, and this mode only prevents *idle* sleep, so a lid close in
        // the middle of a two-hour request would otherwise stretch it. Waking
        // early re-arms for the remainder instead of ending the mode short,
        // and the remainder strictly shrinks, so this converges rather than
        // looping.
        guard seconds(until: deadline) <= 0 else {
            armExpiry()
            return
        }

        // Only this mode's own lease is released. Anything else the registry
        // is holding is somebody else's claim and is none of this deadline's
        // business.
        turnOff()
    }

    private func cancelExpiry() {
        // Advancing the generation retires a callback that is already queued
        // and cannot be taken back out of the queue.
        expiryGeneration += 1
        scheduler.cancel()
        deadline = nil
    }

    private func seconds(until instant: ContinuousClock.Instant) -> TimeInterval {
        let remaining = clock.now.duration(to: instant)
        let components = remaining.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
