import XCTest
@testable import StayAwakeCore

final class DisplayTests: XCTestCase {
    func testReadoutsShowTheirLimits() {
        let c = Config()
        let s = Snapshot(cpuTemperature: 58, gpuTemperature: 52, batteryTemperature: 34, batteryPercent: 71)
        XCTAssertEqual(Readout.cpu(s, c), "CPU 58 °C / 100")
        XCTAssertEqual(Readout.gpu(s, c), "GPU 52 °C / 95")
        XCTAssertEqual(Readout.batteryTemperature(s, c), "Battery 34 °C / 43")
        XCTAssertEqual(Readout.batteryLevel(s, c), "Battery 71% / stops at 40%")
    }

    func testReadoutsFollowTheConfiguredLimitsAndUnit() {
        var c = Config()
        c.cpuLimit = 70; c.floorPercent = 35
        let s = Snapshot(cpuTemperature: 58, batteryPercent: 71)
        XCTAssertEqual(Readout.cpu(s, c), "CPU 58 °C / 70")
        XCTAssertEqual(Readout.batteryLevel(s, c), "Battery 71% / stops at 35%")
        XCTAssertEqual(Readout.cpu(s, c, unit: .fahrenheit), "CPU 136 °F / 158")
    }

    func testMissingReadingsAreShownAsNA() {
        let s = Snapshot(cpuTemperature: nil, gpuTemperature: nil, batteryPercent: nil)
        XCTAssertEqual(Readout.cpu(s, Config()), "CPU n/a / 100")
        XCTAssertEqual(Readout.batteryLevel(s, Config()), "Battery n/a / stops at 40%")
    }

    func testReadoutsShowTheAverageTheRuleUses() {
        let c = Config()
        let s = Snapshot(cpuTemperature: 100, gpuTemperature: 70)
        let sig = Signals(cpu: SignalReading(instant: 100, smoothed: 88.4, source: .smc, samples: 4),
                          gpu: SignalReading(instant: 70, smoothed: 70, source: .smc, samples: 4),
                          battery: SignalReading(instant: 35, smoothed: 35, source: .smc, samples: 1))
        XCTAssertEqual(Readout.cpu(s, c, signals: sig), "CPU 88 °C / 100")
        XCTAssertEqual(Readout.cpu(s, c), "CPU 100 °C / 100", "before the first decision: the instant value")
        XCTAssertEqual(Readout.instantNote(sig.cpu, unit: .celsius), "now 100")
        XCTAssertNil(Readout.instantNote(sig.gpu, unit: .celsius), "no note when they agree")
        let empty = Signals(cpu: SignalReading(instant: nil, smoothed: nil, source: .none, samples: 0), gpu: .none, battery: .none)
        XCTAssertEqual(Readout.cpu(s, c, signals: empty), "CPU 100 °C / 100", "no samples yet: the instant value")
    }

    func testValueSplitsOffTheLabel() {
        XCTAssertEqual(Readout.value("CPU 58 °C / 80", label: "CPU"), "58 °C / 80")
        XCTAssertEqual(Readout.value("Battery 71% / stops at 40%", label: "Battery"), "71% / stops at 40%")
    }

    func testDurations() {
        XCTAssertEqual(Readout.duration(45), "45 s")
        XCTAssertEqual(Readout.duration(42 * 60), "42 min")
        XCTAssertEqual(Readout.duration(72 * 60), "1 h 12 min")
        XCTAssertEqual(Readout.duration(2 * 3600), "2 h")
    }

    func testOpensAtShowsTheDayWhenNotToday() {
        let tomorrow = mondayMorning.addingTimeInterval(86400 - 3600)   // Tue 09:00 Amsterdam
        XCTAssertEqual(Readout.opensAt(mondayMorning.addingTimeInterval(3600), now: mondayMorning, in: amsterdam), "11:00")
        XCTAssertEqual(Readout.opensAt(tomorrow, now: mondayMorning, in: amsterdam), "Tue 09:00")
    }

    func testLimitingTimePicksTheSmallestEstimate() {
        let margins = [
            RuleMargin(rule: .hardCap, fraction: 0.9, seconds: 7 * 3600, detail: "Time cap"),
            RuleMargin(rule: .lidOnBattery, fraction: 0.5, seconds: 42 * 60, detail: "Lid"),
            RuleMargin(rule: .cpuTemperature, fraction: 0.3, seconds: nil, detail: "CPU"),
        ]
        XCTAssertEqual(Readout.limitingTime(margins, timerLeft: nil)?.label, "lid closed")
        XCTAssertEqual(Readout.limitingTime(margins, timerLeft: 600)?.label, "timer")
        XCTAssertNil(Readout.limitingTime([], timerLeft: nil))
    }
}

