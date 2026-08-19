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
