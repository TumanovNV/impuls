import Foundation
import XCTest
@testable import ImpulsCore

final class UpdateServiceTests: XCTestCase {
    func testOnlyExactUpdateEndpointIsAllowed() throws {
        XCTAssertTrue(UpdateService.isAllowedAPIURL(
            try XCTUnwrap(URL(string: "https://api.github.com/repos/TumanovNV/impuls/releases/latest"))
        ))
        XCTAssertFalse(UpdateService.isAllowedAPIURL(
            try XCTUnwrap(URL(string: "https://api.github.com/repos/TumanovNV/impuls/releases/latest?token=secret"))
        ))
        XCTAssertFalse(UpdateService.isAllowedAPIURL(
            try XCTUnwrap(URL(string: "https://api.github.com.evil.example/repos/TumanovNV/impuls/releases/latest"))
        ))
        XCTAssertFalse(UpdateService.isAllowedAPIURL(
            try XCTUnwrap(URL(string: "https://api.github.com:444/repos/TumanovNV/impuls/releases/latest"))
        ))
    }

    func testOnlyRepositoryReleasePagesAreAllowed() throws {
        XCTAssertTrue(UpdateService.isAllowedReleaseURL(
            try XCTUnwrap(URL(string: "https://github.com/TumanovNV/impuls/releases/tag/v1.2.4"))
        ))
        XCTAssertFalse(UpdateService.isAllowedReleaseURL(
            try XCTUnwrap(URL(string: "https://github.com/TumanovNV/other/releases/tag/v1.2.4"))
        ))
    }

    func testNumericVersionComparison() {
        XCTAssertTrue(UpdateService.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateService.isNewer("1.2.4", than: "1.2.4"))
        XCTAssertFalse(UpdateService.isNewer("1.2.3", than: "1.2.4"))
    }
}
