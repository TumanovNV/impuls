import Foundation
import XCTest
@testable import ImpulsCore

final class ClipboardStoreTests: XCTestCase {
    func testPinnedItemsSurviveRetentionAndStayFirst() async {
        await MainActor.run {
            let now = Date()
            let store = ClipboardStore(persistence: nil)
            store.configurePersistence(enabled: false, retention: .oneHour)
            store.record(ClipItem(
                payload: .text("Pinned"),
                date: now.addingTimeInterval(-7_200),
                isPinned: true
            ))
            store.record(ClipItem(
                payload: .text("Expired"),
                date: now.addingTimeInterval(-7_200)
            ))
            store.record(ClipItem(payload: .text("Recent"), date: now))
            store.prune(at: now)

            XCTAssertEqual(store.items.map(\.preview), ["Pinned", "Recent"])
            XCTAssertTrue(store.items[0].isPinned)
        }
    }

    func testDuplicateCapturePreservesPinAndIdentifier() async {
        await MainActor.run {
            let store = ClipboardStore(persistence: nil)
            let original = ClipItem(payload: .text("Same"), date: Date(), isPinned: true)
            store.record(original)
            store.record(ClipItem(payload: .text("Same"), date: Date().addingTimeInterval(10)))

            XCTAssertEqual(store.items.count, 1)
            XCTAssertEqual(store.items[0].id, original.id)
            XCTAssertTrue(store.items[0].isPinned)
        }
    }

    func testClearUnpinnedPreservesPins() async {
        await MainActor.run {
            let store = ClipboardStore(persistence: nil)
            store.record(ClipItem(payload: .text("Pinned"), date: Date(), isPinned: true))
            store.record(ClipItem(payload: .text("Temporary"), date: Date()))

            store.clearUnpinned()

            XCTAssertEqual(store.items.map(\.preview), ["Pinned"])
        }
    }

    func testOversizedTextIsNotRecorded() async {
        await MainActor.run {
            let store = ClipboardStore(persistence: nil)
            let oversized = String(repeating: "x", count: ClipboardStore.maximumTextBytes + 1)

            store.record(ClipItem(payload: .text(oversized), date: Date()))

            XCTAssertTrue(store.items.isEmpty)
            XCTAssertFalse(ClipboardStore.isTextPayloadAllowed(oversized))
        }
    }

    func testInvalidImagePayloadIsRejectedBeforeDecode() async {
        await MainActor.run {
            XCTAssertFalse(ClipboardStore.isImagePayloadAllowed(Data("not an image".utf8)))
        }
    }
}
