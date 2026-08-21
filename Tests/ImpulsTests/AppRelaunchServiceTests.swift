import Foundation
import XCTest
@testable import ImpulsCore

final class AppRelaunchServiceTests: XCTestCase {
    /// Ordered log, so "terminate happened after the helper started" is an
    /// assertion rather than an assumption.
    private final class Recorder: @unchecked Sendable {
        private(set) var events: [String] = []
        private(set) var helperArguments: [String] = []
        func record(_ event: String) { events.append(event) }
        func recordHelper(_ arguments: [String]) {
            events.append("helper")
            helperArguments = arguments
        }
    }

    private struct HelperUnavailable: Error {}

    @MainActor
    private func makeService(
        recorder: Recorder,
        helperFails: Bool = false,
        processIdentifier: Int32 = 4242,
        bundlePath: String = "/Volumes/Work/build/Impuls.app"
    ) -> AppRelaunchService {
        AppRelaunchService(
            bundleURL: { URL(fileURLWithPath: bundlePath) },
            processIdentifier: { processIdentifier },
            startHelper: { arguments in
                if helperFails { throw HelperUnavailable() }
                recorder.recordHelper(arguments)
            },
            terminate: { recorder.record("terminate") }
        )
    }

    // MARK: - Orchestration

    @MainActor
    func testConfirmedRestartStartsTheHelperBeforeTerminating() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        XCTAssertEqual(service.relaunch(pendingChange: true), .relaunching)

