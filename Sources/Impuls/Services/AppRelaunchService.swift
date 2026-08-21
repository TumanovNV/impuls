import AppKit
import Foundation

/// Restarts Impuls without ever letting two instances exist at once.
///
/// The ordering is the whole point. Impuls cannot run code after it exits, so
/// something outside the process has to do the launching — but that something
/// must not launch anything until this process is actually gone. Two live
/// instances would fight over an exclusive resource each: `RegisterEventHotKey`
/// is claimed once with no retry, so the newcomer would come up with a dead
/// global shortcut, and the local stores have no cross-process locking, so both
/// could write `notes.json`, the clipboard archive and the shelf.
///
/// So: spawn a one-shot `/bin/sh` helper, let it watch for this process to
/// disappear, and only then let it `open` the bundle. No `-n` / no
/// `createsNewApplicationInstance`, which exists precisely to start a *second*
/// copy of a running app. No login item, no launch agent, no daemon, no new
/// dependency, and nothing that outlives the restart.
@MainActor
final class AppRelaunchService {
    enum Outcome: Equatable {
        /// The helper is watching and this process is on its way out.
        case relaunching
        /// Nothing was pending, so nothing was started or terminated.
        case nothingToDo
        /// The helper could not be started. This process keeps running.
        case failed
    }

    /// How long the helper waits for the old process before giving up.
    ///
    /// Fail-safe beats convenience: on timeout the helper exits *without*
    /// opening anything, because the only reason to still be waiting is that
    /// the old instance is somehow still alive, and starting a second one is
    /// worse than not restarting at all.
    static let pollInterval = 0.1
    static let pollLimit = 100  // ≈10 s

    /// Watches for `$1` to exit, then runs `$3 "$2"`.
    ///
    /// Every value arrives as a positional argument, never interpolated into
    /// the script text, so a path can contain spaces or shell metacharacters
    /// without becoming code. `kill -0` is a liveness probe, not a signal.
    ///
    /// The short settle after the process disappears is not the wait — the wait
    /// is the loop. It only gives macOS a moment to finish tearing the old
    /// instance down before LaunchServices is asked to start a new one.
    private static let script = """
    set -eu
    pid=$1
    bundle=$2
    opener=$3
    limit=$4
    interval=$5
    attempts=0
    while kill -0 "$pid" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$limit" ]; then
            exit 1
        fi
        /bin/sleep "$interval"
    done
    /bin/sleep 0.2
    exec "$opener" "$bundle"
    """

    private let bundleURL: () -> URL
    private let processIdentifier: () -> Int32
    private let startHelper: ([String]) throws -> Void
    private let terminate: () -> Void

    init(
        bundleURL: @escaping () -> URL = { Bundle.main.bundleURL },
        processIdentifier: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        startHelper: @escaping ([String]) throws -> Void = AppRelaunchService.runShell,
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.bundleURL = bundleURL
        self.processIdentifier = processIdentifier
        self.startHelper = startHelper
        self.terminate = terminate
    }

    /// Starts the helper and, only if that succeeded, quits.
    ///
    /// The order is a safety property, not a style choice: terminating first
    /// would leave the user with no app if the helper turned out to be
    /// unstartable, and starting the new instance first is the two-instance bug
    /// this whole service exists to avoid.
    func relaunch(pendingChange: Bool) -> Outcome {
        guard pendingChange else { return .nothingToDo }

        let arguments = Self.helperArguments(
            processIdentifier: processIdentifier(),
            bundlePath: bundleURL().path
        )
        do {
            try startHelper(arguments)
        } catch {
            return .failed
        }
        terminate()
        return .relaunching
    }

    /// The `/bin/sh` argument vector, exposed so the wait-then-open behaviour
    /// can be exercised against a real process instead of being trusted.
    ///
    /// `$0` is a label for `ps`, not a path — `sh -c` takes the script first and
    /// assigns the remaining operands to `$0`, `$1`, …
    static func helperArguments(
        processIdentifier: Int32,
        bundlePath: String,
        opener: String = "/usr/bin/open",
        pollLimit: Int = pollLimit,
        pollInterval: Double = pollInterval
    ) -> [String] {
        [
            "-c",
            script,
            "impuls-relaunch",
            String(processIdentifier),
            bundlePath,
            opener,
            String(pollLimit),
            String(pollInterval),
        ]
    }

    /// Launches the helper detached from this process's output.
    ///
    /// `Process` children are re-parented rather than killed when the parent
    /// exits, which is what makes the helper outlive the app it is waiting for.
    nonisolated static func runShell(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        // Inheriting a terminal or pipe could block the helper after the parent
        // is gone; it has nothing to say anyway.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}
