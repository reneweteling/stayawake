import XCTest
@testable import StayAwakeCore

final class DisplayTests: XCTestCase {
    func testReadoutsShowTheirLimits() {
        let c = Config()
        let s = Snapshot(cpuTemperature: 58, gpuTemperature: 52, batteryTemperature: 34, batteryPercent: 71)
        XCTAssertEqual(Readout.cpu(s, c), "CPU 58 °C / 90")
        XCTAssertEqual(Readout.gpu(s, c), "GPU 52 °C / 85")
        XCTAssertEqual(Readout.batteryTemperature(s, c), "Battery 34 °C / 40")
        XCTAssertEqual(Readout.batteryLevel(s, c), "Battery 71% / stops at 20%")
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
        XCTAssertEqual(Readout.cpu(s, Config()), "CPU n/a / 90")
        XCTAssertEqual(Readout.batteryLevel(s, Config()), "Battery n/a / stops at 20%")
    }

    func testValueSplitsOffTheLabel() {
        XCTAssertEqual(Readout.value("CPU 58 °C / 80", label: "CPU"), "58 °C / 80")
        XCTAssertEqual(Readout.value("Battery 71% / stops at 20%", label: "Battery"), "71% / stops at 20%")
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
        XCTAssertEqual(Readout.limitingTime(margins, timerLeft: nil)?.label, "lid limit")
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
        rig.snap.batteryPercent = 22   // floor 20: 2.5% of the way
        rig.arm()
        XCTAssertEqual(rig.state.phase, .holding)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .warning)
        XCTAssertEqual(s.tone, .amber)
        XCTAssertEqual(s.tooltip, "Battery at 22%, trips at 20%")
    }

    func testTrippedShowsTheShortReasonUntilAcknowledged() {
        var rig = Rig { $0.cpuSustainSeconds = 20 }
        rig.snap.cpuTemperature = 70
        rig.arm()
        rig.snap.cpuTemperature = 95
        rig.advance(45)
        XCTAssertEqual(rig.state.phase, .tripped)
        let s = MenuBarStatus.make(input(rig))
        XCTAssertEqual(s.kind, .tripped)
        XCTAssertEqual(s.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(s.title.hasPrefix("HOT 95"), s.title)
        XCTAssertEqual(s.tone, .red)
        XCTAssertTrue(s.tooltip.hasPrefix("Sleep restored at "), s.tooltip)
        XCTAssertTrue(s.tooltip.contains("CPU temperature"), s.tooltip)
        rig.state = RuleEngine.acknowledge(rig.state)
        XCTAssertEqual(MenuBarStatus.make(input(rig)).kind, .off)
    }

    func testGPUTripReason() {
        var rig = Rig { $0.gpuSustainSeconds = 0 }
        rig.arm()
        rig.snap.gpuTemperature = 85
        rig.advance(15)
        XCTAssertEqual(rig.state.lastTrip?.shortReason, "GPU HOT")
        XCTAssertEqual(MenuBarStatus.make(input(rig)).title, "GPU HOT")
    }
}
