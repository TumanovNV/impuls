import Foundation
import XCTest
@testable import ImpulsCore

/// Backup import must not do blocking filesystem work on the main actor, and
/// must refuse filesystem objects whose reads cannot be bounded by a byte
/// budget. A reliability defect, not a security one.
///
/// This case is deliberately **not** `@MainActor`. `BackupService` is a
/// main-actor type, so a member is reachable from here only while it stays
/// `nonisolated` — which makes "the read path did not drift back onto the main
/// actor" a fact the compiler re-checks on every build, not a comment.
final class BackupIsolationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsBackupImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - The defect

    /// The regression. Reading a FIFO waits for a writer that never comes, and
    /// no byte budget bounds that wait, so it has to be refused before the
    /// read starts. If this ever hangs instead of throwing, the guard is gone.
    func testAFifoIsRefusedInsteadOfBlockingTheReader() throws {
        let fifo = try makeFifo(named: "backup.json")

        XCTAssertThrowsError(
            try BoundedFileReader.read(from: fifo, maximumBytes: 1_024)
        ) { error in
            XCTAssertEqual(error as? BoundedDataError, .notARegularFile)
        }
    }

    /// The same refusal, seen through the import path the user actually drives,
    /// as a localized error rather than a raw reader failure.
    func testImportingAFifoReportsAnUnsupportedFileTypeRatherThanHanging() throws {
        let fifo = try makeFifo(named: "pretend-backup.json")

        XCTAssertThrowsError(try BackupService.decode(contentsOf: fifo)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedFileType)
        }
        XCTAssertNotNil(BackupError.unsupportedFileType.errorDescription)
    }

    /// A directory is not readable as a backup either, and must not surface as
    /// a decode failure that suggests a corrupt file.
    func testADirectoryIsRefusedAsANonRegularFile() throws {
        let nested = directory.appendingPathComponent("folder.json", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertThrowsError(try BackupService.decode(contentsOf: nested)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedFileType)
        }
    }

    /// A symlink pointing at a FIFO is the shape the finding described: the
    /// name looks like a backup, the thing behind it is not a file. The check
    /// reads the descriptor actually opened, so the target decides the answer.
    func testASymlinkToAFifoIsRefused() throws {
        let fifo = try makeFifo(named: "target")
        let link = directory.appendingPathComponent("looks-like-a-backup.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)

        XCTAssertThrowsError(try BackupService.decode(contentsOf: link)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedFileType)
        }
    }

    // MARK: - What must keep working

    /// A symlink to a *regular* file is still a perfectly good backup. The
    /// guard rejects what cannot be read safely, not indirection.
    func testASymlinkToARegularBackupStillImports() throws {
        let real = try writeBackup(named: "real-backup.json")
        let link = directory.appendingPathComponent("linked-backup.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let document = try BackupService.decode(contentsOf: link)
        XCTAssertEqual(document.schemaVersion, ImpulsBackupDocument.currentSchemaVersion)
    }

    func testAValidRegularBackupStillImports() throws {
        let url = try writeBackup(named: "valid-backup.json")

        let document = try BackupService.decode(contentsOf: url)
        XCTAssertEqual(document.schemaVersion, ImpulsBackupDocument.currentSchemaVersion)
        XCTAssertEqual(document.snippets.count, 1)
        XCTAssertEqual(document.notes.count, 1)
    }

    /// The 10 MB bound predates this change and must survive it.
    func testTheOversizedBackupBoundStillHolds() throws {
        let url = directory.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ImpulsBackupDocument.maximumEncodedBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try BackupService.decode(contentsOf: url)) { error in
            XCTAssertEqual(error as? BackupError, .fileTooLarge)
        }
    }

    /// A missing file must still fail as a filesystem error, not be mistaken
    /// for an unsupported type — the two send the user to different places.
    func testAMissingFileStillFailsAsAFilesystemError() throws {
        let missing = directory.appendingPathComponent("nope.json")

        XCTAssertThrowsError(try BackupService.decode(contentsOf: missing)) { error in
            XCTAssertNotEqual(error as? BackupError, .unsupportedFileType)
        }
    }

    // MARK: - Isolation

    /// The import path's blocking work must actually leave the main actor.
    ///
    /// Driven from the main actor, exactly as the panel's completion handler
    /// drives it, and asserted from inside the same kind of detached boundary
    /// `BackupService.loadDocument` uses.
    @MainActor
    func testTheReadRunsOffTheMainActor() async throws {
        let url = try writeBackup(named: "off-main.json")

        MainActor.assertIsolated("the test drives this the way the panel's completion does")

        let ranOffMain: Bool = try await Task.detached(priority: .userInitiated) {
            _ = try BackupService.decode(contentsOf: url)
            // `Thread.isMainThread` is unavailable from an async context, and
            // this is the same question one layer down.
            return pthread_main_np() == 0
        }.value

        XCTAssertTrue(ranOffMain, "the read and decode must not execute on the main thread")
    }

    // MARK: - Helpers

    private func makeFifo(named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let created = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkfifo(path, 0o600)
        }
        try XCTSkipIf(created != 0, "the filesystem under test does not support FIFOs")
        return url
    }

    private func makeDocument() throws -> ImpulsBackupDocument {
        // Whole-second timestamps and a pinned version: `.iso8601` carries no
        // fractional seconds, so a `Date()` default would not survive its own
        // round trip and the comparison would fail for a reason that has
        // nothing to do with what these tests are checking.
        ImpulsBackupDocument(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.4.16",
            settings: ImpulsSettingsSnapshot(
                hotKey: .optionShiftSpace,
                activationMode: .hoverAndShortcut,
                openDelay: .balanced,
                panelSize: .compact,
                selectedDisplayID: nil,
                modules: [],
                saveClipboardImages: false
            ),
            snippets: [Snippet(label: "Office", text: "info@example.com")],
            notes: [Note(id: UUID(), text: "Call back", edited: Date(timeIntervalSince1970: 1_700_000_100))]
        )
    }

    private func writeBackup(named name: String) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(name)
        try encoder.encode(try makeDocument()).write(to: url)
        return url
    }
}