        // Order is the safety property: quitting first would leave the user with
        // no app at all if the helper could not be started.
        XCTAssertEqual(recorder.events, ["helper", "terminate"])
    }

    /// If the helper cannot start, the app that is still working must keep working.
    @MainActor
    func testAFailedHelperLeavesTheApplicationRunning() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder, helperFails: true)

        XCTAssertEqual(service.relaunch(pendingChange: true), .failed)

        XCTAssertEqual(recorder.events, [], "nothing may be terminated when the helper never started")
    }

    @MainActor
    func testNoPendingChangeStartsNothing() {
        let recorder = Recorder()
        let service = makeService(recorder: recorder)

        XCTAssertEqual(service.relaunch(pendingChange: false), .nothingToDo)

        XCTAssertEqual(recorder.events, [])
    }

    /// The development build must come back, not some other copy on disk.
    @MainActor
    func testTheHelperReceivesTheExactBundlePathAndProcessIdentifier() {
        let recorder = Recorder()
        let path = "/Users/someone/Developer/impuls/build/Impuls.app"
        let service = makeService(recorder: recorder, processIdentifier: 9137, bundlePath: path)

        _ = service.relaunch(pendingChange: true)

        XCTAssertTrue(recorder.helperArguments.contains("9137"))
        XCTAssertTrue(recorder.helperArguments.contains(path))
        XCTAssertEqual(recorder.helperArguments.first, "-c")
    }

    /// Values must reach the shell as operands, never as script text.
    @MainActor
    func testAPathWithShellMetacharactersIsPassedAsAnOperand() {
        let recorder = Recorder()
        let hostile = "/tmp/a b; touch /tmp/pwned/Impuls.app"
        let service = makeService(recorder: recorder, bundlePath: hostile)

        _ = service.relaunch(pendingChange: true)

        XCTAssertTrue(recorder.helperArguments.contains(hostile))
        let script = recorder.helperArguments.dropFirst().first ?? ""
        XCTAssertFalse(script.isEmpty)
        XCTAssertFalse(script.contains(hostile), "the path must not be interpolated into the script")
    }

    /// `open -n` is exactly the flag that starts a second copy of a running app.
    @MainActor
    func testTheHelperNeverAsksForAnAdditionalInstance() {
        let recorder = Recorder()
        _ = makeService(recorder: recorder).relaunch(pendingChange: true)

        XCTAssertFalse(recorder.helperArguments.contains("-n"))
        let script = recorder.helperArguments.dropFirst().first ?? ""
        XCTAssertFalse(script.contains("-n "))
    }

    // MARK: - Together with the language preference

    private static let shipped = ["en", "ru", "de", "fr", "es", "zh-Hans", "ja"]

    @MainActor
    private func makeLanguageService() throws -> (AppLanguageService, UserDefaults, String) {
        let suite = "AppRelaunchServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped), defaults, suite)
    }

    /// Cancelling declines the restart, not the language.
    @MainActor
    func testCancellingTheConfirmationKeepsTheLanguageAndThePendingState() throws {
        let (language, defaults, suite) = try makeLanguageService()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        _ = makeService(recorder: recorder)

        language.select(.german)
        // The user dismissed the prompt: the service is simply never asked.

        XCTAssertEqual(recorder.events, [], "cancelling must neither start a helper nor terminate")
        XCTAssertEqual(language.selection, .german)
        XCTAssertEqual(defaults.string(forKey: AppLanguageService.preferenceKey), "de")
        XCTAssertTrue(language.requiresRelaunch, "the restart is still owed after a cancel")
    }

    /// Returning to System Default goes through the same safe restart.
    @MainActor
    func testReturningToSystemDefaultTakesTheSameRestartPath() throws {
        let suite = "AppRelaunchServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped).select(.german)

        let language = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertFalse(language.requiresRelaunch, "a fresh launch on the chosen language owes nothing")

        language.select(.system)
        XCTAssertTrue(language.requiresRelaunch)

        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        XCTAssertEqual(service.relaunch(pendingChange: language.requiresRelaunch), .relaunching)
        XCTAssertEqual(recorder.events, ["helper", "terminate"])
    }

    /// After the restart the new process owes nothing and must say nothing.
    @MainActor
    func testTheProcessThatComesBackHasNoPendingRestart() throws {
        let suite = "AppRelaunchServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let before = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        before.select(.japanese)
        XCTAssertTrue(before.requiresRelaunch)

        let relaunched = AppLanguageService(defaults: defaults, availableLocalizations: Self.shipped)
        XCTAssertEqual(relaunched.selection, .japanese)
        XCTAssertFalse(relaunched.requiresRelaunch)

        let recorder = Recorder()
        let service = makeService(recorder: recorder)
        XCTAssertEqual(service.relaunch(pendingChange: relaunched.requiresRelaunch), .nothingToDo)
        XCTAssertEqual(recorder.events, [])
    }

    /// A failed helper must not cost the user the language they picked.
    @MainActor
    func testTheLanguageSurvivesAFailedRestart() throws {
        let (language, defaults, suite) = try makeLanguageService()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = Recorder()
        let service = makeService(recorder: recorder, helperFails: true)

        language.select(.french)
        XCTAssertEqual(service.relaunch(pendingChange: language.requiresRelaunch), .failed)

        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(language.selection, .french)
        XCTAssertEqual(defaults.string(forKey: AppLanguageService.preferenceKey), "fr")
        XCTAssertTrue(language.requiresRelaunch)
    }

    // MARK: - The helper script itself

    /// The invariant the whole design exists for: nothing is opened while the
    /// original process is still alive.
    func testTheHelperDoesNotOpenAnythingWhileTheOldProcessIsAlive() throws {
        let sandbox = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let marker = sandbox.appendingPathComponent("opened")
        let opener = try recorder(at: sandbox, writing: marker)

        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["2"]
        try victim.run()

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = MainActor.assumeIsolated {
            AppRelaunchService.helperArguments(
                processIdentifier: victim.processIdentifier,
                bundlePath: "/exact/path/Impuls.app",
                opener: opener.path
            )
        }
        try helper.run()

        // While the "old process" lives, the helper must stay silent.
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(victim.isRunning, "the watched process ended too early to prove anything")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: marker.path),
                "the helper opened the bundle while the old instance was still running"
            )
        }

        victim.waitUntilExit()
        helper.waitUntilExit()

        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            "/exact/path/Impuls.app",
            "the helper must reopen the exact bundle it was given"
        )
    }

    /// Fail-safe: a process that refuses to die must not get a second instance.
    func testTheHelperGivesUpWithoutOpeningWhenTheOldProcessOutlivesTheTimeout() throws {
        let sandbox = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let marker = sandbox.appendingPathComponent("opened")
        let opener = try recorder(at: sandbox, writing: marker)

        let victim = Process()
        victim.executableURL = URL(fileURLWithPath: "/bin/sleep")
        victim.arguments = ["5"]
        try victim.run()
        defer { victim.terminate() }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = MainActor.assumeIsolated {
            AppRelaunchService.helperArguments(
                processIdentifier: victim.processIdentifier,
                bundlePath: "/exact/path/Impuls.app",
                opener: opener.path,
                pollLimit: 3,
                pollInterval: 0.1
            )
        }
        try helper.run()
        helper.waitUntilExit()

        XCTAssertNotEqual(helper.terminationStatus, 0, "the helper must report that it gave up")
        XCTAssertTrue(victim.isRunning, "the old process is still alive — that is the point of this case")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "timing out must never end in a second instance"
        )
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppRelaunchServiceTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for `/usr/bin/open` that records the path it was handed.
    private func recorder(at directory: URL, writing marker: URL) throws -> URL {
        let script = directory.appendingPathComponent("recorder.sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(marker.path)\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
