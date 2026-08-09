import Foundation
import XCTest
@testable import ImpulsCore

final class ClipboardContentTests: XCTestCase {
    func testRecognizesSupportedTextKinds() {
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "https://example.com/a"), .link)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "hello@example.com"), .email)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "+7 (999) 123-45-67"), .phone)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "#1A2B3C"), .color)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: #"{"ready":true}"#), .json)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "func launch() {\n  run();\n}"), .code)
        XCTAssertEqual(ClipboardContentClassifier.kind(for: "ordinary sentence"), .text)
    }

    func testFormatsJSONDeterministically() {
        let formatted = ClipboardContentClassifier.prettyPrintedJSON(#"{"z":1,"a":2}"#)
        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted?.contains("\n") == true)
        let a = formatted?.range(of: "\"a\"")?.lowerBound
        let z = formatted?.range(of: "\"z\"")?.lowerBound
        if let a, let z { XCTAssertLessThan(a, z) }
    }

    func testRecognizesImageFiles() {
        XCTAssertEqual(
            ClipboardContentClassifier.kind(for: URL(fileURLWithPath: "/tmp/screenshot.png")),
            .image
        )
        XCTAssertEqual(
            ClipboardContentClassifier.kind(for: URL(fileURLWithPath: "/tmp/model.step")),
            .file
        )
    }
}
