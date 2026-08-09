import Foundation
import XCTest
@testable import ImpulsCore

final class ImpulsActionsStoreTests: XCTestCase {
    func testSearchMatchesEverySourceAndFoldsCaseAndAccents() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let clips = [ClipItem(payload: .text("Cafe deployment checklist"), date: Date())]
            let snippets = [Snippet(label: "Café VPN", text: "vpn.example.com")]
            let notes = [Note(id: UUID(), text: "Call the cafe supplier", edited: Date())]

            store.query = "CAFE"
            let results = store.results(clipboard: clips, snippets: snippets, notes: notes)

            XCTAssertEqual(Set(results.map(\.source)), Set(ImpulsActionSource.allCases))
            XCTAssertTrue(results.contains { $0.title == "Café VPN" })
        }
    }

    func testEmptyQueryReturnsBoundedMixedRecents() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let clips = (0..<8).map { ClipItem(payload: .text("Clip \($0)"), date: Date()) }
            let snippets = (0..<6).map { Snippet(label: "Saved \($0)", text: "Value \($0)") }
            let notes = (0..<5).map { Note(id: UUID(), text: "Note \($0)", edited: Date()) }

            let results = store.results(clipboard: clips, snippets: snippets, notes: notes)

            XCTAssertEqual(results.count, 10)
            XCTAssertEqual(results.filter { $0.source == .clipboard }.count, 4)
            XCTAssertEqual(results.filter { $0.source == .snippets }.count, 3)
            XCTAssertEqual(results.filter { $0.source == .notes }.count, 3)
        }
    }

    func testCommandsFollowContentTypeAndOrigin() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let file = ClipItem(payload: .file(URL(fileURLWithPath: "/tmp/drawing.step")), date: Date())
            let link = ClipItem(payload: .text("https://example.com"), date: Date())
            let snippet = Snippet(label: "Portal", text: "https://example.com")

            let results = store.results(clipboard: [file, link], snippets: [snippet], notes: [])
            let fileResult = results.first { $0.value == .file(URL(fileURLWithPath: "/tmp/drawing.step")) }
            let linkResult = results.first { $0.origin == .clipboard(link.id) }
            let snippetResult = results.first { $0.source == .snippets }

            XCTAssertEqual(fileResult?.commands, [.copy, .open, .reveal, .pin])
            XCTAssertTrue(linkResult?.commands.contains(.open) == true)
            XCTAssertFalse(snippetResult?.commands.contains(.saveSnippet) == true)
            XCTAssertTrue(snippetResult?.commands.contains(.createNote) == true)
        }
    }

    func testContextCommandsFollowDetectedClipboardContent() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let email = ClipItem(payload: .text("hello@example.com"), date: Date())
            let phone = ClipItem(payload: .text("+7 999 123-45-67"), date: Date())
            let json = ClipItem(payload: .text(#"{"ready":true}"#), date: Date(), isPinned: true)

            let results = store.results(clipboard: [email, phone, json], snippets: [], notes: [])
            let emailResult = results.first { $0.origin == .clipboard(email.id) }
            let phoneResult = results.first { $0.origin == .clipboard(phone.id) }
            let jsonResult = results.first { $0.origin == .clipboard(json.id) }

            XCTAssertEqual(emailResult?.contentKind, .email)
            XCTAssertTrue(emailResult?.commands.contains(.email) == true)
            XCTAssertTrue(phoneResult?.commands.contains(.call) == true)
            XCTAssertTrue(jsonResult?.commands.contains(.formatJSON) == true)
            XCTAssertTrue(jsonResult?.commands.contains(.unpin) == true)
        }
    }
}
