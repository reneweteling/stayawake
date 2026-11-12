import XCTest
@testable import StayAwakeCore

final class ForecastTests: XCTestCase {
    func samples(percentPerMinute: Double, minutes: Int, start: Int = 80) -> [DrainSample] {
        (0...minutes).map { DrainSample(monotonic: 1000 + Double($0) * 60, percent: start - Int((Double($0) * percentPerMinute).rounded())) }
    }

    func testDrainSlopeOfSteadyDrain() {
        let s = samples(percentPerMinute: 1, minutes: 8)
        let slope = Forecast.drainSlope(samples: s, now: 1000 + 8 * 60)
        XCTAssertEqual(slope!, -1.0 / 60, accuracy: 0.0005)
    }

    func testOnlyTheLastTenMinutesCount() {
        // Fast drain long ago, flat for the last 10 minutes.
        var s = samples(percentPerMinute: 2, minutes: 5)
        s += (6...20).map { DrainSample(monotonic: 1000 + Double($0) * 60, percent: 70) }
        let slope = Forecast.drainSlope(samples: s, now: 1000 + 20 * 60)
        XCTAssertEqual(slope!, 0, accuracy: 0.0001)
    }

    func testNoEstimateWhenDataIsShort() {
        XCTAssertNil(Forecast.drainSlope(samples: [], now: 0))
        XCTAssertNil(Forecast.drainSlope(samples: [DrainSample(monotonic: 0, percent: 80)], now: 0))
        let tooClose = [DrainSample(monotonic: 0, percent: 80), DrainSample(monotonic: 60, percent: 79)]
        XCTAssertNil(Forecast.drainSlope(samples: tooClose, now: 60), "span under 2 minutes")
    }

    func testTimeToFloor() {
        // 1 percent per minute, 10 points above the floor: 10 minutes.
        XCTAssertEqual(Forecast.timeToFloor(percent: 30, floor: 20, slope: -1.0 / 60)!, 600, accuracy: 0.01)
        XCTAssertEqual(Forecast.timeToFloor(percent: 20, floor: 20, slope: -1.0 / 60), 0)
        XCTAssertNil(Forecast.timeToFloor(percent: 50, floor: 20, slope: 0.001), "charging")
        XCTAssertNil(Forecast.timeToFloor(percent: 50, floor: 20, slope: 0))
        XCTAssertNil(Forecast.timeToFloor(percent: 50, floor: 20, slope: nil))
    }

    func testEngineEstimatesTimeToFloorFromDrain() {
        var rig = Rig()
        rig.snap.batteryPercent = 80
        rig.arm()
        // Drop one point per minute for 10 minutes.
        for minute in 1...10 {
            rig.snap.batteryPercent = 80 - minute
            rig.now = rig.now.advanced(by: 60)
            rig.snap.cpuTemperature = 50 + Double(minute % 2)
            rig.snap.batteryTemperature = 30 + Double(minute % 2) * 0.1
            rig.eval()
        }
        let floor = rig.last!.margins.first { $0.rule == .batteryFloor }
        XCTAssertEqual(floor!.seconds!, 50 * 60, accuracy: 120, "70 percent now, floor at 20, one point per minute")
        XCTAssertEqual(rig.last!.timeLeft!, floor!.seconds!, accuracy: 1)
    }

    func testNoFloorEstimateWithoutEnoughData() {
        var rig = Rig()
        rig.arm()
        XCTAssertNil(rig.last!.margins.first { $0.rule == .batteryFloor }?.seconds)
    }

    func testRankingWarningBandFirstThenTimeThenDistance() {
        let margins = [
            RuleMargin(rule: .cpuTemperature, fraction: 0.4, seconds: nil, detail: ""),
            RuleMargin(rule: .lidOnBattery, fraction: 0.5, seconds: 2520, detail: ""),
            RuleMargin(rule: .schedule, fraction: 1, seconds: 6480, detail: ""),
            RuleMargin(rule: .batteryFloor, fraction: 0.6, seconds: 8400, detail: ""),
            RuleMargin(rule: .batteryTemperature, fraction: 0.05, seconds: nil, detail: ""),
            RuleMargin(rule: .gpuTemperature, fraction: 0.2, seconds: nil, detail: ""),
        ]
        XCTAssertEqual(Forecast.rank(margins).map(\.rule),
                       [.batteryTemperature, .lidOnBattery, .schedule, .batteryFloor, .gpuTemperature, .cpuTemperature])
    }

    func testNextToTripReturnsTheFirstThree() {
        let margins = RuleID.allCases.prefix(6).enumerated().map {
            RuleMargin(rule: $1, fraction: 1, seconds: Double(100 - $0), detail: "")
        }
        let next = Forecast.nextToTrip(margins)
        XCTAssertEqual(next.count, 3)
        XCTAssertEqual(next.map(\.seconds), [95, 96, 97])
    }

    func testRankingTiesBreakByRulePriority() {
        let a = RuleMargin(rule: .idle, fraction: 1, seconds: 100, detail: "")
        let b = RuleMargin(rule: .lidOnBattery, fraction: 1, seconds: 100, detail: "")
        XCTAssertEqual(Forecast.rank([a, b]).map(\.rule), [.lidOnBattery, .idle])
    }

    func testTimeLeftUsesOnlyCapScheduleLidAndFloor() {
        let margins = [
            RuleMargin(rule: .idle, fraction: 1, seconds: 30, detail: ""),
            RuleMargin(rule: .hardCap, fraction: 1, seconds: 5000, detail: ""),
            RuleMargin(rule: .schedule, fraction: 1, seconds: 4000, detail: ""),
            RuleMargin(rule: .cpuTemperature, fraction: 1, seconds: nil, detail: ""),
        ]
        XCTAssertEqual(Forecast.timeLeft(margins), 4000)
        XCTAssertNil(Forecast.timeLeft([RuleMargin(rule: .cpuTemperature, fraction: 1, seconds: nil, detail: "")]))
    }

    func testWarningsListRulesWithinTenPercent() {
        var rig = Rig()
        rig.snap.cpuTemperature = 95   // 5 percent below 100
        rig.snap.batteryPercent = 80
        rig.arm()
        XCTAssertEqual(rig.last!.warnings, [.cpuTemperature])
    }
}
