import XCTest
@testable import ImpulsCore

@MainActor
final class PowerMonitorTests: XCTestCase {
    func testChargingBatteryKeepsTimeAndBatteryPowerSeparateFromAdapterRating() {
        let reading = PowerSourceReading.portable(
            providing: .ac,
            state: .ac,
            current: 72,
            maximum: 100,
            design: 5_000,
            charged: false,
            charging: true,
            timeToFull: 49,
            voltage: 11_500,
            amperage: 3_200,
            temperature: 33.6,
            cycles: 41,
            adapterWatts: 70
        )

        let snapshot = PowerNormalizer.snapshot(from: reading)

        XCTAssertEqual(snapshot.deviceKind, .portable)
        XCTAssertEqual(snapshot.batteryPercentage, 72)
        XCTAssertEqual(snapshot.batteryState, .charging)
        XCTAssertEqual(snapshot.timeToFullCharge, .minutes(49))
        XCTAssertEqual(snapshot.batteryPowerWatts ?? 0, 36.8, accuracy: 0.01)
        XCTAssertEqual(snapshot.adapterRatedPowerWatts, 70)
        XCTAssertEqual(snapshot.temperatureCelsius, 33.6)
        XCTAssertEqual(snapshot.cycleCount, 41)
    }

    func testChargingTimeCalculatingDoesNotBecomeNegativeMinutes() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .ac,
            state: .ac,
            charging: true,
            timeToFull: -1
        ))

        XCTAssertEqual(snapshot.timeToFullCharge, .calculating)
        XCTAssertEqual(PowerTimeFormatter.string(for: snapshot.timeToFullCharge), "Calculating…")
    }

    func testChargedBatteryDoesNotNeedAZeroMinuteEstimate() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .ac,
            state: .ac,
            charged: true,
            charging: false,
            timeToFull: 0
        ))

        XCTAssertEqual(snapshot.batteryState, .charged)
        XCTAssertEqual(snapshot.timeToFullCharge, .minutes(0))
    }

    func testChargedBatteryReportsZeroPowerInsteadOfAnUnavailableValue() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .ac,
            state: .ac,
            charged: true,
            charging: false,
            voltage: 12_000,
            amperage: 0
        ))

        XCTAssertEqual(snapshot.batteryPowerWatts, 0)
    }

    func testPluggedInButNotChargingIsNotReportedAsDischarging() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .ac,
            state: .ac,
            charged: false,
            charging: false
        ))

        XCTAssertEqual(snapshot.batteryState, .pluggedNotCharging)
        XCTAssertNil(snapshot.batteryPowerWatts)
    }

    func testDischargingBatteryUsesTimeToEmptyAndNormalizesNegativeCurrent() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .battery,
            state: .battery,
            charged: false,
            charging: false,
            timeToEmpty: 222,
            voltage: 12_000,
            amperage: -700
        ))

        XCTAssertEqual(snapshot.batteryState, .discharging)
        XCTAssertEqual(snapshot.timeToEmpty, .minutes(222))
        XCTAssertEqual(snapshot.batteryCurrentMilliamps, 700)
        XCTAssertEqual(snapshot.batteryPowerWatts ?? 0, 8.4, accuracy: 0.01)
    }

    func testUnknownTimeAndInvalidNumbersStayUnavailable() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            providing: .battery,
            state: .battery,
            charged: false,
            charging: false,
            timeToEmpty: -7,
            voltage: -1,
            amperage: Int.min,
            temperature: 10_000,
            cycles: -1
        ))

        XCTAssertEqual(snapshot.timeToEmpty, .unavailable)
        XCTAssertNil(snapshot.batteryPowerWatts)
        XCTAssertNil(snapshot.temperatureCelsius)
        XCTAssertNil(snapshot.cycleCount)
    }

    func testSmartBatteryTenthsOfKelvinAreNormalizedToCelsius() {
        let snapshot = PowerNormalizer.snapshot(from: .portable(
            temperature: 3_056
        ))

        XCTAssertEqual(snapshot.temperatureCelsius ?? 0, 32.45, accuracy: 0.01)
    }

    func testCapacityHealthNeedsBothPositiveCapacities() {
        XCTAssertEqual(
            PowerNormalizer.capacityHealthPercent(fullChargeCapacity: 4_950, designCapacity: 5_000) ?? -1,
            99,
            accuracy: 0.0001
        )
        XCTAssertNil(PowerNormalizer.capacityHealthPercent(fullChargeCapacity: 4_950, designCapacity: nil))
        XCTAssertNil(PowerNormalizer.capacityHealthPercent(fullChargeCapacity: 4_950, designCapacity: 0))
        XCTAssertNil(PowerNormalizer.capacityHealthPercent(fullChargeCapacity: -1, designCapacity: 5_000))
    }

    func testCapacityHealthAboveOneHundredRemainsAValidReading() {
        let health = PowerNormalizer.capacityHealthPercent(fullChargeCapacity: 5_050, designCapacity: 5_000)
        XCTAssertEqual(health ?? 0, 101, accuracy: 0.0001)
    }

    func testCapacityHealthHidesIncompatibleCapacityScales() {
        XCTAssertNil(
            PowerNormalizer.capacityHealthPercent(fullChargeCapacity: 100, designCapacity: 5_000)
        )
    }

    func testReliableConnectionEvidenceIsPreservedWithoutGuessingUnknown() {
        var reading = PowerSourceReading.portable(providing: .ac, state: .ac, charging: true)
        reading.connectionType = .magSafe
        XCTAssertEqual(PowerNormalizer.snapshot(from: reading).connectionType, .magSafe)

        reading.connectionType = .usbC
        XCTAssertEqual(PowerNormalizer.snapshot(from: reading).connectionType, .usbC)

        reading.connectionType = .unknown
        XCTAssertEqual(PowerNormalizer.snapshot(from: reading).connectionType, .unknown)

        reading.connectionType = .externalPower
        XCTAssertEqual(PowerNormalizer.snapshot(from: reading).connectionType, .externalPower)

        reading.connectionType = .unplugged
        XCTAssertEqual(PowerNormalizer.snapshot(from: reading).connectionType, .unplugged)
    }

    func testConnectionDetectorReportsOnlyTheEvidenceAvailableFromIOKit() {
        XCTAssertEqual(
            ChargeConnectionDetector.currentConnection(providingPowerSource: .ac, adapterDetails: nil),
            .externalPower
        )
        XCTAssertEqual(
            ChargeConnectionDetector.currentConnection(providingPowerSource: .battery, adapterDetails: nil),
            .unplugged
        )
        XCTAssertEqual(
            ChargeConnectionDetector.currentConnection(providingPowerSource: .unknown, adapterDetails: nil),
            .unknown
        )
    }

    func testDesktopDoesNotExposeBatteryCardsOrInventWallPower() {
        let snapshot = PowerNormalizer.snapshot(from: .unavailableDesktop)

        XCTAssertEqual(snapshot.deviceKind, .desktop)
        XCTAssertNil(snapshot.batteryPercentage)
        XCTAssertNil(snapshot.batteryPowerWatts)
        XCTAssertNil(snapshot.adapterRatedPowerWatts)
    }

    func testTimeFormatterUsesCompactMinutesAndHours() {
        XCTAssertEqual(PowerTimeFormatter.string(for: .minutes(49)), "49 min")
        XCTAssertEqual(PowerTimeFormatter.string(for: .minutes(84)), "1 h 24 min")
        XCTAssertEqual(PowerTimeFormatter.string(for: .unavailable), "—")
    }

    func testMonitorDoesNotPollOrObserveWhenDisabledAndDoesNotDuplicateLifecycle() {
        let provider = FakePowerProvider(snapshot: PowerNormalizer.snapshot(from: .portable()))
        let monitor = PowerMonitor(provider: provider)

        monitor.setActive(true)
        XCTAssertEqual(provider.snapshotCalls, 0)
        XCTAssertEqual(provider.startObservingCalls, 0)
        XCTAssertFalse(monitor.isLiveMonitoring)

        monitor.setEnabled(true)
        XCTAssertEqual(provider.snapshotCalls, 1)
        XCTAssertEqual(provider.startObservingCalls, 1)
        XCTAssertTrue(monitor.isLiveMonitoring)

        monitor.setActive(true)
        XCTAssertEqual(provider.startObservingCalls, 1)

        provider.emitChange()
        XCTAssertEqual(provider.snapshotCalls, 2)

        monitor.setEnabled(false)
        XCTAssertEqual(provider.stopObservingCalls, 1)
        XCTAssertFalse(monitor.isLiveMonitoring)

        provider.emitChange()
        XCTAssertEqual(provider.snapshotCalls, 2)
    }
}

