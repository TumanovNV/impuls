import Foundation
import XCTest
@testable import ImpulsCore

final class UpdateServiceTests: XCTestCase {
    func testOnlyExactSignedFeedEndpointIsAllowed() throws {
        XCTAssertTrue(UpdateService.isAllowedFeedURL(
            try XCTUnwrap(URL(string: "https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml"))
        ))
        XCTAssertFalse(UpdateService.isAllowedFeedURL(
            try XCTUnwrap(URL(string: "https://github.com/TumanovNV/impuls/releases/latest/download/appcast.xml?token=secret"))
        ))
        XCTAssertFalse(UpdateService.isAllowedFeedURL(
            try XCTUnwrap(URL(string: "https://github.com.evil.example/TumanovNV/impuls/releases/latest/download/appcast.xml"))
        ))
        XCTAssertFalse(UpdateService.isAllowedFeedURL(
            try XCTUnwrap(URL(string: "https://github.com:444/TumanovNV/impuls/releases/latest/download/appcast.xml"))
        ))
        XCTAssertFalse(UpdateService.isAllowedFeedURL(
            try XCTUnwrap(URL(string: "https://attacker@github.com/TumanovNV/impuls/releases/latest/download/appcast.xml"))
        ))
    }

    func testLegacyConsentMigrationAcceptsOnlyCompletedDecisions() {
        XCTAssertEqual(UpdateService.legacyConsent(from: "allowed"), .allowed)
        XCTAssertEqual(UpdateService.legacyConsent(from: "denied"), .denied)
        XCTAssertNil(UpdateService.legacyConsent(from: "unknown"))
        XCTAssertNil(UpdateService.legacyConsent(from: "invalid"))
        XCTAssertNil(UpdateService.legacyConsent(from: nil))
    }

    func testChunkedResponseAccumulatorRejectsBytesBeyondLimit() throws {
        var buffer = BoundedDataAccumulator(maximumBytes: 5)
        try buffer.append(Data([0, 1]))
        try buffer.append(Data([2, 3, 4]))
        XCTAssertEqual(buffer.data.count, 5)
        XCTAssertThrowsError(try buffer.append(Data([5]))) { error in
            XCTAssertEqual(error as? BoundedDataError, .limitExceeded)
        }
    }
}
