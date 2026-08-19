import XCTest
@testable import ImpulsCore

final class MenuBarStatusItemPresentationTests: XCTestCase {
    func testBatteryLevelColorRolesHaveExactInclusiveThresholds() {
        let expected: [(Int, MenuBarBatteryStatusPresentation.LevelColorRole)] = [
            (100, .green),
            (60, .green),
            (59, .orange),
            (20, .orange),
            (19, .red),
            (1, .red),
            (0, .red)
        ]

        for (percentage, role) in expected {
            XCTAssertEqual(
                MenuBarBatteryStatusPresentation.levelColorRole(for: percentage),
                role,
                "Unexpected colour role for \(percentage)%"
            )
        }
    }

    func testBatterySymbolsTrackTheReportedLevel() {
        let expected: [(Int, String)] = [
            (0, "battery.0"),
            (10, "battery.0"),
            (11, "battery.25"),
            (35, "battery.25"),
            (36, "battery.50"),
            (65, "battery.50"),
            (66, "battery.75"),
            (90, "battery.75"),
            (91, "battery.100percent"),
            (100, "battery.100percent")
        ]

        for (percentage, symbol) in expected {
            XCTAssertEqual(MenuBarBatteryStatusPresentation.symbolName(for: percentage), symbol)
        }
    }

    func testChargingUsesAnSFSourceBoltButChargedAndPluggedInDoNot() {
        XCTAssertEqual(presentation(72, .charging).chargingSymbolName, "bolt.fill")
        XCTAssertNil(presentation(100, .charged).chargingSymbolName)
        XCTAssertNil(presentation(72, .pluggedNotCharging).chargingSymbolName)
        XCTAssertNil(presentation(72, .discharging).chargingSymbolName)
    }

    func testBatteryStatusPresentationCannotUseTheImpulsLogoOrUnicodeBolt() {
        let battery = MenuBarBattery(identifier: "mac", title: "This Mac", percentage: 72, state: .charging)
        let status = MenuBarStatusItemPresentation(content: .battery(battery))

        XCTAssertEqual(status.image, .battery(presentation(72, .charging)))
        XCTAssertFalse(status.title.contains("⚡"))
        XCTAssertEqual(status.title, "72%")
        XCTAssertEqual(status.toolTip, "This Mac — 72% — Charging")
    }

    func testLogoAndPlayerKeepTheirExistingStatusItemPresentation() {
        XCTAssertEqual(MenuBarStatusItemPresentation(content: .logo).image, .impulsLogo)
        XCTAssertEqual(
            MenuBarStatusItemPresentation(
                content: .player(.init(title: "Track", subtitle: "Artist", isPlaying: true))
            ).image,
            .impulsLogo
        )
    }

    private func presentation(
        _ percentage: Int,
        _ state: MenuBarBattery.State
    ) -> MenuBarBatteryStatusPresentation {
        MenuBarBatteryStatusPresentation(
            battery: .init(identifier: "battery", title: "Battery", percentage: percentage, state: state)
        )
    }
}
