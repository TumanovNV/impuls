import Foundation
import XCTest
@testable import ImpulsCore

final class ClipboardHistoryPersistenceTests: XCTestCase {
    func testEncryptedArchiveRoundTripPreservesMetadata() throws {
        let item = ClipItem(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            payload: .text("confidential clipboard value"),
            date: Date(timeIntervalSince1970: 1_700_000_000),
            isPinned: true
        )
        let key = Data((0..<32).map { UInt8($0) })

        let sealed = try EncryptedClipboardArchive.seal(
            ClipboardHistoryArchive(items: [item]),
            keyData: key
        )
        let opened = try EncryptedClipboardArchive.open(sealed, keyData: key)

        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "confidential"))
        XCTAssertEqual(opened.items.first?.id, item.id)
        XCTAssertEqual(opened.items.first?.preview, item.preview)
        XCTAssertEqual(opened.items.first?.isPinned, true)
    }

    func testWrongKeyCannotOpenArchive() throws {
        let archive = ClipboardHistoryArchive(items: [
            ClipItem(payload: .text("secret"), date: Date())
        ])
        let sealed = try EncryptedClipboardArchive.seal(archive, keyData: Data(repeating: 1, count: 32))

        XCTAssertThrowsError(
            try EncryptedClipboardArchive.open(sealed, keyData: Data(repeating: 2, count: 32))
        )
    }

    // MARK: - An archive that cannot be read is still the user's data

    func testAMissingArchiveLoadsAsEmptyRatherThanUnreadable() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(Self.persistence(at: url).load(), .loaded([]))
    }

    func testAnArchiveThatCannotBeOpenedIsReportedAsUnreadable() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an archive this build can open".utf8).write(to: url)

        XCTAssertEqual(Self.persistence(at: url).load(), .unreadable)
    }

    /// The regression this guards: switching persistence on used to `load()`,
    /// get `[]` back for every failure alike, and then immediately seal the
    /// in-memory list over the file. A history that was merely momentarily
    /// unreadable — a newer build's archive, one over the size budget, a key the
    /// process could not fetch — was destroyed by nothing more than a toggle.
    @MainActor
    func testEnablingPersistenceDoesNotWriteOverAnArchiveItCouldNotRead() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("not an archive this build can open".utf8)
        try original.write(to: url)

        let persistence = Self.persistence(at: url)
        let store = ClipboardStore(persistence: persistence)
        store.record(ClipItem(payload: .text("copied after the failed read"), date: Date()))

        store.configurePersistence(enabled: true, retention: .sevenDays)
        // Writes are debounced onto a serial queue; `flush` is what makes a
        // pending one land. With nothing pending it returns without writing,
        // which is exactly the property under test.
        persistence.flush()

        XCTAssertEqual(
            try Data(contentsOf: url),
            original,
            "an archive this build cannot open must survive the toggle that could not read it"
        )
    }

    // MARK: - The write latch, and recovery from it

    /// The finding an independent review raised against the fix above: the
    /// toggle was guarded, and nothing else was. `persist()` asked only whether
    /// persistence was enabled, so the very next clipboard change — half a
    /// second later, on the ordinary poll — sealed the in-memory list over an
    /// archive this process had merely failed to open. So did a retention edit,
    /// and so did the flush at quit.
    ///
    /// This drives every one of those paths against a real archive whose bytes
    /// are known, and then proves the file is unchanged byte for byte.
    @MainActor
    func testNoNormalPersistencePathWritesOverAnArchiveThatCouldNotBeRead() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let persistence = Self.persistence(at: url)
        defer { persistence.delete() }

        // A genuine archive, sealed with this persistence's own key.
        let seeded = ClipItem(payload: .text("saved before the archive became unreadable"), date: Date())
        let seeder = ClipboardStore(persistence: persistence)
        seeder.configurePersistence(enabled: true, retention: .sevenDays)
        seeder.record(seeded)
        persistence.flush()
        let realArchive = try Data(contentsOf: url)
        XCTAssertFalse(realArchive.isEmpty, "the seeded archive has to exist for this test to mean anything")

        // Now make it unreadable the way a newer build's format or a truncated
        // write would: the file is there, and this process cannot open it.
        let unreadable = Data("an archive this build cannot open".utf8)
        try unreadable.write(to: url)

        let store = ClipboardStore(persistence: persistence)
        store.configurePersistence(enabled: true, retention: .sevenDays)
        XCTAssertTrue(
            persistence.isBlockedByUnreadableArchive,
            "a failed read has to latch, not just return early once"
        )

        // Every ordinary write path, in the order a running app reaches them.
        store.record(ClipItem(payload: .text("copied while the archive was unreadable"), date: Date()))
        store.record(ClipItem(payload: .text("copied again"), date: Date()))
        store.setPinned(id: store.items[0].id, pinned: true)
        store.prune()
        store.configurePersistence(enabled: true, retention: .thirtyDays)
        persistence.flush()
        store.stop()

        XCTAssertEqual(
            try Data(contentsOf: url),
            unreadable,
            "no clipboard event, prune, retention change or shutdown flush may write over an unread archive"
        )
        XCTAssertTrue(persistence.isBlockedByUnreadableArchive, "nothing but a successful read may unlatch")

        // The items were withheld from disk, not thrown away.
        XCTAssertEqual(store.items.count, 2)

        // Recovery: the archive becomes readable again — the keychain unlocks,
        // the newer build is gone — and the next configuration retries the read.
        try realArchive.write(to: url)
        store.configurePersistence(enabled: true, retention: .sevenDays)
        persistence.flush()

        XCTAssertFalse(persistence.isBlockedByUnreadableArchive, "a successful read releases the latch")
        XCTAssertEqual(
            persistence.load().items.map(\.preview).sorted(),
            [
                "copied again",
                "copied while the archive was unreadable",
                "saved before the archive became unreadable",
            ],
            "recovery folds the restored archive together with the session — neither side is destroyed"
        )
    }

    /// The latch belongs to the object that owns the file, so a caller cannot
    /// reach the disk around it. `save` + `flush` is the shortest such route.
    func testTheLatchCannotBeBypassedByGoingStraightToThePersistenceLayer() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let unreadable = Data("an archive this build cannot open".utf8)
        try unreadable.write(to: url)

        let persistence = Self.persistence(at: url)
        defer { persistence.delete() }
        XCTAssertEqual(persistence.load(), .unreadable)

        persistence.save([ClipItem(payload: .text("straight to the writer"), date: Date())])
        persistence.flush()

        XCTAssertEqual(try Data(contentsOf: url), unreadable)
    }

    /// Requirement four of the recovery contract: a destructive reset stays
    /// available, but only as something the user asks for. Switching clipboard
    /// persistence off is that action, and it reaches `delete()`.
    @MainActor
    func testTurningPersistenceOffIsStillAllowedToRemoveAnUnreadableArchive() throws {
        let url = Self.temporaryArchiveURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("an archive this build cannot open".utf8).write(to: url)

        let persistence = Self.persistence(at: url)
        let store = ClipboardStore(persistence: persistence)
        store.configurePersistence(enabled: true, retention: .sevenDays)
        XCTAssertTrue(persistence.isBlockedByUnreadableArchive)

        store.configurePersistence(enabled: false, retention: .sevenDays)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(persistence.isBlockedByUnreadableArchive, "the archive it guarded is gone")
    }

    private static func persistence(at url: URL) -> ClipboardHistoryPersistence {
        // A test-owned keychain identity: the write path mints a key on demand,
        // and it must never be the one that decrypts the real archive.
        ClipboardHistoryPersistence(
            fileURL: url,
            service: "io.tumanov.impuls.tests.clipboard-history",
            account: "archive-key.\(UUID().uuidString)"
        )
    }

    private static func temporaryArchiveURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsClipboardArchiveTests-\(UUID().uuidString)")
    }
}