private extension PowerSourceReading {
    static func portable(
        providing: SystemPowerSource = .battery,
        state: SystemPowerSource = .battery,
        current: Int? = 72,
        maximum: Int? = 100,
        design: Int? = 5_000,
        charged: Bool? = false,
        charging: Bool? = false,
        finishing: Bool? = false,
        timeToEmpty: Int? = nil,
        timeToFull: Int? = nil,
        voltage: Int? = nil,
        amperage: Int? = nil,
        temperature: Double? = nil,
        cycles: Int? = nil,
        adapterWatts: Double? = nil
    ) -> PowerSourceReading {
        PowerSourceReading(
            providingPowerSource: providing,
            hasInternalBattery: true,
            batteryPowerSourceState: state,
            currentCapacity: current,
            maxCapacity: maximum,
            designCapacity: design,
            isCharging: charging,
            isCharged: charged,
            isFinishingCharge: finishing,
            timeToEmptyMinutes: timeToEmpty,
            timeToFullChargeMinutes: timeToFull,
            voltageMillivolts: voltage,
            currentMilliamps: amperage,
            temperatureCelsius: temperature,
            systemBatteryCondition: nil,
            cycleCount: cycles,
            adapterRatedPowerWatts: adapterWatts,
            connectionType: .unknown
        )
    }
}

@MainActor
private final class FakePowerProvider: PowerSourceObserving {
    var currentSnapshot: PowerSnapshot
    private(set) var snapshotCalls = 0
    private(set) var startObservingCalls = 0
    private(set) var stopObservingCalls = 0
    private var onChange: (() -> Void)?

    init(snapshot: PowerSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() -> PowerSnapshot {
        snapshotCalls += 1
        return currentSnapshot
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        startObservingCalls += 1
        self.onChange = onChange
    }

    func stopObserving() {
        stopObservingCalls += 1
        onChange = nil
    }

    func emitChange() {
        onChange?()
    }
}
