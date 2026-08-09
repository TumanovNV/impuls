import XCTest
@testable import ImpulsCore

final class BoundedTextTests: XCTestCase {
    func testFirstLineIsTrimmedAndBoundedWithoutChangingSource() {
        let source = "  \n  " + String(repeating: "x", count: 1_000) + "\nignored"
        let preview = BoundedText.firstLine(source, maximumCharacters: 160)

        XCTAssertEqual(preview.count, 160)
        XCTAssertEqual(preview, String(repeating: "x", count: 160))
        XCTAssertTrue(source.hasSuffix("ignored"))
    }

    func testLeadingWhitespaceHasAnInspectionBudget() {
        let source = String(repeating: " ", count: 5_000) + "hidden"
        XCTAssertEqual(BoundedText.firstLine(source, maximumCharacters: 160), "")
    }

    func testPrefixDoesNotSplitExtendedCharacters() {
        XCTAssertEqual(BoundedText.prefix("👨‍👩‍👧‍👦abc", maximumCharacters: 2), "👨‍👩‍👧‍👦a")
    }
}
