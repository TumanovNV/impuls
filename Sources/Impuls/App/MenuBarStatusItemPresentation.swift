import Foundation

/// The information that may appear in the one compact status item.
///
/// The workspace resolver decides *which* existing local value is relevant.
/// This type decides only how that resolved value is expressed, so the AppKit
/// controller cannot accidentally bring the Impuls logo or Unicode emoji back
/// into a battery status item.
struct MenuBarStatusItemPresentation: Equatable {
    enum Image: Equatable {
        case impulsLogo
        case battery(MenuBarBatteryStatusPresentation)
    }

    let image: Image
    let title: String
    let toolTip: String
    let usesVariableLength: Bool

    init(content: MenuBarWorkspaceContent) {
        switch content {
        case .logo:
            image = .impulsLogo
            title = ""
            toolTip = "Impuls"
            usesVariableLength = false
        case .battery(let battery):
            let presentation = MenuBarBatteryStatusPresentation(battery: battery)
            image = .battery(presentation)
            title = presentation.percentageText ?? ""
            toolTip = Self.batteryDescription(battery)
            usesVariableLength = true
        case .player(let player):
            image = .impulsLogo
            title = player.isPlaying ? " ♪" : " ♫"
            toolTip = player.subtitle.isEmpty ? player.title : "\(player.title) — \(player.subtitle)"
            usesVariableLength = true
        }
    }

    private static func batteryDescription(_ battery: MenuBarBattery) -> String {
        var values = [battery.title]
        if let percentage = battery.percentage { values.append("\(percentage)%") }
        if let state = battery.state.title { values.append(state) }
        return values.joined(separator: " — ")
    }
}

/// A system-symbol description of a selected battery, independent of AppKit
/// drawing. The same presentation serves This Mac and an external Apple device;
/// neither source gets a parallel status-item rendering path.
struct MenuBarBatteryStatusPresentation: Equatable {
    enum LevelColorRole: Equatable {
        case green
        case orange
        case red
    }

    let symbolName: String
    let levelColorRole: LevelColorRole?
    let percentageText: String?
    let chargingSymbolName: String?

    init(battery: MenuBarBattery) {
        symbolName = Self.symbolName(for: battery.percentage)
        levelColorRole = Self.levelColorRole(for: battery.percentage)
        percentageText = battery.percentage.map { "\($0)%" }
        chargingSymbolName = battery.state == .charging ? "bolt.fill" : nil
    }

    static func symbolName(for percentage: Int?) -> String {
        guard let percentage else { return "battery.0" }
        switch percentage {
        case 0...10: return "battery.0"
        case 11...35: return "battery.25"
        case 36...65: return "battery.50"
        case 66...90: return "battery.75"
        default: return "battery.100percent"
        }
    }

    static func levelColorRole(for percentage: Int?) -> LevelColorRole? {
        guard let percentage else { return nil }
        switch percentage {
        case 60...: return .green
        case 20...59: return .orange
        default: return .red
        }
    }
}
