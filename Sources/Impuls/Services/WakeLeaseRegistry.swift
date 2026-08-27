import Foundation

/// One owner's claim on the Mac staying awake.
///
/// A token rather than a `Bool` because there is more than one possible owner
/// and a shared flag cannot say who set it. With a flag, the manual mode
/// turning off would also cancel whatever else had asked for the same thing,
/// and whichever of them released last would decide the outcome. A token means
/// releasing acts on exactly one claim and leaves every other one alone.
///
/// The value is created by `WakeLeaseRegistry` and by nothing else: the
/// initialiser is `fileprivate`, so no other file can mint a token and then
/// release a claim it does not hold.
struct WakeLeaseToken: Hashable, Sendable {
    fileprivate let rawValue: UInt64

    fileprivate init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Owns every physical power assertion this process holds, and hands out leases.
///
/// The rule it exists to enforce is aggregation: however many leases ask for
/// `systemIdleSleep`, exactly one system assertion exists; when the last of
/// them goes, it is released once. The same holds independently for
/// `displayIdleSleep`. Callers therefore never have to know about each other,
/// and no caller can release an assertion another one is still relying on.
///
/// 1.4.16 ships exactly one owner — the manual Stay Awake mode. The registry is
/// still a registry rather than a single flag because the ownership rule is the
/// hard part and retrofitting it later would mean rewriting the callers that
/// had grown up around a flag. Nothing speculative is built on top of it: there
/// is no second owner, no background lease and no hidden holder.
///
/// `@MainActor` because that is where the mode's observable state lives and
/// because `IOPMAssertionCreateWithName`/`IOPMAssertionRelease` are short
/// bookkeeping calls into `powerd`, not the kind of I/O the concurrency
/// registry requires to leave the UI actor. There is no queue, no task and no
/// timer here.
@MainActor
final class WakeLeaseRegistry {
    private let driver: PowerAssertionDriving
    private let assertionName: String

    /// What each live lease is asking for. The union of the values is what the
    /// system is asked to hold.
    private var leases: [WakeLeaseToken: Set<WakeRequirement>] = [:]

    /// The physical assertions that currently exist, at most one per
    /// requirement. This is the only place a live assertion identifier is kept.
    private var assertions: [WakeRequirement: PowerAssertionHandle] = [:]

    /// A counter rather than a `UUID`: uniqueness within one registry is all a
    /// token needs, and a counter makes the tests deterministic. It only ever
    /// grows, so a released token's value is never handed out again and a
    /// stale copy cannot start matching a later lease.
    private var nextTokenValue: UInt64 = 1

    /// No default driver, deliberately. The real IOKit driver has to be named
    /// at the call site, so a test that forgets to pass a fake fails to
    /// compile instead of quietly keeping the machine running the suite awake.
    init(driver: PowerAssertionDriving, assertionName: String = PowerAssertionName.stayAwake) {
        self.driver = driver
        self.assertionName = assertionName
    }

    // MARK: - Leases

    /// Registers a lease and makes sure the assertions it needs exist.
    ///
    /// Throws without registering anything if a required assertion could not be
    /// created. A caller that gets an error holds no lease, so its interface can
    /// say the mode is off and be telling the truth.
    @discardableResult
    func acquire(_ requirements: Set<WakeRequirement>) throws -> WakeLeaseToken {
        let token = WakeLeaseToken(rawValue: nextTokenValue)
        var proposed = leases
        proposed[token] = requirements
        try reconcile(to: proposed)
        // Advanced only after the change has been committed, so a failed
        // acquisition does not burn a value and leave a gap in the sequence.
        nextTokenValue += 1
        return token
    }

