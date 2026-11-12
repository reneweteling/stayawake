import XCTest
@testable import StayAwakeCore

final class SafetyPresetTests: XCTestCase {
    func testDefaultsAreBalanced() {
        XCTAssertEqual(SafetyPreset.matching(Config()), .balanced)
        XCTAssertEqual(SafetyPreset.balanced.apply(to: Config()), Config())
    }

    func testEachPresetRoundTrips() {
        for preset in SafetyPreset.allCases {
            let c = preset.apply(to: Config())
            XCTAssertEqual(SafetyPreset.matching(c), preset)
            XCTAssertEqual(c.clamped(), c, "\(preset) is inside the config ranges")
        }
    }

    func testCautiousIsStricterThanRelaxed() {
        let cautious = SafetyPreset.cautious.apply(to: Config())
        let relaxed = SafetyPreset.relaxed.apply(to: Config())
        XCTAssertLessThan(cautious.cpuLimit, relaxed.cpuLimit)
        XCTAssertLessThan(cautious.gpuLimit, relaxed.gpuLimit)
        XCTAssertLessThan(cautious.batteryTempLimit, relaxed.batteryTempLimit)
        XCTAssertLessThan(cautious.thermalLimit, relaxed.thermalLimit)
        XCTAssertGreaterThan(cautious.floorPercent, relaxed.floorPercent)
        XCTAssertLessThan(cautious.cpuSustainSeconds, relaxed.cpuSustainSeconds)
        XCTAssertLessThan(cautious.gpuSustainSeconds, relaxed.gpuSustainSeconds)
        XCTAssertLessThanOrEqual(cautious.batteryTempSustainSeconds, relaxed.batteryTempSustainSeconds)
        XCTAssertTrue(cautious.batteryHeatingEnabled)
        XCTAssertFalse(relaxed.batteryHeatingEnabled)
    }

    func testPresetsAreOrdered() {
        let c = SafetyPreset.cautious.apply(to: Config())
        let b = SafetyPreset.balanced.apply(to: Config())
        let r = SafetyPreset.relaxed.apply(to: Config())
        XCTAssertLessThanOrEqual(c.cpuLimit, b.cpuLimit); XCTAssertLessThanOrEqual(b.cpuLimit, r.cpuLimit)
        XCTAssertLessThanOrEqual(c.gpuLimit, b.gpuLimit); XCTAssertLessThanOrEqual(b.gpuLimit, r.gpuLimit)
        XCTAssertLessThanOrEqual(c.batteryTempLimit, b.batteryTempLimit); XCTAssertLessThanOrEqual(b.batteryTempLimit, r.batteryTempLimit)
        XCTAssertLessThanOrEqual(c.cpuSustainSeconds, b.cpuSustainSeconds); XCTAssertLessThanOrEqual(b.cpuSustainSeconds, r.cpuSustainSeconds)
    }

    func testPresetTable() {
        typealias Row = (cpu: Double, cpuWait: Int, gpu: Double, gpuWait: Int, battery: Double, batteryWait: Int,
                         thermal: ThermalLevel, thermalWait: Int, heating: Bool)
        let table: [SafetyPreset: Row] = [
            .cautious: (95, 60, 90, 60, 40, 30, .serious, 60, true),
            .balanced: (100, 120, 95, 120, 43, 60, .serious, 300, false),
            .relaxed: (106, 180, 105, 180, 45, 60, .critical, 300, false),
        ]
        for (preset, row) in table {
            let c = preset.apply(to: Config())
            XCTAssertEqual(c.cpuLimit, row.cpu, "\(preset)"); XCTAssertEqual(c.cpuSustainSeconds, row.cpuWait, "\(preset)")
            XCTAssertEqual(c.gpuLimit, row.gpu, "\(preset)"); XCTAssertEqual(c.gpuSustainSeconds, row.gpuWait, "\(preset)")
            XCTAssertEqual(c.batteryTempLimit, row.battery, "\(preset)")
            XCTAssertEqual(c.batteryTempSustainSeconds, row.batteryWait, "\(preset)")
            XCTAssertEqual(c.thermalLimit, row.thermal, "\(preset)")
            XCTAssertEqual(c.thermalSustainSeconds, row.thermalWait, "\(preset)")
            XCTAssertEqual(c.batteryHeatingEnabled, row.heating, "\(preset)")
            XCTAssertEqual(c.batteryHeatingRise, 2, "\(preset)")
            XCTAssertEqual(c.cpuClearMargin, 10); XCTAssertEqual(c.batteryTempClearMargin, 3)
        }
    }

    func testEditedWaitIsCustomButAnUnusedOneIsNot() {
        var c = Config()
        c.cpuSustainSeconds = 90
        XCTAssertNil(SafetyPreset.matching(c))
        // Relaxed stops at critical only, so its thermal wait does nothing.
        c = SafetyPreset.relaxed.apply(to: Config())
        c.thermalSustainSeconds = 120
        XCTAssertEqual(SafetyPreset.matching(c), .relaxed)
        // The heating rise only matters while that rule is on.
        c = Config()
        c.batteryHeatingRise = 4
        XCTAssertEqual(SafetyPreset.matching(c), .balanced)
        c = SafetyPreset.cautious.apply(to: Config())
        c.batteryHeatingRise = 4
        XCTAssertNil(SafetyPreset.matching(c))
    }

    func testEditedLimitIsCustom() {
        var c = Config()
        c.cpuLimit = 88
        XCTAssertNil(SafetyPreset.matching(c))
        c = Config()
        c.gpuEnabled = false
        XCTAssertNil(SafetyPreset.matching(c))
    }

    func testPresetLeavesOtherSettingsAlone() {
        var c = Config()
        c.capHours = 3
        c.cpuClearMargin = 7
        c.schedule = .off
        let applied = SafetyPreset.cautious.apply(to: c)
        XCTAssertEqual(applied.capHours, 3)
        XCTAssertEqual(applied.cpuClearMargin, 7)
        XCTAssertEqual(applied.schedule, .off)
        XCTAssertEqual(SafetyPreset.matching(applied), .cautious)
    }
}
