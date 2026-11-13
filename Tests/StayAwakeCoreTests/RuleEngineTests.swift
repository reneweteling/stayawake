import XCTest
@testable import StayAwakeCore

final class RuleEngineTests: XCTestCase {

    // MARK: Temperature rules

    /// Sustain and hysteresis on their own: smoothing off, a 20 s wait.
    private func mechanics(_ c: inout Config) {
        c.smoothingSeconds = 0
        c.cpuSustainSeconds = 20
        c.gpuSustainSeconds = 20
    }

    func testCpuTripsAtLimitAfterSustain() {
        var rig = Rig(tweak: mechanics)
        rig.arm()
        XCTAssertEqual(rig.last?.phase, .holding)
        rig.snap.cpuTemperature = 102
        let ds = rig.advance(30, step: 10, jitter: false)
        XCTAssertEqual(ds[0].phase, .holding)
        XCTAssertEqual(ds[1].phase, .holding)
        XCTAssertEqual(ds[2].phase, .tripped, "exactly 20 s at the limit")
        XCTAssertEqual(ds[2].trip?.rule, .cpuTemperature)
        XCTAssertEqual(ds[2].action, .release)
    }

    func testCpuDoesNotTripBelowLimit() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = 99.9
        let ds = rig.advance(600)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
    }

    func testSpikeShorterThanSustainDoesNotTrip() {
        var rig = Rig(tweak: mechanics)
        rig.arm()
        rig.snap.cpuTemperature = 102
        rig.advance(10, step: 10, jitter: false)
        rig.snap.cpuTemperature = 60
        rig.advance(10, step: 10, jitter: false)
        rig.snap.cpuTemperature = 102
        let ds = rig.advance(10, step: 10, jitter: false)
        XCTAssertEqual(ds.last?.phase, .holding, "the counter started over")
    }

    func testZeroSustainTripsImmediately() {
        var rig = Rig(tweak: { $0.cpuSustainSeconds = 0; $0.smoothingSeconds = 0 })
        rig.arm()
        rig.snap.cpuTemperature = 102
        XCTAssertEqual(rig.eval().phase, .tripped)
    }

    func testCpuHysteresisKeepsRuleFailingUntilClearsAt() {
        var rig = Rig(tweak: mechanics)
        rig.config.cpuSustainSeconds = 0
        rig.arm()
        rig.snap.cpuTemperature = 107
        XCTAssertEqual(rig.eval().phase, .tripped)
        rig.snap.cpuTemperature = 95
        XCTAssertEqual(rig.advance(15, jitter: false).last?.rules, [.cpuTemperature], "still above 90")
        rig.snap.cpuTemperature = 90.5
        XCTAssertEqual(rig.advance(15, jitter: false).last?.rules, [.cpuTemperature])
        rig.snap.cpuTemperature = 90
        XCTAssertEqual(rig.advance(15, jitter: false).last?.rules, [], "clears at limit minus 10")
    }

    func testArmRefusedWhileLatchedAboveClearsAt() {
        var rig = Rig(tweak: mechanics)
        rig.config.cpuSustainSeconds = 0
        rig.arm()
        rig.snap.cpuTemperature = 107
        rig.eval()
        rig.snap.cpuTemperature = 97
        let refused = rig.arm()
        guard case .refused(let reasons) = refused.outcome else { return XCTFail("expected refusal") }
        XCTAssertEqual(reasons.map(\.rule), [.cpuTemperature])
        XCTAssertEqual(rig.state.phase, .tripped, "refused arm leaves the state alone")
        rig.snap.cpuTemperature = 87
        rig.eval()
        XCTAssertEqual(rig.arm().outcome, .holding)
    }

    func testGpuTripsLikeCpu() {
        var rig = Rig(tweak: mechanics)
        rig.arm()
        rig.snap.gpuTemperature = 95
        let ds = rig.advance(30, step: 10, jitter: false)
        XCTAssertEqual(ds[1].phase, .holding)
        XCTAssertEqual(ds[2].phase, .tripped)
        XCTAssertEqual(ds[2].trip?.rule, .gpuTemperature)
        XCTAssertEqual(ds[2].trip?.shortReason, "GPU HOT")
    }

    func testGpuBelowLimitHysteresisAndSpike() {
        var rig = Rig(tweak: { $0.gpuSustainSeconds = 0; $0.smoothingSeconds = 0 })
        rig.arm()
        rig.snap.gpuTemperature = 94.9
        XCTAssertEqual(rig.eval().phase, .holding)
        rig.snap.gpuTemperature = 95
        XCTAssertEqual(rig.eval().phase, .tripped)
        rig.snap.gpuTemperature = 86
        XCTAssertEqual(rig.eval().rules, [.gpuTemperature])
        rig.snap.gpuTemperature = 85
        XCTAssertEqual(rig.eval().rules, [])
    }

    func testMissingGpuNeverTripsSensorFailure() {
        var rig = Rig()
        rig.snap.gpuTemperature = nil
        rig.arm()
        let ds = rig.advance(1800)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
    }

    func testGpuIncludedInNextToTrip() {
        var rig = Rig()
        rig.snap.gpuTemperature = 92
        rig.snap.cpuTemperature = 50
        rig.arm()
        let d = rig.eval()
        XCTAssertEqual(d.nextToTrip.first?.rule, .gpuTemperature)
        XCTAssertTrue(d.warnings.contains(.gpuTemperature))
    }

    func testDisabledGpuRuleIsIgnored() {
        var rig = Rig(tweak: { $0.gpuEnabled = false; $0.gpuSustainSeconds = 0 })
        rig.snap.gpuTemperature = 109
        rig.arm()
        XCTAssertEqual(rig.eval().phase, .holding)
        XCTAssertFalse(rig.last!.margins.contains { $0.rule == .gpuTemperature })
    }

    func testBatteryTemperatureTripsAtLimitAfterSustain() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryTemperature = 43
        let ds = rig.advance(70, step: 10, jitter: false)
        XCTAssertEqual(ds[5].phase, .holding, "50 s at the limit")
        XCTAssertEqual(ds[6].trip?.rule, .batteryTemperature, "60 s at the limit")
    }

    func testBatteryTemperatureClearsAtThreeDegreesBelow() {
        var rig = Rig(tweak: { $0.batteryTempSustainSeconds = 0 })
        rig.arm()
        rig.snap.batteryTemperature = 44
        rig.eval()
        rig.snap.batteryTemperature = 40.5
        XCTAssertEqual(rig.eval().rules, [.batteryTemperature])
        rig.snap.batteryTemperature = 40
        XCTAssertEqual(rig.eval().rules, [])
    }

    func testThermalSeriousTripsOnlyAfterFiveMinutes() {
        var rig = Rig()
        rig.arm()
        rig.snap.thermal = .fair
        XCTAssertEqual(rig.eval().phase, .holding)
        rig.snap.thermal = .serious
        XCTAssertEqual(rig.eval().phase, .holding, "serious starts the 5 minute wait")
        let ds = rig.advance(300)
        XCTAssertEqual(ds[18].phase, .holding, "285 s serious")
        XCTAssertEqual(ds[19].trip?.rule, .thermalPressure, "300 s serious")
        XCTAssertTrue(ds[19].trip!.message.contains("for 300 s"), ds[19].trip!.message)
    }

    func testThermalSeriousThatDropsBackStartsOver() {
        var rig = Rig()
        rig.arm()
        rig.snap.thermal = .serious
        rig.advance(240)
        rig.snap.thermal = .fair
        rig.eval()
        rig.snap.thermal = .serious
        XCTAssertTrue(rig.advance(240).allSatisfy { $0.phase == .holding })
        XCTAssertNotNil(rig.last!.margins.first { $0.rule == .thermalPressure }?.seconds, "the wait shows as time left")
    }

    func testThermalCriticalTripsAtOnce() {
        var rig = Rig()
        rig.arm()
        rig.snap.thermal = .critical
        XCTAssertEqual(rig.eval().trip?.rule, .thermalPressure)
        var relaxed = Rig(tweak: { $0.thermalLimit = .critical })
        relaxed.arm()
        relaxed.snap.thermal = .serious
        XCTAssertTrue(relaxed.advance(900).allSatisfy { $0.phase == .holding }, "critical only")
        relaxed.snap.thermal = .critical
        XCTAssertEqual(relaxed.eval().trip?.rule, .thermalPressure)
    }

    func testThermalSeriousWaitIsConfigurable() {
        var rig = Rig(tweak: { $0.thermalSustainSeconds = 60 })
        rig.arm()
        rig.snap.thermal = .serious
        let ds = rig.advance(75)
        XCTAssertEqual(ds[3].phase, .holding, "45 s serious")
        XCTAssertEqual(ds[4].trip?.rule, .thermalPressure, "60 s serious")
    }

    func testThermalLimitFairTripsAtFair() {
        var rig = Rig(tweak: { $0.thermalLimit = .fair; $0.thermalSustainSeconds = 0 })
        rig.arm()
        rig.snap.thermal = .fair
        XCTAssertEqual(rig.eval().trip?.rule, .thermalPressure)
    }

    // MARK: Battery floor

    func testBatteryFloorTripsBelowNotAt() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryPercent = 40
        XCTAssertEqual(rig.eval().phase, .holding)
        rig.snap.batteryPercent = 39
        let d = rig.eval()
        XCTAssertEqual(d.trip?.rule, .batteryFloor)
        XCTAssertEqual(d.trip?.shortReason, "LOW 39%")
    }

    func testBatteryFloorIgnoredWhileCharging() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryPercent = 10
        rig.snap.isCharging = true
        XCTAssertEqual(rig.eval().phase, .holding)
    }

    func testBatteryFloorHysteresisNeedsTenPoints() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryPercent = 39
        rig.eval()
        rig.snap.batteryPercent = 49
        XCTAssertEqual(rig.eval().rules, [.batteryFloor])
        rig.snap.batteryPercent = 50
        XCTAssertEqual(rig.eval().rules, [])
    }

    func testBatteryFloorClearsWhenCharging() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryPercent = 35
        rig.eval()
        rig.snap.isCharging = true
        XCTAssertEqual(rig.eval().rules, [])
    }

    func testArmRefusedWhenFloorAboveCurrentLevel() {
        var rig = Rig(tweak: { $0.floorPercent = 60 })
        rig.snap.batteryPercent = 50
        let r = rig.arm()
        guard case .refused(let reasons) = r.outcome else { return XCTFail("expected refusal") }
        XCTAssertEqual(reasons.first?.rule, .batteryFloor)
        XCTAssertEqual(r.state.phase, .off)
        XCTAssertEqual(r.decision.action, .none)
    }

    // MARK: Fail closed

    func testMissingCpuReadingTripsAfterSensorFailureTime() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = nil
        let ds = rig.advance(75, step: 15)
        XCTAssertEqual(ds[3].phase, .holding, "45 s without a reading")
        XCTAssertEqual(ds[4].trip?.rule, .sensorFailure, "60 s without a reading")
        XCTAssertEqual(ds[4].trip?.shortReason, "SENSOR")
    }

    func testImplausibleReadingsCountAsMissing() {
        for bad in [-5.0, 131.0, 400.0] {
            var rig = Rig()
            rig.arm()
            rig.snap.cpuTemperature = bad
            let ds = rig.advance(90, step: 15, jitter: false)
            XCTAssertEqual(ds.compactMap(\.trip).first?.rule, .sensorFailure, "reading \(bad)")
        }
    }

    func testStuckReadingTripsAfterFiveMinutesPlusSensorFailureTime() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = 55
        let ds = rig.advance(420, step: 15, jitter: false)
        let tripIndex = ds.firstIndex { $0.phase == .tripped }
        XCTAssertNotNil(tripIndex)
        XCTAssertEqual(ds[tripIndex!].trip?.rule, .sensorFailure)
        XCTAssertGreaterThanOrEqual(Double(tripIndex! + 1) * 15, 360)
    }

    /// Display asleep on power: CPU wobbles, the battery sits on one value
    /// for half an hour. That is a healthy sensor, not a stuck one.
    func testFlatBatteryTemperatureDoesNotTripSensorFailure() {
        var rig = Rig()
        rig.snap.cpuTemperature = 55
        rig.snap.batteryTemperature = 33.4
        rig.arm()
        for n in 0..<120 {
            rig.now = rig.now.advanced(by: 15)
            rig.snap.cpuTemperature = 50 + Double(n % 7)
            rig.snap.gpuTemperature = 60 + Double(n % 5)
            let d = rig.eval()
            XCTAssertEqual(d.phase, .holding, "eval \(n)")
            XCTAssertFalse(d.rules.contains(.sensorFailure), "eval \(n)")
        }
    }

    func testMissingBatteryTemperatureStillTripsSensorFailure() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryTemperature = nil
        let ds = rig.advance(90, step: 15)
        XCTAssertEqual(ds.compactMap(\.trip).first?.rule, .sensorFailure)
    }

    /// The loop did not run for minutes (display sleep, App Nap) but every
    /// read that did happen was valid: the gap alone must not trip.
    func testSampleGapWithValidReadsDoesNotTrip() {
        var rig = Rig()
        rig.arm()
        rig.advance(60)
        rig.sleep(600)
        let ds = rig.advance(120)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
        XCTAssertFalse(ds.contains { $0.rules.contains(.sensorFailure) })
    }

    /// A failed read before a gap and one after it are not 60 s of failure:
    /// the clock starts again after the gap.
    func testFailedReadAcrossGapRestartsSensorFailureClock() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = nil
        rig.advance(30)
        rig.sleep(600)
        XCTAssertEqual(rig.eval().phase, .holding)
        rig.advance(45)
        XCTAssertEqual(rig.last?.phase, .holding)
        XCTAssertEqual(rig.advance(30).compactMap(\.trip).first?.rule, .sensorFailure)
    }

    func testConsecutiveFailedReadsForSixtySecondsTrip() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = nil
        // First failed read at +15 s, the fifth (+75 s) is 60 s after it.
        let ds = rig.advance(75, step: 15)
        XCTAssertEqual(ds.dropLast().filter { $0.phase == .tripped }.count, 0)
        XCTAssertEqual(ds.last?.trip?.rule, .sensorFailure)
    }

    /// After a sensor-failure trip on a flat battery reading, turning on
    /// again must work while the battery still reads the same value.
    func testRearmWithUnchangedBatteryTemperature() {
        var rig = Rig()
        rig.snap.cpuTemperature = 55
        rig.snap.batteryTemperature = 33.4
        rig.arm()
        for n in 0..<40 {
            rig.now = rig.now.advanced(by: 15)
            rig.snap.cpuTemperature = 50 + Double(n % 7)
            rig.eval()
        }
        rig.state = RuleEngine.disarm(rig.state).state
        let r = rig.arm()
        XCTAssertEqual(r.outcome, .holding)
    }

    func testReadingReturningClearsSensorFailure() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = nil
        rig.advance(45)
        rig.snap.cpuTemperature = 50
        let ds = rig.advance(300)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
    }

    func testSensorFailureCannotBeSwitchedOffByDisablingTemperatureRules() {
        var rig = Rig(tweak: { $0.cpuEnabled = false; $0.batteryTempEnabled = false; $0.gpuEnabled = false })
        rig.arm()
        rig.snap.cpuTemperature = nil
        XCTAssertEqual(rig.advance(75).last?.trip?.rule, .sensorFailure)
    }

    func testThermalStateOnlyPreferenceDoesNotNeedTemperatures() {
        var rig = Rig(tweak: { $0.sensorPreference = .thermalStateOnly })
        rig.snap.cpuTemperature = nil
        rig.snap.batteryTemperature = nil
        rig.arm()
        XCTAssertTrue(rig.advance(300).allSatisfy { $0.phase == .holding })
        rig.snap.thermal = .critical
        XCTAssertEqual(rig.eval().trip?.rule, .thermalPressure)
    }

    // MARK: Disabled rules

    func testDisabledRulesAreIgnored() {
        var rig = Rig(tweak: {
            $0.cpuEnabled = false; $0.batteryTempEnabled = false; $0.thermalEnabled = false
            $0.floorEnabled = false; $0.lidEnabled = false; $0.networkEnabled = false; $0.capEnabled = false
            $0.idleEnabled = false; $0.cpuSustainSeconds = 0
        })
        rig.snap.cpuTemperature = 109
        rig.snap.batteryTemperature = 49
        rig.snap.thermal = .critical
        rig.snap.batteryPercent = 6
        rig.snap.lidClosed = true
        rig.snap.networkUsable = false
        rig.snap.cpuLoadPercent = 0
        XCTAssertEqual(rig.arm().outcome, .holding)
        XCTAssertTrue(rig.advance(3 * 3600, step: 60).allSatisfy { $0.phase == .holding })
    }

    // MARK: Priority

    func testPriorityWhenSeveralRulesTrip() {
        var rig = Rig(tweak: { $0.cpuSustainSeconds = 0; $0.batteryTempSustainSeconds = 0 })
        rig.arm()
        rig.snap.cpuTemperature = 102
        rig.snap.batteryTemperature = 45
        rig.snap.batteryPercent = 10
        rig.snap.networkUsable = false
        let d = rig.eval()
        XCTAssertEqual(d.trip?.rule, .cpuTemperature)
        XCTAssertEqual(d.rules, [.cpuTemperature, .batteryTemperature, .batteryFloor])
    }

    func testPriorityHeatBeforeBatteryBeforeLid() {
        let order = RuleID.allCases
        XCTAssertLessThan(order.firstIndex(of: .cpuTemperature)!, order.firstIndex(of: .batteryFloor)!)
        XCTAssertLessThan(order.firstIndex(of: .batteryFloor)!, order.firstIndex(of: .lidOnBattery)!)
        XCTAssertLessThan(order.firstIndex(of: .sensorFailure)!, order.firstIndex(of: .hardCap)!)
        XCTAssertLessThan(order.firstIndex(of: .lidOnBattery)!, order.firstIndex(of: .idle)!)
    }

    // MARK: Time rules

    func testLidOnBatteryTripsAtNinetyMinutes() {
        var rig = Rig()
        rig.snap.lidClosed = true
        rig.snap.cpuLoadPercent = 60
        rig.arm()
        let ds = rig.advance(90 * 60, step: 60)
        XCTAssertTrue(ds.dropLast().allSatisfy { $0.phase == .holding })
        XCTAssertEqual(ds.last?.trip?.rule, .lidOnBattery)
    }

    func testLidTimerResetsWhenLidOpensOrAcConnects() {
        var rig = Rig()
        rig.snap.lidClosed = true
        rig.snap.cpuLoadPercent = 60
        rig.arm()
        rig.advance(80 * 60, step: 60)
        rig.snap.lidClosed = false
        rig.advance(60, step: 60)
        rig.snap.lidClosed = true
        XCTAssertTrue(rig.advance(80 * 60, step: 60).allSatisfy { $0.phase == .holding })
        rig.snap.powerSource = .ac
        rig.advance(60, step: 60)
        rig.snap.powerSource = .battery
        XCTAssertTrue(rig.advance(80 * 60, step: 60).allSatisfy { $0.phase == .holding })
    }

    func testIdleTripsAfterFifteenMinutesWithLidClosed() {
        var rig = Rig()
        rig.snap.lidClosed = true
        rig.snap.cpuLoadPercent = 5
        rig.arm()
        let ds = rig.advance(15 * 60, step: 60)
        XCTAssertTrue(ds.dropLast().allSatisfy { $0.phase == .holding })
        XCTAssertEqual(ds.last?.trip?.rule, .idle)
    }

    func testIdleNeverCountsWithLidOpen() {
        var rig = Rig()
        rig.snap.cpuLoadPercent = 1
        rig.arm()
        XCTAssertTrue(rig.advance(3600, step: 60).allSatisfy { $0.phase == .holding })
    }

    func testIdleHysteresisResetsOnlyAboveLimitPlusTen() {
        var rig = Rig()
        rig.snap.lidClosed = true
        rig.snap.cpuLoadPercent = 5
        rig.arm()
        rig.advance(10 * 60, step: 60)
        rig.snap.cpuLoadPercent = 15
        rig.advance(60, step: 60)
        rig.snap.cpuLoadPercent = 5
        XCTAssertEqual(rig.advance(4 * 60, step: 60).last?.trip?.rule, .idle, "15 percent did not reset the timer")

        var rig2 = Rig()
        rig2.snap.lidClosed = true
        rig2.snap.cpuLoadPercent = 5
        rig2.arm()
        rig2.advance(10 * 60, step: 60)
        rig2.snap.cpuLoadPercent = 20
        rig2.advance(60, step: 60)
        rig2.snap.cpuLoadPercent = 5
        XCTAssertTrue(rig2.advance(10 * 60, step: 60).allSatisfy { $0.phase == .holding }, "20 percent reset the timer")
    }

    func testWatchedProcessTripsAfterTwentyMinutes() {
        var rig = Rig(tweak: { $0.watchedEnabled = true })
        rig.snap.watchedProcessRunning = false
        rig.arm()
        let ds = rig.advance(20 * 60, step: 60)
        XCTAssertTrue(ds.dropLast().allSatisfy { $0.phase == .holding })
        XCTAssertEqual(ds.last?.trip?.rule, .watchedProcess)
    }

    func testWatchedProcessOffByDefault() {
        var rig = Rig()
        rig.snap.watchedProcessRunning = false
        rig.arm()
        XCTAssertTrue(rig.advance(3600, step: 60).allSatisfy { $0.phase == .holding })
    }

    func testNoNetworkTripsAfterFifteenMinutesAndRouteReturnResets() {
        var rig = Rig()
        rig.snap.networkUsable = false
        rig.arm()
        rig.advance(14 * 60, step: 60)
        rig.snap.networkUsable = true
        rig.advance(60, step: 60)
        rig.snap.networkUsable = false
        XCTAssertTrue(rig.advance(14 * 60, step: 60).allSatisfy { $0.phase == .holding })
        XCTAssertEqual(rig.advance(2 * 60, step: 60).last?.trip?.rule, .noNetwork)
    }

    func testHardCapTripsAtEightHours() {
        var rig = Rig()
        rig.arm()
        let ds = rig.advance(8 * 3600, step: 15)
        XCTAssertTrue(ds.dropLast().allSatisfy { $0.phase == .holding })
        XCTAssertEqual(ds.last?.trip?.rule, .hardCap)
        XCTAssertEqual(ds.last?.trip?.shortReason, "CAP 8h")
    }

    // MARK: Sleep gap

    func testSleepGapResetsSustain() {
        var rig = Rig(tweak: mechanics)
        rig.arm()
        rig.snap.cpuTemperature = 102
        rig.eval()
        rig.sleep(100)
        XCTAssertEqual(rig.eval().phase, .holding, "counter restarted after the gap")
        rig.now = rig.now.advanced(by: 10)
        XCTAssertEqual(rig.eval().phase, .holding)
        rig.now = rig.now.advanced(by: 10)
        XCTAssertEqual(rig.eval().phase, .tripped)
    }

    func testSleepGapResetsSensorFailureCounter() {
        var rig = Rig()
        rig.arm()
        rig.snap.cpuTemperature = nil
        rig.advance(45)
        rig.sleep(600)
        XCTAssertEqual(rig.eval().phase, .holding)
    }

    func testShortGapKeepsSustain() {
        var rig = Rig(tweak: mechanics)
        rig.arm()
        rig.snap.cpuTemperature = 102
        rig.eval()
        rig.sleep(25)
        XCTAssertEqual(rig.eval().phase, .tripped, "25 s is below two intervals")
    }

    // MARK: Schedule gate

    func testArmOutsideScheduleWaitsInsteadOfTripping() {
        let night = iso("2026-11-09T21:30:00Z") // 22:30 Amsterdam
        var rig = Rig(schedule: .default, start: night)
        let r = rig.arm()
        guard case .waitingForSchedule(let opensAt) = r.outcome else { return XCTFail("expected waiting") }
        XCTAssertEqual(opensAt, iso("2026-11-10T06:00:00Z"))
        XCTAssertEqual(rig.state.phase, .waiting)
        XCTAssertTrue(rig.advance(3600, step: 60).allSatisfy { $0.phase == .waiting && $0.action == .none })
    }

    func testWaitingBecomesHoldingWhenWindowOpens() {
        var rig = Rig(schedule: .default, start: iso("2026-11-10T05:55:00Z")) // 06:55
        rig.arm()
        XCTAssertEqual(rig.state.phase, .waiting)
        let ds = rig.advance(600, step: 60)
        XCTAssertEqual(ds.first { $0.phase == .holding }?.action, .hold)
        XCTAssertEqual(ds.last?.phase, .holding)
    }

    func testScheduleEndTripsHoldingWithScheduleReason() {
        var rig = Rig(schedule: .default, start: iso("2026-11-09T18:55:00Z")) // 19:55
        rig.arm()
        XCTAssertEqual(rig.state.phase, .holding)
        let ds = rig.advance(600, step: 60)
        let trip = ds.compactMap(\.trip).first
        XCTAssertEqual(trip?.rule, .schedule)
        XCTAssertEqual(trip?.shortReason, "SCHEDULE")
        XCTAssertEqual(ds.last?.phase, .tripped)
    }

    func testWaitingWithFailingRuleDoesNotTrip() {
        var rig = Rig(schedule: .default, start: iso("2026-11-10T05:55:00Z"))
        rig.arm()
        rig.snap.batteryPercent = 5
        let ds = rig.advance(600, step: 60)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .waiting })
        XCTAssertTrue(ds.last!.rules.contains(.batteryFloor))
    }

    func testTimeLeftIsSmallestOfCapScheduleLidAndFloor() {
        var rig = Rig(schedule: .default, start: iso("2026-11-09T17:00:00Z")) // 18:00, window ends 20:00
        rig.arm()
        let d = rig.advance(15).last!
        XCTAssertEqual(d.timeLeft!, 2 * 3600 - 15, accuracy: 1)
    }

    // MARK: Unplug alert

    func testUnplugAlertFiresOnceOnAcToBattery() {
        var rig = Rig()
        rig.snap.powerSource = .ac
        rig.arm()
        rig.advance(60)
        rig.snap.powerSource = .battery
        let d = rig.eval()
        XCTAssertEqual(d.alerts, [.unpluggedWhileHolding])
        XCTAssertTrue(rig.advance(300).allSatisfy { $0.alerts.isEmpty })
    }

    func testUnplugAlertFiresAgainOnNextTransition() {
        var rig = Rig()
        rig.snap.powerSource = .ac
        rig.arm()
        rig.snap.powerSource = .battery
        XCTAssertEqual(rig.eval().alerts.count, 1)
        rig.snap.powerSource = .ac
        XCTAssertTrue(rig.eval().alerts.isEmpty)
        rig.snap.powerSource = .battery
        XCTAssertEqual(rig.eval().alerts.count, 1)
    }

    func testNoUnplugAlertWhenAlreadyOnBattery() {
        var rig = Rig()
        rig.snap.powerSource = .battery
        rig.arm()
        XCTAssertTrue(rig.advance(300).allSatisfy { $0.alerts.isEmpty })
        XCTAssertTrue(rig.last!.alerts.isEmpty)
    }

    func testNoUnplugAlertWhenOffOrDisarmed() {
        var rig = Rig()
        rig.snap.powerSource = .ac
        rig.eval()
        rig.snap.powerSource = .battery
        XCTAssertTrue(rig.eval().alerts.isEmpty, "never armed")

        var rig2 = Rig()
        rig2.snap.powerSource = .ac
        rig2.arm()
        rig2.state = RuleEngine.disarm(rig2.state).state
        rig2.snap.powerSource = .battery
        XCTAssertTrue(rig2.eval().alerts.isEmpty, "disarmed")
    }

    func testNoUnplugAlertWhenDisabledInConfig() {
        var rig = Rig(tweak: { $0.alertOnUnplug = false })
        rig.snap.powerSource = .ac
        rig.arm()
        rig.snap.powerSource = .battery
        XCTAssertTrue(rig.eval().alerts.isEmpty)
    }

    func testUnplugAlertFiresWhileWaitingAndRegardlessOfLid() {
        var rig = Rig(schedule: .default, start: iso("2026-11-09T21:30:00Z"))
        rig.snap.powerSource = .ac
        rig.snap.lidClosed = true
        rig.arm()
        XCTAssertEqual(rig.state.phase, .waiting)
        rig.snap.powerSource = .battery
        XCTAssertEqual(rig.eval().alerts, [.unpluggedWhileHolding])

        var rig2 = Rig()
        rig2.snap.powerSource = .ac
        rig2.snap.lidClosed = false
        rig2.arm()
        rig2.snap.powerSource = .battery
        XCTAssertEqual(rig2.eval().alerts, [.unpluggedWhileHolding])
    }

    func testNoUnplugAlertOnFirstEvaluationWithoutHistory() {
        var rig = Rig()
        rig.state.phase = .holding
        rig.snap.powerSource = .battery
        XCTAssertTrue(rig.eval().alerts.isEmpty)
    }

    func testUnplugBetweenTicksBeforeArmDoesNotAlert() {
        var rig = Rig()
        rig.snap.powerSource = .ac
        rig.eval()
        rig.snap.powerSource = .battery
        rig.arm()
        XCTAssertTrue(rig.last!.alerts.isEmpty)
        XCTAssertTrue(rig.eval().alerts.isEmpty)
    }

    // MARK: Arm timers, disarm, re-arm

    func testArmForOneHourEndsTheHold() {
        var rig = Rig()
        rig.arm(.oneHour)
        let ds = rig.advance(3600, step: 15)
        XCTAssertTrue(ds.dropLast().allSatisfy { $0.phase == .holding })
        XCTAssertEqual(ds.last?.phase, .off)
        XCTAssertEqual(ds.last?.action, .release)
        XCTAssertEqual(ds.last?.timerEnded, true)
    }

    func testArmUntilScheduleEndEndsAtWindowEnd() {
        var rig = Rig(schedule: .default, start: iso("2026-11-09T18:00:00Z")) // 19:00
        rig.arm(.untilScheduleEnd)
        let ds = rig.advance(3700, step: 60)
        XCTAssertEqual(ds.first { $0.phase != .holding }?.phase, .off)
        XCTAssertNil(ds.compactMap(\.trip).first, "a timer end is not a trip")
    }

    func testDisarmReleasesOnlyWhenHolding() {
        var rig = Rig()
        rig.arm()
        XCTAssertEqual(RuleEngine.disarm(rig.state).action, .release)
        XCTAssertEqual(RuleEngine.disarm(EngineState()).action, .none)
    }

    func testAcknowledgeClearsTrippedPhase() {
        var rig = Rig(tweak: mechanics)
        rig.config.cpuSustainSeconds = 0
        rig.arm()
        rig.snap.cpuTemperature = 105
        rig.eval()
        XCTAssertEqual(RuleEngine.acknowledge(rig.state).phase, .off)
    }

    func testStaysTrippedWithoutRearmSetting() {
        var rig = Rig(tweak: { $0.thermalLimit = .serious })
        rig.arm()
        rig.snap.thermal = .critical
        rig.eval()
        rig.snap.thermal = .nominal
        rig.snap.didWake = true
        XCTAssertEqual(rig.eval().phase, .tripped)
    }

    func testRearmOnWakeWhenAllRulesClear() {
        var rig = Rig(tweak: { $0.afterTrip = .rearmOnWake })
        rig.arm()
        rig.snap.thermal = .critical
        rig.eval()
        rig.snap.thermal = .nominal
        XCTAssertEqual(rig.eval().phase, .tripped, "no wake yet")
        rig.snap.didWake = true
        let d = rig.eval()
        XCTAssertEqual(d.phase, .holding)
        XCTAssertEqual(d.action, .hold)
    }

    func testRearmOnWakeWaitsWhileRuleStillFailing() {
        var rig = Rig(tweak: { $0.afterTrip = .rearmOnWake; $0.cpuSustainSeconds = 0; $0.smoothingSeconds = 0 })
        rig.arm()
        rig.snap.cpuTemperature = 107
        rig.eval()
        rig.snap.cpuTemperature = 97
        rig.snap.didWake = true
        XCTAssertEqual(rig.eval().phase, .tripped, "97 is above the clears-at level of 92")
    }

    func testRearmOnWakeDetectsWakeFromSleepGap() {
        var rig = Rig(tweak: { $0.afterTrip = .rearmOnWake })
        rig.arm()
        rig.snap.thermal = .critical
        XCTAssertEqual(rig.eval().phase, .tripped)
        rig.snap.thermal = .nominal
        rig.sleep(3600)
        XCTAssertEqual(rig.eval().phase, .holding)
    }

    func testNeverRearmsAfterHardCapOrSensorFailure() {
        var rig = Rig(tweak: { $0.afterTrip = .rearmOnWake })
        rig.arm()
        rig.snap.cpuTemperature = nil
        rig.advance(75)
        XCTAssertEqual(rig.state.phase, .tripped)
        rig.snap.cpuTemperature = 50
        rig.snap.didWake = true
        XCTAssertEqual(rig.eval().phase, .tripped)

        var rig2 = Rig(tweak: { $0.afterTrip = .rearmOnWake })
        rig2.arm()
        rig2.advance(8 * 3600)
        XCTAssertEqual(rig2.state.phase, .tripped)
        rig2.snap.didWake = true
        XCTAssertEqual(rig2.eval().phase, .tripped)
    }

    func testRearmWhenPluggedInAfterBatteryFloorStop() {
        var rig = Rig(tweak: { $0.rearmWhenPluggedIn = true })
        rig.arm()
        rig.snap.batteryPercent = 30
        XCTAssertEqual(rig.eval().state.lastTrip?.rule, .batteryFloor)
        XCTAssertEqual(rig.state.phase, .tripped)
        let still = rig.eval()
        XCTAssertEqual(still.phase, .tripped, "still on battery")
        rig.snap.powerSource = .ac
        rig.snap.isCharging = true
        rig.snap.batteryPercent = 45
        let d = rig.eval()
        XCTAssertEqual(d.phase, .holding)
        XCTAssertEqual(d.action, .hold)
        XCTAssertEqual(d.alerts, [.rearmedOnPower])
    }

    func testNoRearmWhenPluggedInWithSettingOff() {
        var rig = Rig()
        rig.arm()
        rig.snap.batteryPercent = 30
        rig.eval()
        rig.snap.powerSource = .ac
        rig.snap.isCharging = true
        rig.snap.batteryPercent = 45
        XCTAssertEqual(rig.eval().phase, .tripped)
    }

    func testNoRearmOnPowerAfterOtherTripReason() {
        var rig = Rig(tweak: { $0.rearmWhenPluggedIn = true })
        rig.arm()
        rig.snap.thermal = .critical
        rig.eval()
        rig.snap.thermal = .nominal
        rig.snap.powerSource = .ac
        XCTAssertEqual(rig.eval().phase, .tripped)
    }


    func testOffPhaseNeverActs() {
        var rig = Rig()
        rig.snap.cpuTemperature = 99
        rig.snap.batteryPercent = 3
        let ds = rig.advance(600, step: 60, jitter: false)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .off && $0.action == .none && $0.trip == nil })
    }
}
