import XCTest
@testable import ImpulsCore

final class ThemeTests: XCTestCase {
    /// `NotchButtonStyle` draws its own foreground rather than relying on
    /// SwiftUI's automatic disabled-dimming, so this mapping is the only
    /// thing that makes a disabled button in that style look different from
    /// an enabled one. A UI consistency audit found every `NotchButtonStyle`
    /// button — including the capability-gated Music transport controls —
    /// rendered identically regardless of `.disabled(...)`.
    func testDisabledForegroundDiffersFromEnabled() {
        XCTAssertNotEqual(Theme.foregroundColor(isEnabled: true), Theme.foregroundColor(isEnabled: false))
        XCTAssertEqual(Theme.foregroundColor(isEnabled: true), Theme.primary)
        XCTAssertEqual(Theme.foregroundColor(isEnabled: false), Theme.tertiary)
    }
}
