import XCTest
@testable import ImpulsCore

final class BackupDocumentTests: XCTestCase {
    func testBackupRoundTripPreservesSettingsAndContent() async throws {
        try await MainActor.run {
            let settings = ImpulsSettingsSnapshot(
                hotKey: .optionShiftSpace,
                activationMode: .hoverAndShortcut,
                openDelay: .balanced,
                panelSize: .compact,
                selectedDisplayID: 42,
                modules: NotchViewModel.Tab.allCases.map { ModulePreference(tab: $0, isEnabled: $0 != .media) },
                saveClipboardImages: false
            )
            let document = ImpulsBackupDocument(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "1.1.0",
                settings: settings,
                snippets: [Snippet(label: "Office", text: "info@example.com")],
                notes: [Note(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, text: "Call back", edited: Date(timeIntervalSince1970: 1_700_000_100))]
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoded = try ImpulsBackupDocument.decode(encoder.encode(document))

            XCTAssertEqual(decoded, document)
        }
    }

    func testUnsupportedSchemaIsRejected() async {
        await MainActor.run {
            let json = """
            {
              "schemaVersion": 99,
              "createdAt": "2023-11-14T22:13:20Z",
              "appVersion": "9.9.9",
              "settings": {
                "hotKey": "optionSpace",
                "activationMode": "hoverAndShortcut",
                "openDelay": "short",
                "panelSize": "standard",
                "modules": [],
                "saveClipboardImages": true
              },
              "snippets": [],
              "notes": []
            }
            """

            XCTAssertThrowsError(try ImpulsBackupDocument.decode(Data(json.utf8)))
        }
    }
}
