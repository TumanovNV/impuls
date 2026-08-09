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
                saveClipboardImages: false,
                persistClipboardHistory: true,
                clipboardRetention: .thirtyDays,
                excludedClipboardBundleIdentifiers: ["com.example.private"]
            )
            let document = ImpulsBackupDocument(
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                appVersion: "1.2.2",
                settings: settings,
                snippets: [Snippet(label: "Office", text: "info@example.com")],
                notes: [Note(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, text: "Call back", edited: Date(timeIntervalSince1970: 1_700_000_100))]
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoded = try ImpulsBackupDocument.decode(encoder.encode(document))

            XCTAssertEqual(decoded, document)
            XCTAssertEqual(decoded.schemaVersion, 2)
            XCTAssertTrue(decoded.settings.persistClipboardHistory)
        }
    }

    func testVersionOneBackupRemainsReadable() async throws {
        try await MainActor.run {
            let json = """
            {
              "schemaVersion": 1,
              "createdAt": "2023-11-14T22:13:20Z",
              "appVersion": "1.1.0",
              "settings": {
                "hotKey": "optionSpace",
                "activationMode": "hoverAndShortcut",
                "openDelay": "short",
                "panelSize": "standard",
                "modules": [{"tab": "media", "isEnabled": true}],
                "saveClipboardImages": true
              },
              "snippets": [],
              "notes": []
            }
            """

            let decoded = try ImpulsBackupDocument.decode(Data(json.utf8))
            XCTAssertEqual(decoded.schemaVersion, 1)
            XCTAssertEqual(decoded.settings.modules.map(\.tab), [.media])
            XCTAssertFalse(decoded.settings.persistClipboardHistory)
        }
    }

    func testUnsupportedSchemaIsRejected() async throws {
        try await MainActor.run {
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
