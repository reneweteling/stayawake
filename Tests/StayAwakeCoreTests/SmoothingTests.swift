import XCTest
@testable import StayAwakeCore

final class SmoothingTests: XCTestCase {

    // MARK: Rolling mean

    func testMeanOverTheWindow() {
        var samples: [TimedValue] = []
        XCTAssertEqual(Smoothing.add(70, samples: &samples, now: 0), 70)
        XCTAssertEqual(Smoothing.add(100, samples: &samples, now: 15), 85)
        XCTAssertEqual(Smoothing.add(70, samples: &samples, now: 30), 80)
        XCTAssertEqual(Smoothing.add(100, samples: &samples, now: 45), 85)
        // t=0 is 60 s old now and drops out.
        XCTAssertEqual(Smoothing.add(70, samples: &samples, now: 60), 85)
        XCTAssertEqual(samples.map(\.t), [15, 30, 45, 60])
    }

    func testBurstsReplaceInsteadOfPilingUp() {
        var samples: [TimedValue] = []
        _ = Smoothing.add(70, samples: &samples, now: 0)
        _ = Smoothing.add(100, samples: &samples, now: 15)
        _ = Smoothing.add(101, samples: &samples, now: 15.3)
        XCTAssertEqual(Smoothing.add(102, samples: &samples, now: 16), 86)
        XCTAssertEqual(samples.count, 2)
    }

    func testZeroWindowKeepsOnlyTheCurrentReading() {
        var samples: [TimedValue] = []
        _ = Smoothing.add(70, samples: &samples, now: 0)
        XCTAssertEqual(Smoothing.add(100, samples: &samples, now: 15, window: 0), 100)
    }

    func testClockGoingBackwardsDropsFutureSamples() {
        var samples = [TimedValue(t: 500, v: 99)]
        XCTAssertEqual(Smoothing.add(60, samples: &samples, now: 100), 60)
    }

    // MARK: Source hold

    func testHoldCoversAShortSMCGap() {
        var t = SignalTracker()
        XCTAssertEqual(Smoothing.hold(88, source: .smc, tracker: &t, now: 0).value, 88)
        let held = Smoothing.hold(57, source: .hid, tracker: &t, now: 10)
        XCTAssertEqual(held.value, 88)
        XCTAssertEqual(held.source, .held)
        XCTAssertEqual(Smoothing.hold(57, source: .hid, tracker: &t, now: 59.9).source, .held)
        let late = Smoothing.hold(57, source: .hid, tracker: &t, now: 60)
        XCTAssertEqual(late.value, 57, "after 60 s HID takes over")
        XCTAssertEqual(late.source, .hid)
    }

    func testHoldNeverCoversNoReadingAtAll() {
        var t = SignalTracker()
        _ = Smoothing.hold(88, source: .smc, tracker: &t, now: 0)
        let r = Smoothing.hold(nil, source: .none, tracker: &t, now: 10)
        XCTAssertNil(r.value, "sensor failure must see a total loss")
        XCTAssertEqual(r.source, .none)
    }

    func testHoldWithoutSMCHistoryUsesHID() {
        var t = SignalTracker()
        XCTAssertEqual(Smoothing.hold(57, source: .hid, tracker: &t, now: 0).source, .hid)
    }

    // MARK: Engine

    /// The measured trace: instant max over the curated M2 Max keys every
    /// 10 s during normal agent work, with the two HID-only samples. This
    /// overstates the new mean signal, so it is a hard case.
    static let measured: [(Double, TemperatureSource)] = [
        (88.6, .smc), (97.9, .smc), (91.9, .smc), (90.6, .smc), (100.4, .smc), (96.0, .smc), (98.9, .smc),
        (91.8, .smc), (94.3, .smc), (87.8, .smc), (88.6, .smc), (94.9, .smc), (87.2, .smc), (77.9, .smc),
        (76.7, .smc), (81.5, .smc), (74.1, .smc), (60.2, .hid), (71.7, .smc), (70.5, .smc), (74.6, .smc),
        (57.3, .hid), (69.8, .smc), (73.3, .smc),
    ]

    private func replay(_ config: (inout Config) -> Void, rounds: Int = 5) -> [Decision] {
        var rig = Rig(tweak: config)
        rig.snap.powerSource = .ac
        rig.snap.isCharging = true
        rig.arm()
        var out: [Decision] = []
        var n = 0
        for _ in 0..<rounds {
            for (v, source) in Self.measured {
                n += 1
                rig.now = rig.now.advanced(by: 10)
                // GPU and battery wobble a little so they never count as stuck.
                rig.snap.gpuTemperature = 70 + Double(n % 3)
                rig.snap.batteryTemperature = 35 + Double(n % 2) * 0.1
                rig.snap.cpuTemperature = v
                rig.snap.cpuSource = source
                out.append(rig.eval())
            }
        }
        return out
    }

