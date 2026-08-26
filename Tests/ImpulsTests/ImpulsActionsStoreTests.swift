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

    func testLargeSearchCorpusIsBoundedOnTheMainActor() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let large = String(repeating: "x", count: ImpulsActionsStore.maximumSearchCharacters * 4)
            let item = ClipItem(payload: .text(large), date: Date())

            let results = store.results(clipboard: [item], snippets: [], notes: [])
            guard let result = results.first else {
                return XCTFail("Expected the large clipboard item in recent results")
            }
            let searchable = ImpulsActionsStore.searchableValue(of: result)

            XCTAssertEqual(searchable.count, ImpulsActionsStore.maximumSearchCharacters)
            XCTAssertEqual(result.title.count, ImpulsActionsStore.maximumSummaryCharacters)
        }
    }

    // MARK: - The folded corpus is cached, and it is never stale

    /// The saving. Typing another letter searches the same rows, so folding
    /// them again — three allocating `String.folding` calls per row, over up to
    /// 16 KiB each — is work for nothing.
    func testTypingDoesNotRefoldAnUnchangedCorpus() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let clips = [ClipItem(payload: .text("deployment checklist"), date: Date())]
            let snippets = [Snippet(label: "VPN", text: "vpn.example.com")]
            let notes = [Note(id: UUID(), text: "call the supplier", edited: Date())]

            var seen: [[ImpulsActionResult]] = []
            for query in ["d", "de", "dep", "depl", "deploy"] {
                store.query = query
                seen.append(store.results(clipboard: clips, snippets: snippets, notes: notes))
            }

            XCTAssertTrue(seen.allSatisfy { $0.contains { $0.title.contains("deployment") } })
            XCTAssertEqual(store.corpusBuildCount, 1, "five keystrokes over unchanged sources build one corpus")
        }
    }

    /// The correctness side, and the one that decides whether the cache is
    /// allowed to exist at all. Each source has to invalidate, and the very
    /// next search has to see the new data — added, edited and removed alike.
    func testEverySourceInvalidatesTheCorpusAndTheNextSearchSeesTheChange() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            var clips = [ClipItem(payload: .text("original clip"), date: Date())]
            var snippets = [Snippet(label: "original snippet", text: "value")]
            var notes = [Note(id: UUID(), text: "original note", edited: Date())]

            store.query = "original"
            XCTAssertEqual(store.results(clipboard: clips, snippets: snippets, notes: notes).count, 3)

            // Added.
            store.invalidateCorpus()
            clips.append(ClipItem(payload: .text("original addition"), date: Date()))
            store.query = "addition"
            XCTAssertEqual(
                store.results(clipboard: clips, snippets: snippets, notes: notes).map(\.source),
                [.clipboard],
                "a new clipboard entry has to be searchable immediately"
            )

            // Edited.
            store.invalidateCorpus()
            notes = [Note(id: notes[0].id, text: "rewritten note", edited: Date())]
            store.query = "rewritten"
            XCTAssertEqual(
                store.results(clipboard: clips, snippets: snippets, notes: notes).map(\.source),
                [.notes],
                "an edit that keeps the same id still changes what the row says"
            )
            store.query = "original note"
            XCTAssertTrue(
                store.results(clipboard: clips, snippets: snippets, notes: notes).isEmpty,
                "the old text must not survive in the cache"
            )

            // Removed.
            store.invalidateCorpus()
            snippets = []
            store.query = "original snippet"
            XCTAssertTrue(
                store.results(clipboard: clips, snippets: snippets, notes: notes).isEmpty,
                "a removed snippet must stop being a result"
            )
        }
    }

    /// Invalidation is driven by the stores' announcements, but a corpus whose
    /// size disagrees with the arrays it was handed is rebuilt rather than
    /// trusted — a missed notification must not become a stale result.
    func testACorpusThatDisagreesWithItsSourcesIsRebuiltWithoutBeingTold() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let clips = [ClipItem(payload: .text("first clip"), date: Date())]

            store.query = "clip"
            XCTAssertEqual(store.results(clipboard: clips, snippets: [], notes: []).count, 1)

            let more = clips + [ClipItem(payload: .text("second clip"), date: Date())]
            XCTAssertEqual(
                store.results(clipboard: more, snippets: [], notes: []).count,
                2,
                "no invalidateCorpus() was called, and the result is still correct"
            )
        }
    }
    /// A pinned file is deliberately absent from Actions search: an Actions row
    /// carries a value, not the pin's Open / Reveal / re-select / unavailable
    /// behaviour, and surfacing half of that under the same name is worse than
    /// leaving the pin in its own pane.
    func testAPinnedFileIsNotOfferedInActionsSearch() async {
        await MainActor.run {
            let store = ImpulsActionsStore()
            let text = Snippet(label: "Office", text: "info@example.com")
            let pin = Snippet(label: "Report", text: "/tmp/report.pdf", file: SnippetFileReference())

            let results = store.results(clipboard: [], snippets: [text, pin], notes: [])

            XCTAssertTrue(results.contains { $0.title == "Office" }, "a text snippet is still offered")
            XCTAssertFalse(results.contains { $0.title == "Report" }, "a file pin must not appear")
            XCTAssertFalse(
                results.contains { $0.origin == .snippet(pin.id) },
                "not under any title either"
            )
        }
    }
}
