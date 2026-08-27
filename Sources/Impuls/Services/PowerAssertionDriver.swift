import Foundation
import IOKit.pwr_mgt

/// What one holder of a wake lease is asking the system for.
///
/// The two are deliberately independent. A person who wants their Mac to keep
/// working while it renders something does not necessarily want the screen to
/// stay lit, and macOS models those as two different assertions rather than as
/// two strengths of one. Modelling them as one flag would force the display to
/// stay on for every caller, which is both a battery cost and a decision that
/// belongs to the person, not to this file.
///
/// One enum rather than a domain enum plus a mirrored driver enum: the two
/// would be one-to-one, and a second taxonomy that always agrees with the first
/// is duplication pretending to be a boundary. The mapping to the IOKit string
/// is the only thing that differs, and it lives on the driver below.
enum WakeRequirement: String, CaseIterable, Sendable, Hashable {
    /// Prevents the system idle-sleeping for lack of user activity. The
    /// display may still dim and sleep.
    case systemIdleSleep
    /// Prevents the display dimming and turning off for lack of user activity.
    case displayIdleSleep

    /// The public IOKit assertion type this requirement is expressed as.
    ///
    /// Both come from `IOKit/pwr_mgt/IOPMLib.h` and are the two the header
    /// documents for exactly this purpose. The deprecated spellings next to
    /// them in that header — `kIOPMAssertionTypeNoIdleSleep`,
    /// `kIOPMAssertionTypeNoDisplaySleep`, `kIOPMAssertionTypePreventSystemSleep`
    /// — are deliberately not used: the first two have been deprecated since
    /// 10.7, and the third is documented as not supported in any release.
    var ioKitAssertionType: String {
        switch self {
        case .systemIdleSleep: return kIOPMAssertPreventUserIdleSystemSleep
        case .displayIdleSleep: return kIOPMAssertPreventUserIdleDisplaySleep
        }
    }
}

/// One physical assertion this process owns.
///
/// The identifier is carried rather than kept in a global, so releasing means
/// releasing *this* assertion. There is no ambient "the assertion" to get
/// wrong, and a handle that has been released is a value the registry has
/// already dropped rather than a stale global still pointing at a live ID.
struct PowerAssertionHandle: Hashable, Sendable {
    let requirement: WakeRequirement
    let rawIdentifier: UInt32
}

/// Why a physical assertion could not be created or released.
///
/// It carries the `IOReturn` because that is the only thing IOKit tells us and
/// discarding it would leave a failure with no diagnosis at all. It is not
/// user-facing: the interface says the mode could not be turned on, and this
/// value never reaches a string a person reads.
enum PowerAssertionFailure: Error, Equatable {
    case creationFailed(WakeRequirement, status: Int32)
    case releaseFailed(PowerAssertionHandle, status: Int32)
}

/// The seam between the lease model and macOS.
///
/// It exists so that running the test suite cannot keep a developer's or a CI
/// runner's Mac awake. `WakeLeaseRegistry` has no default driver — the real one
/// has to be named at the call site — so reaching IOKit is an explicit
/// production choice and a test that forgets to pass a fake does not compile.
@MainActor
protocol PowerAssertionDriving: AnyObject {
    /// Creates one assertion and returns the handle for exactly that assertion.
    func createAssertion(for requirement: WakeRequirement, name: String) throws -> PowerAssertionHandle
    /// Releases exactly the assertion this handle refers to.
    func releaseAssertion(_ handle: PowerAssertionHandle) throws
}

/// The production driver: public IOKit power-management assertions, nothing else.
///
/// Deliberately not `/usr/bin/caffeinate` and not `pmset`. `caffeinate` would
/// mean owning a child process whose lifetime we would then have to reconcile
/// with our own, and it can only express what its flags express; `pmset` writes
/// the person's own Energy Saver settings, which this feature must never touch.
/// An assertion is scoped to this process — it is what `caffeinate` itself
/// takes — so quitting or crashing Impuls ends it, and the user's system
/// settings are exactly where they were.
///
/// `IOPMAssertionCreateWithName` needs no entitlement and no permission, so
/// there is no authorization path here and nothing to ask the user for.
@MainActor
final class IOKitPowerAssertionDriver: PowerAssertionDriving {
    func createAssertion(for requirement: WakeRequirement, name: String) throws -> PowerAssertionHandle {
        var identifier = IOPMAssertionID(kIOPMNullAssertionID)
        let status = IOPMAssertionCreateWithName(
            requirement.ioKitAssertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &identifier
        )
        // Both halves are checked. A success return with the null ID is not
        // something the header promises can happen, but treating it as a live
        // assertion would leave the interface claiming a mode that does not
        // exist, which is the one outcome this feature must not produce.
        guard status == kIOReturnSuccess, identifier != IOPMAssertionID(kIOPMNullAssertionID) else {
            throw PowerAssertionFailure.creationFailed(requirement, status: status)
        }
        return PowerAssertionHandle(requirement: requirement, rawIdentifier: identifier)
    }

    func releaseAssertion(_ handle: PowerAssertionHandle) throws {
        let status = IOPMAssertionRelease(IOPMAssertionID(handle.rawIdentifier))
        guard status == kIOReturnSuccess else {
            throw PowerAssertionFailure.releaseFailed(handle, status: status)
        }
    }
}

/// The name macOS shows for our assertions, in `pmset -g assertions` and in the
/// system's own diagnostics.
///
/// It names the application and the feature and stops there. No file path, no
/// device identifier, no window title and nothing about what the person is
/// doing: this string leaves the process and is readable by anything on the
/// Mac that can run `pmset`, so it is held to the same rule as a log line.
///
/// Not localized, on purpose. It is a diagnostic identifier that somebody
/// grepping `pmset` output has to be able to match, and a name that changes
/// with the interface language would make that impossible.
///
/// ASCII only, for the same reason, and this is not a style preference:
/// `/usr/bin/pmset` writes its output in MacRoman rather than UTF-8, so an em
/// dash here arrives in a UTF-8 terminal as a lone `0xD1` byte and the name a
/// person copied out of the source no longer matches the line on their screen.
/// Verified on macOS 26 against a live assertion.
enum PowerAssertionName {
    static let stayAwake = "Impuls: Stay Awake"
}