    func testMeasuredNormalWorkTripsTheOldRuleButNotBalanced() {
        let old = replay { $0.cpuLimit = 90; $0.cpuSustainSeconds = 20; $0.smoothingSeconds = 0 }
        XCTAssertNotNil(old.compactMap(\.trip).first, "the old 90 C / 20 s instant rule trips on this")
        let balanced = replay { _ in }
        XCTAssertTrue(balanced.allSatisfy { $0.phase == .holding })
        let peak = balanced.compactMap(\.signals.cpu.smoothed).max()!
        XCTAssertLessThan(peak, 97, "the 60 s average stays well under 102")
        let cautious = replay { $0 = SafetyPreset.cautious.apply(to: $0) }
        XCTAssertTrue(cautious.allSatisfy { $0.phase == .holding }, "even Cautious holds through normal work")
    }

    func testHeldSampleShowsInTheSignals() {
        let ds = replay({ _ in }, rounds: 1)
        XCTAssertEqual(ds[17].signals.cpu.source, .held)
        XCTAssertEqual(ds[17].signals.cpu.instant, 60.2)
        XCTAssertEqual(ds[16].signals.cpu.source, .smc)
    }

    func testHIDSampleDoesNotResetTheSustainTimer() {
        var rig = Rig { $0.cpuSustainSeconds = 60 }
        rig.arm()
        rig.snap.cpuTemperature = 105
        var ds = rig.advance(60, step: 15)           // the window fills with 105, the average crosses at +60
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
        XCTAssertNotNil(rig.state.cpu.exceededSince)
        rig.snap.cpuTemperature = 57
        rig.snap.cpuSource = .hid
        rig.now = rig.now.advanced(by: 15)
        XCTAssertEqual(rig.eval().phase, .holding, "held at 105, timer keeps running")
        XCTAssertNotNil(rig.state.cpu.exceededSince)
        rig.snap.cpuTemperature = 105
        rig.snap.cpuSource = .smc
        ds = rig.advance(45, step: 15)
        XCTAssertEqual(ds.last?.trip?.rule, .cpuTemperature, "60 s above the limit despite the HID sample")
    }

    func testWithoutHoldHIDWouldHaveResetTheTimer() {
        var rig = Rig { $0.cpuSustainSeconds = 120; $0.smoothingSeconds = 0 }
        rig.arm()
        rig.snap.cpuTemperature = 105
        rig.advance(45, step: 15)
        // Long SMC outage: more than 60 s since the last SMC value.
        rig.snap.cpuTemperature = 57
        rig.snap.cpuSource = .hid
        let ds = rig.advance(75, step: 15)
        XCTAssertEqual(ds.first?.signals.cpu.source, .held)
        XCTAssertEqual(ds.last?.signals.cpu.source, .hid)
        XCTAssertTrue(ds.allSatisfy { $0.phase == .holding })
    }

    func testSpikeIsAveragedAway() {
        var rig = Rig { $0.cpuSustainSeconds = 0 }
        rig.snap.cpuTemperature = 85
        rig.arm()
        rig.advance(60)
        rig.snap.cpuTemperature = 108
        let d = rig.advance(15, jitter: false).last!
        XCTAssertEqual(d.phase, .holding, "one 108 among 85s averages to about 91")
        XCTAssertEqual(d.signals.cpu.instant, 108)
        XCTAssertEqual(d.signals.cpu.smoothed!, (85 * 3 + 108) / 4, accuracy: 0.05)
        XCTAssertEqual(Readout.instantNote(d.signals.cpu, unit: .celsius), "now 108")
    }

    func testSustainedHeatTripsAfterWindowAndWait() {
        var rig = Rig()                                // Balanced: 102 C, 120 s
        rig.snap.cpuTemperature = 80
        rig.arm()
        rig.advance(60)
        rig.snap.cpuTemperature = 106
        let ds = rig.advance(300, step: 15)
        let i = ds.firstIndex { $0.trip != nil }!
        let seconds = Double(i + 1) * 15
        XCTAssertGreaterThanOrEqual(seconds, 120 + 30, "the average needs time to cross, then the wait")
        XCTAssertLessThanOrEqual(seconds, 120 + 60)
        XCTAssertTrue(ds[i].trip!.message.contains("60 s average"), ds[i].trip!.message)
    }

    func testGPUIsSmoothedToo() {
        var rig = Rig { $0.gpuSustainSeconds = 0 }
        rig.snap.gpuTemperature = 80
        rig.arm()
        rig.advance(60)
        rig.snap.gpuTemperature = 110
        XCTAssertEqual(rig.advance(15).last!.phase, .holding, "one 110 among 80s")
        XCTAssertEqual(rig.advance(45).compactMap(\.trip).first?.rule, .gpuTemperature)
    }

