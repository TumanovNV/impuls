import Foundation
import XCTest
@testable import ImpulsCore

final class ClipboardContentTests: XCTestCase {
    func testLargeStructuredPayloadUsesBoundedClassification() {
        let oversizedJSON = "{\"payload\":\"" + String(
            repeating: "x",
            count: ClipboardContentClassifier.maximumStructuredTextBytes
        ) + "\"}"

        XCTAssertEqual(ClipboardContentClassifier.kind(for: oversizedJSON), .text)
    }

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

    func testSnippetIdentityAndRowsStayCompactForLargeText() {
        let text = String(repeating: "x", count: 100_000)
        let first = Snippet(text: text)
        let second = Snippet(text: text)

        XCTAssertEqual(first.id, second.id)
        XCTAssertLessThan(first.id.count, 64)
        XCTAssertEqual(first.preview.count, 240)
        XCTAssertEqual(first.symbol, "text.alignleft")
    }

    func testNotePreviewDoesNotWalkTheWholeNote() {
        let note = Note(id: UUID(), text: String(repeating: "n", count: 100_000), edited: Date())
        XCTAssertEqual(note.preview.count, 160)
    }
}
