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
}