    func testSleepGapClearsTheWindow() {
        var rig = Rig()
        rig.snap.cpuTemperature = 100
        rig.arm()
        rig.advance(60)
        rig.sleep(600)
        rig.snap.cpuTemperature = 60
        let d = rig.eval()
        XCTAssertEqual(d.signals.cpu.samples, 1)
        XCTAssertEqual(d.signals.cpu.smoothed, 60)
    }

    func testMarginsUseTheAverage() {
        var rig = Rig()
        rig.snap.cpuTemperature = 80
        rig.arm()
        rig.advance(60)
        rig.snap.cpuTemperature = 101
        let d = rig.advance(15).last!
        let m = d.margins.first { $0.rule == .cpuTemperature }!
        XCTAssertTrue(m.detail.hasPrefix("CPU 85"), m.detail)
        XCTAssertFalse(d.warnings.contains(.cpuTemperature))
    }

    // MARK: Battery heating up

    private func heatingRig(_ tweak: @escaping (inout Config) -> Void = { _ in }) -> Rig {
        var rig = Rig { $0.batteryHeatingEnabled = true; $0.lidMinutes = 480; tweak(&$0) }
        rig.snap.lidClosed = true
        rig.snap.powerSource = .battery
        rig.snap.cpuLoadPercent = 60
        rig.snap.batteryTemperature = 32
        return rig
    }

    func testHeatingUpTripsOnARiseOfMoreThanTwoDegreesInFiveMinutes() {
        var rig = heatingRig()
        rig.arm()
        var trip: TripInfo?
        for i in 1...20 {
            rig.now = rig.now.advanced(by: 15)
            rig.snap.batteryTemperature = 32 + Double(i) * 0.15    // 0.6 C a minute
            let d = rig.eval()
            if let t = d.trip { trip = t; XCTAssertEqual(i, 14, "2.1 C above the start after 210 s"); break }
        }
        XCTAssertEqual(trip?.rule, .batteryHeating)
        XCTAssertEqual(trip?.shortReason, "BATT RISING")
    }

    func testSlowRiseDoesNotTrip() {
        var rig = heatingRig()
        rig.arm()
        for i in 1...120 {                                           // 30 min, 0.3 C a minute
            rig.now = rig.now.advanced(by: 15)
            rig.snap.cpuTemperature = 50 + Double(i % 2)
            rig.snap.batteryTemperature = 32 + Double(i) * 0.075
            XCTAssertEqual(rig.eval().phase, .holding)
        }
    }

    func testHeatingUpOnlyWithLidClosedOnBattery() {
        for (lid, power) in [(false, PowerSource.battery), (true, .ac)] {
            var rig = heatingRig()
            rig.snap.lidClosed = lid
            rig.snap.powerSource = power
            rig.arm()
            for i in 1...20 {
                rig.now = rig.now.advanced(by: 15)
                rig.snap.batteryTemperature = 32 + Double(i) * 0.3
                XCTAssertNil(rig.eval().failing.first { $0.rule == .batteryHeating })
            }
            XCTAssertNil(rig.last!.signals.batteryRise)
        }
    }

    func testHeatingUpOffByDefault() {
        var rig = Rig()
        rig.snap.lidClosed = true
        rig.snap.cpuLoadPercent = 60
        rig.arm()
        for i in 1...20 {
            rig.now = rig.now.advanced(by: 15)
            rig.snap.batteryTemperature = 30 + Double(i) * 0.3
            XCTAssertNil(rig.eval().failing.first { $0.rule == .batteryHeating })
        }
    }

    func testHeatingUpRiseIsConfigurable() {
        var rig = heatingRig { $0.batteryHeatingRise = 4 }
        rig.arm()
        for i in 1...20 {
            rig.now = rig.now.advanced(by: 15)
            rig.snap.batteryTemperature = 32 + Double(i) * 0.15     // 3 C in 5 min
            XCTAssertEqual(rig.eval().phase, .holding)
        }
        XCTAssertEqual(rig.last!.signals.batteryRise!, 3, accuracy: 0.01, "the arm reading, exactly 300 s ago, still counts")
        XCTAssertNotNil(rig.last!.margins.first { $0.rule == .batteryHeating })
    }

    func testOpeningTheLidClearsTheHeatingHistory() {
        var rig = heatingRig()
        rig.arm()
        rig.snap.batteryTemperature = 32
        rig.advance(60)
        rig.snap.lidClosed = false
        rig.advance(15)
        XCTAssertTrue(rig.state.batteryHistory.isEmpty)
    }

    // MARK: Simulator

    func testSimulatorTakesTheSourceField() throws {
        let r = try Simulator.run(try Simulator.parse(Data("""
        { "config": { "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "steps": [
            { "at": 0, "command": "arm", "snapshot": { "cpuTemperature": 90 } },
            { "at": 15, "snapshot": { "cpuTemperature": 58, "cpuSource": "hid" } }
          ] }
        """.utf8)))
        XCTAssertEqual(r[1].decision.signals.cpu.source, .held)
        XCTAssertEqual(r[1].decision.signals.cpu.smoothed, 90)
    }
}