    /// Changes what an existing lease asks for, without releasing and
    /// re-taking it.
    ///
    /// This is the path the display option uses. Releasing the lease and
    /// acquiring a new one would drop the system assertion to zero holders for
    /// an instant and re-create it, which the person would feel as the Mac
    /// briefly being allowed to sleep. Throws — leaving the lease exactly as it
    /// was — if the new requirement could not be satisfied.
    func update(_ token: WakeLeaseToken, to requirements: Set<WakeRequirement>) throws {
        guard leases[token] != nil else { return }
        var proposed = leases
        proposed[token] = requirements
        try reconcile(to: proposed)
    }

    /// Drops one lease. Unknown or already-released tokens are a no-op.
    ///
    /// Not throwing, and not failing on a token it does not know: release is
    /// the path that runs during shutdown and during error recovery, and a
    /// release that can fail is a release that leaks. Assertions still wanted
    /// by another lease are untouched.
    func release(_ token: WakeLeaseToken) {
        guard leases[token] != nil else { return }
        var proposed = leases
        proposed[token] = nil
        // Releasing only ever removes requirements, so reconciliation creates
        // nothing and cannot fail. `try?` here is the absence of a creation
        // step, not a swallowed error.
        try? reconcile(to: proposed)
    }

    /// Drops every lease and releases every assertion. Idempotent.
    func releaseAll() {
        try? reconcile(to: [:])
    }

    // MARK: - Inspection

    /// Whether a physical assertion for this requirement currently exists.
    func holdsAssertion(for requirement: WakeRequirement) -> Bool {
        assertions[requirement] != nil
    }

    /// The requirements physically held right now.
    var heldRequirements: Set<WakeRequirement> {
        Set(assertions.keys)
    }

    /// How many leases exist. Used by tests and by nothing in the interface.
    var leaseCount: Int { leases.count }

    func requirements(for token: WakeLeaseToken) -> Set<WakeRequirement>? {
        leases[token]
    }

    // MARK: - Reconciliation

    /// Brings the physical assertions in line with a proposed set of leases,
    /// all or nothing.
    ///
    /// Order is the whole point. Everything that has to be created is created
    /// **first**; only once all of it succeeded is anything released and the
    /// lease table committed. That gives three properties the feature depends
    /// on:
    ///
    /// - a new requirement that cannot be created leaves the assertions that
    ///   already worked exactly as they were — turning on Keep Display Awake
    ///   and failing does not cost the person the system assertion they had;
    /// - a partial creation is rolled back before the error propagates, so no
    ///   assertion is left behind with nothing referring to it;
    /// - the caller's state and the system's state cannot disagree, because the
    ///   lease table is only written after the system said yes.
    ///
    /// Release failures are a different case and are deliberately not fatal.
    /// IOKit has already been told to drop the assertion, the handle is gone
    /// from our table either way, and retrying with an identifier the system
    /// may have discarded would risk releasing something else. Keeping the
    /// handle would be worse: it would be released a second time later.
    private func reconcile(to proposedLeases: [WakeLeaseToken: Set<WakeRequirement>]) throws {
        let desired = proposedLeases.values.reduce(into: Set<WakeRequirement>()) { $0.formUnion($1) }

        // `allCases` rather than set iteration so the order assertions are
        // created in is fixed. A test that makes the second creation fail needs
        // to know which one that is.
        let toCreate = WakeRequirement.allCases.filter { desired.contains($0) && assertions[$0] == nil }
        let toRelease = WakeRequirement.allCases.filter { !desired.contains($0) && assertions[$0] != nil }

        var created: [WakeRequirement: PowerAssertionHandle] = [:]
        do {
            for requirement in toCreate {
                created[requirement] = try driver.createAssertion(for: requirement, name: assertionName)
            }
        } catch {
            for handle in created.values {
                try? driver.releaseAssertion(handle)
            }
            throw error
        }

        for (requirement, handle) in created {
            assertions[requirement] = handle
        }
        for requirement in toRelease {
            guard let handle = assertions.removeValue(forKey: requirement) else { continue }
            try? driver.releaseAssertion(handle)
        }
        leases = proposedLeases
    }
}
