import XCTest
@testable import ImpulsCore

final class TranslatorTests: XCTestCase {
    func testInputIsBoundedBeforeLanguageAnalysis() async {
        await MainActor.run {
            let translator = Translator()
            translator.input = String(
                repeating: "я",
                count: Translator.maximumInputCharacters + 1_000
            )

            XCTAssertEqual(translator.input.count, Translator.maximumInputCharacters)
            XCTAssertEqual(translator.route.source, Translator.russian)
        }
    }
}