final class MenuBarStatusTests: XCTestCase {
    private func input(_ rig: Rig, phase: Phase? = nil, setup: String? = nil, readout: MenuBarReadout = .both) -> MenuBarStatus.Input {
        MenuBarStatus.Input(phase: phase ?? rig.state.phase, setupMessage: setup, snapshot: rig.snap, decision: rig.last,
                            lastTrip: rig.state.lastTrip, trippedAt: rig.now.wall,
                            heldFor: rig.state.heldSince.map { rig.now.monotonic - $0 }, now: rig.now.wall,
                            config: rig.config, readout: readout, timeZone: amsterdam)
    }

    func testOff() {
        let rig = Rig()
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .off)
        XCTAssertEqual(s.symbol, "moon.zzz")
        XCTAssertEqual(s.title, "")
        XCTAssertEqual(s.tooltip, "StayAwake: off")
    }

    func testSetupWhenTheBackendCannotHold() {
        let s = MenuBarStatus.make(input(Rig(), setup: "Approve the helper"))
        XCTAssertEqual(s.kind, .setup)
        XCTAssertEqual(s.symbol, "lock.slash")
        XCTAssertEqual(s.title, "SETUP")
        XCTAssertEqual(s.tooltip, "Approve the helper")
    }

    func testHoldingShowsTheReadout() {
        var rig = Rig()
        rig.snap.cpuTemperature = 58; rig.snap.batteryPercent = 71
        rig.arm()
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .holding)
        XCTAssertEqual(s.symbol, "cup.and.saucer.fill")
        XCTAssertEqual(s.title, "58° 71%")
        XCTAssertTrue(s.tooltip.contains("battery 71%") && s.tooltip.contains("CPU 58°"), s.tooltip)
        XCTAssertEqual(MenuBarStatus.make(input(rig, readout: .temperature)).title, "58°")
        XCTAssertEqual(MenuBarStatus.make(input(rig, readout: .battery)).title, "71%")
        XCTAssertEqual(MenuBarStatus.make(input(rig, readout: .none)).title, "")
    }

    func testWaitingOutsideTheScheduleShowsTheOpeningTime() {
        // Monday 10:00 local, window starts at 13:00.
        var rig = Rig(schedule: weekdays([TimeWindow(start: 13 * 60, end: 20 * 60)], on: [1]))
        rig.arm()
        XCTAssertEqual(rig.state.phase, .waiting)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .waiting)
        XCTAssertEqual(s.symbol, "clock")
        XCTAssertEqual(s.title, "13:00")
        XCTAssertEqual(s.tooltip, "Armed, waiting for 13:00")
    }

    func testWarningWhenARuleIsWithinTenPercent() {
        var rig = Rig()
        rig.snap.batteryPercent = 42   // floor 40: 3.3% of the way
        rig.arm()
        XCTAssertEqual(rig.state.phase, .holding)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .warning)
        XCTAssertEqual(s.tone, .amber)
        XCTAssertEqual(s.tooltip, "Battery at 42%, trips at 40%")
    }

    func testTrippedShowsTheShortReasonUntilAcknowledged() {
        var rig = Rig { $0.cpuSustainSeconds = 20; $0.smoothingSeconds = 0 }
        rig.snap.cpuTemperature = 70
        rig.arm()
        rig.snap.cpuTemperature = 105
        rig.advance(45)
        XCTAssertEqual(rig.state.phase, .tripped)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .tripped)
        XCTAssertEqual(s.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(s.title.hasPrefix("HOT 105"), s.title)
        XCTAssertEqual(s.tone, .red)
        XCTAssertTrue(s.tooltip.hasPrefix("Sleep restored at "), s.tooltip)
        XCTAssertTrue(s.tooltip.contains("CPU temperature"), s.tooltip)
        rig.state = RuleEngine.acknowledge(rig.state)
        XCTAssertEqual(MenuBarStatus.make(input(rig)).kind, .off)
    }

    func testGPUTripReason() {
        var rig = Rig { $0.gpuSustainSeconds = 0; $0.smoothingSeconds = 0 }
        rig.arm()
        rig.snap.gpuTemperature = 100
        rig.advance(15)
        XCTAssertEqual(rig.state.lastTrip?.shortReason, "GPU HOT")
        XCTAssertEqual(MenuBarStatus.make(input(rig)).title, "GPU HOT")
    }

    // MARK: Tripped, live versus cleared

    private func tripped(_ rig: inout Rig, seconds: Double = 45) {
        rig.arm()
        rig.advance(seconds)
        XCTAssertEqual(rig.state.phase, .tripped)
    }

    private func assertStopped(_ s: MenuBarStatus, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s.kind, .stopped, file: file, line: line)
        XCTAssertEqual(s.symbol, "moon.zzz", file: file, line: line)
        XCTAssertEqual(s.title, "", file: file, line: line)
        XCTAssertEqual(s.tone, .normal, file: file, line: line)
        XCTAssertTrue(s.tooltip.hasPrefix("StayAwake stopped at "), s.tooltip, file: file, line: line)
    }

    func testBatteryLowShowsTheLiveValueWhileStillLow() {
        var rig = Rig()
        rig.snap.batteryPercent = 60
        rig.arm()
        rig.snap.batteryPercent = 39
        rig.advance(30)
        XCTAssertEqual(rig.state.lastTrip?.shortReason, "LOW 39%")
        rig.snap.batteryPercent = 38
        rig.advance(30)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .tripped)
        XCTAssertEqual(s.title, "LOW 38%")
        XCTAssertEqual(s.tone, .red)
    }

    func testBatteryLowClearedWhenChargedGoesNeutral() {
        var rig = Rig()
        rig.snap.batteryPercent = 60
        rig.arm()
        rig.snap.batteryPercent = 39
        rig.advance(30)
        rig.snap.batteryPercent = 80; rig.snap.isCharging = true; rig.snap.powerSource = .ac
        rig.advance(30)
        XCTAssertEqual(rig.state.phase, .tripped, "the trip stays latched")
        XCTAssertEqual(rig.state.lastTrip?.shortReason, "LOW 39%")
        let s = MenuBarStatus.make(input(rig))
        assertStopped(s)
        XCTAssertTrue(s.tooltip.contains("Battery 39% is below 40%"), s.tooltip)
    }

    func testBatteryTemperatureLiveThenCleared() {
        var rig = Rig { $0.batteryTempSustainSeconds = 0 }
        rig.arm()
        rig.snap.batteryTemperature = 45
        rig.advance(30)
        XCTAssertEqual(rig.state.phase, .tripped)
        XCTAssertEqual(MenuBarStatus.make(input(rig)).kind, .tripped)
        rig.snap.batteryTemperature = 30
        rig.advance(30)
        assertStopped(MenuBarStatus.make(input(rig)))
    }

    func testCPUAndGPULiveThenCleared() {
        var cpu = Rig { $0.cpuSustainSeconds = 0; $0.smoothingSeconds = 0 }
        cpu.arm()
        cpu.snap.cpuTemperature = 105
        cpu.advance(30)
        XCTAssertEqual(MenuBarStatus.make(input(cpu)).kind, .tripped)
        cpu.snap.cpuTemperature = 50
        cpu.advance(30)
        assertStopped(MenuBarStatus.make(input(cpu)))

        var gpu = Rig { $0.gpuSustainSeconds = 0; $0.smoothingSeconds = 0 }
        gpu.arm()
        gpu.snap.gpuTemperature = 100
        gpu.advance(30)
        XCTAssertEqual(MenuBarStatus.make(input(gpu)).title, "GPU HOT")
        gpu.snap.gpuTemperature = 45
        gpu.advance(30)
        assertStopped(MenuBarStatus.make(input(gpu)))
    }

    func testSensorFailureLiveThenCleared() {
        var rig = Rig { $0.sensorFailureSeconds = 60 }
        rig.arm()
        rig.snap.cpuTemperature = nil
        rig.advance(120)
        XCTAssertEqual(rig.state.lastTrip?.rule, .sensorFailure)
        XCTAssertEqual(MenuBarStatus.make(input(rig)).title, "SENSOR")
        rig.snap.cpuTemperature = 50
        rig.advance(30)
        assertStopped(MenuBarStatus.make(input(rig)))
    }

    func testWithoutADecisionATripShowsNeutral() {
        var rig = Rig()
        rig.snap.batteryPercent = 60
        rig.arm()
        rig.snap.batteryPercent = 39
        rig.advance(30)
        var i = input(rig)
        i.decision = nil
        assertStopped(MenuBarStatus.make(i))
    }
}
