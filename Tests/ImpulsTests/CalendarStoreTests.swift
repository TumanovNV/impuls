import Foundation
import XCTest
@testable import ImpulsCore

final class CalendarStoreTests: XCTestCase {
    func testMeetingLinksRequireKnownHTTPSProvider() throws {
        XCTAssertTrue(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "https://meet.google.com/abc-defg-hij"))
        ))
        XCTAssertTrue(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "https://company.zoom.us/j/123?pwd=secret"))
        ))
        XCTAssertFalse(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "http://meet.google.com/abc-defg-hij"))
        ))
        XCTAssertFalse(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "https://attacker@meet.google.com/abc-defg-hij"))
        ))
        XCTAssertFalse(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "https://meet.google.com.evil.example/abc"))
        ))
        XCTAssertFalse(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "file:///tmp/invitation.command"))
        ))
    }
}
