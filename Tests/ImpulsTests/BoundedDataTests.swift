import Foundation
import XCTest
@testable import ImpulsCore

final class BoundedDataTests: XCTestCase {
    func testBoundedFileReaderNeverReturnsPastLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpulsBoundedRead-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data([0, 1, 2, 3, 4]).write(to: url)
        XCTAssertEqual(
            try BoundedFileReader.read(from: url, maximumBytes: 5),
            Data([0, 1, 2, 3, 4])
        )
        XCTAssertThrowsError(try BoundedFileReader.read(from: url, maximumBytes: 4)) { error in
            XCTAssertEqual(error as? BoundedDataError, .limitExceeded)
        }
    }
}
