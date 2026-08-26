import Foundation
import EventKit
import XCTest
@testable import ImpulsCore

final class CalendarStoreTests: XCTestCase {
    func testZoomMeetingIDsAndSubdomainAreAccepted() throws {
        for url in [
            "https://zoom.us/j/123456789",
            "https://us02web.zoom.us/j/1234567890",
            "https://us02web.zoom.us/j/12345678901",
        ] {
            XCTAssertTrue(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testZoomPreservesOriginalQueryAndFragment() {
        let value = "Join https://zoom.us/j/123456789?pwd=synthetic#synthetic"
        XCTAssertEqual(MeetingLink.firstKnownLink(in: value)?.absoluteString, "https://zoom.us/j/123456789?pwd=synthetic#synthetic")
    }

    func testZoomRejectsOrdinaryAndInvalidPaths() throws {
        for url in [
            "https://zoom.us/", "https://zoom.us/signin", "https://zoom.us/join",
            "https://zoom.us/meeting/123456789", "https://zoom.us/settings", "https://zoom.us/profile",
            "https://zoom.us/w/123456789", "https://zoom.us/j/abcdefghi",
            "https://zoom.us/j/12345678", "https://zoom.us/j/123456789012",
        ] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
        for url in ["https://zoom.us.example.com/j/123456789", "https://fakezoom.us/j/123456789", "https://zoom-us.example.com/j/123456789"] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testGoogleMeetCodeAndOriginalQueryAreAccepted() throws {
        XCTAssertTrue(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: "https://meet.google.com/AbC-dEfG-hIj"))))
        let value = "Join https://meet.google.com/abc-defg-hij?authuser=0#synthetic"
        XCTAssertEqual(MeetingLink.firstKnownLink(in: value)?.absoluteString, "https://meet.google.com/abc-defg-hij?authuser=0#synthetic")
    }

    func testGoogleMeetRejectsOrdinaryMalformedAndLookalikeURLs() throws {
        for url in [
            "https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com/lookup/synthetic",
            "https://meet.google.com/new", "https://meet.google.com/settings", "https://meet.google.com/abc-defg-h1j",
            "https://meet.google.com/abc-defgh-ij", "https://sub.meet.google.com/abc-defg-hij",
            "https://meet.google.com.example.com/abc-defg-hij",
        ] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testLegacyTeamsMeetupJoinAndOriginalQueryAreAccepted() throws {
        let url = "https://teams.microsoft.com/l/meetup-join/synthetic-payload/0?context=synthetic#synthetic"
        XCTAssertTrue(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))))
        XCTAssertEqual(MeetingLink.firstKnownLink(in: "Join \(url)")?.absoluteString, url)
    }

    func testLegacyTeamsRejectsMissingSegmentsAndOrdinaryURLs() throws {
        for url in [
            "https://teams.microsoft.com/", "https://teams.microsoft.com/l/messages/synthetic",
            "https://teams.microsoft.com/l/channel/synthetic", "https://teams.microsoft.com/l/meetup-join/",
            "https://teams.microsoft.com/l/meetup-join/synthetic",
            "https://teams.microsoft.com/launcher.html?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2Fsynthetic",
        ] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testShortTeamsMeetingURLsAcceptNumericIDsAndPreserveOriginalURL() throws {
        for url in [
            "https://teams.microsoft.com/meet/123456?p=synthetic",
            "https://teams.microsoft.com/meet/12345678901234567890?context=synthetic&p=synthetic#synthetic",
        ] {
            XCTAssertTrue(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
            XCTAssertEqual(MeetingLink.firstKnownLink(in: "Join \(url)")?.absoluteString, url)
        }
    }

    func testShortTeamsMeetingURLsRejectMalformedPathsAndPasscodes() throws {
        for url in [
            "https://teams.microsoft.com/meet/", "https://teams.microsoft.com/meet/abc?p=synthetic",
            "https://teams.microsoft.com/meet/123456", "https://teams.microsoft.com/meet/123456?p=",
            "https://teams.microsoft.com/meet/123456/extra?p=synthetic",
            "https://teams.microsoft.com/meeting/123456?p=synthetic",
            "https://fake.teams.microsoft.com/meet/123456?p=synthetic",
            "https://teams.microsoft.com.example.com/meet/123456?p=synthetic",
        ] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testGlobalURLSafetyRejectsInsecureCredentialsPortsAndUnrelatedHosts() throws {
        for url in [
            "http://meet.google.com/abc-defg-hij", "https://attacker@meet.google.com/abc-defg-hij",
            "https://meet.google.com:443/abc-defg-hij", "https://example.com/abc-defg-hij",
            "file:///tmp/invitation.command",
        ] {
            XCTAssertFalse(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
        XCTAssertFalse(MeetingLink.isAllowedMeetingURL(
            try XCTUnwrap(URL(string: "https://zoom.us/j/123 456789"))
        ))
    }

    func testFieldPriorityAndDuplicateAreDeterministic() throws {
        let event = EKEvent(eventStore: EKEventStore())
        event.location = "https://zoom.us/j/123456789"
        event.notes = "https://meet.google.com/abc-defg-hij"
        event.url = try XCTUnwrap(URL(string: "https://teams.microsoft.com/l/meetup-join/synthetic/0"))
        XCTAssertEqual(MeetingLink.find(in: event)?.absoluteString, event.location)

        event.location = nil
        XCTAssertEqual(MeetingLink.find(in: event)?.absoluteString, "https://meet.google.com/abc-defg-hij")

        event.notes = nil
        XCTAssertEqual(MeetingLink.find(in: event)?.absoluteString, event.url?.absoluteString)

        event.location = "https://zoom.us/j/123456789"
        event.notes = "https://zoom.us/j/123456789"
        XCTAssertEqual(MeetingLink.find(in: event)?.absoluteString, event.location)
    }

    func testFirstAcceptedTextualCandidateWins() {
        let text = "https://example.com/nope https://meet.google.com/abc-defg-hij https://zoom.us/j/123456789"
        XCTAssertEqual(MeetingLink.firstKnownLink(in: text)?.absoluteString, "https://meet.google.com/abc-defg-hij")
    }

    func testLegacyProviderHostOnlyCompatibilityIsPreserved() throws {
        for url in [
            "https://company.webex.com/signin", "https://whereby.com/landing", "https://meet.jit.si/synthetic-room",
            "https://discord.gg/synthetic", "https://telemost.yandex.ru/synthetic",
            "https://teams.live.com/ordinary-page",
        ] {
            XCTAssertTrue(MeetingLink.isAllowedMeetingURL(try XCTUnwrap(URL(string: url))), url)
        }
    }

    func testMeetingLinkScanHasABoundedCorpus() {
        XCTAssertEqual(
            MeetingLink.firstKnownLink(in: "Join https://meet.google.com/abc-defg-hij now")?.host,
            "meet.google.com"
        )

        let outsideBudget = String(
            repeating: "x",
            count: MeetingLink.maximumScannedCharacters
        ) + " https://meet.google.com/abc-defg-hij"
        XCTAssertNil(MeetingLink.firstKnownLink(in: outsideBudget))
    }
}
