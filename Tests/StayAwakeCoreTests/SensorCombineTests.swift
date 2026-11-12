import XCTest
@testable import StayAwakeCore

final class SensorCombineTests: XCTestCase {
    func testHottestDropsImplausibleValues() {
        // A glitching sensor must not win just because it is "hottest".
        XCTAssertEqual(SensorCombine.hottest([400, 60]), 60)
        XCTAssertEqual(SensorCombine.hottest([-5, 60]), 60)
        XCTAssertEqual(SensorCombine.hottest([0, 60]), 60)
        XCTAssertNil(SensorCombine.hottest([400, -1]))
        XCTAssertNil(SensorCombine.hottest([nil, nil]))
        XCTAssertEqual(SensorCombine.hottest([130, 20]), 130)
        XCTAssertEqual(SensorCombine.hottest([1, nil]), 1)
    }

    // MARK: Battery max signal

    func testBatteryTakesTheHottestOfTheThreeSensors() {
        // Measured on an M2 Max: Temperature 30.9, VirtualTemperature 35.9, gas gauge 35.0.
        XCTAssertEqual(SensorCombine.battery(temperature: 30.9, virtual: 35.89, hid: 35.0), 35.89)
        XCTAssertEqual(SensorCombine.battery(temperature: 30.9, virtual: nil, hid: 36.2), 36.2)
        XCTAssertEqual(SensorCombine.battery(temperature: 41, virtual: 40, hid: nil), 41)
    }

    func testBatteryWithOneOrNoSensor() {
        XCTAssertEqual(SensorCombine.battery(temperature: nil, virtual: nil, hid: 33), 33)
        XCTAssertNil(SensorCombine.battery(temperature: nil, virtual: nil, hid: nil))
        XCTAssertEqual(SensorCombine.battery(temperature: 31, virtual: 400, hid: nil), 31, "implausible values are dropped")
    }

    func testBatteryParserReadsVirtualTemperature() {
        let b = BatterySample(rawTemperature: 3091, rawVirtualTemperature: 3589)
        XCTAssertEqual(b.temperature!, 30.91, accuracy: 0.001)
        XCTAssertEqual(b.virtualTemperature!, 35.89, accuracy: 0.001)
    }

    // MARK: Mean, not max

    func testCPUIsTheMeanOfTheCuratedKeys() {
        let keys = [SMCKey(key: "Tp01", celsius: 100), SMCKey(key: "Tp05", celsius: 70),
                    SMCKey(key: "Tp09", celsius: 82), SMCKey(key: "Tp1h", celsius: 6.7)]
        let c = SensorCombine.choose(.cpu, hid: 57, smc: keys, family: .m2)
        XCTAssertEqual(c.value!, 84, accuracy: 0.001, "gated Tp1h is skipped, the rest averaged")
        XCTAssertEqual(c.used.count, 3)
        XCTAssertEqual(c.kind, .smc)
        XCTAssertEqual(c.hid, 57)
    }

    func testMeanDrivesTheCPURule() {
        // Max 106 would trip a 100 limit at once; the mean 98 does not.
        var rig = Rig { $0.cpuSustainSeconds = 0 }
        let keys = [SMCKey(key: "Tp01", celsius: 106), SMCKey(key: "Tp05", celsius: 90)]
        rig.snap.cpuTemperature = SensorCombine.choose(.cpu, hid: 49, smc: keys, family: .m2).value
        XCTAssertEqual(rig.arm().outcome, .holding)
    }
}
