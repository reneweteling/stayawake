import XCTest
@testable import StayAwakeCore

/// Fixtures captured on a MacBook Pro (Mac14,5, Apple M2 Max, macOS 26.6).
final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: pmset -g

    func testPmsetSleepDisabled() throws {
        let p = PmsetParser.parse(try fixture("pmset-g.txt"))
        XCTAssertNotNil(p.sleepDisabled)
        XCTAssertEqual(p.sleepDisabled, p.values["SleepDisabled"] == "1")
    }

    func testPmsetValuesAndPreventers() throws {
        let p = PmsetParser.parse(try fixture("pmset-g.txt"))
        XCTAssertEqual(p.values["hibernatemode"], "3")
        XCTAssertEqual(p.values["displaysleep"], "5")
        XCTAssertEqual(p.values["sleep"], "1")
        XCTAssertFalse(p.sleepPreventedBy.isEmpty)
        XCTAssertTrue(p.sleepPreventedBy.contains("powerd"))
        XCTAssertEqual(Set(p.sleepPreventedBy).count, p.sleepPreventedBy.count)
    }

    func testPmsetSynthetic() {
        let on = PmsetParser.parse("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 0 (sleep prevented by caffeinate, caffeinate)\n")
        XCTAssertEqual(on.sleepDisabled, true)
        XCTAssertEqual(on.sleepPreventedBy, ["caffeinate"])
        let off = PmsetParser.parse("Currently in use:\n sleep 1\n")
        XCTAssertNil(off.sleepDisabled)
        XCTAssertEqual(PmsetParser.parse(" SleepDisabled 0\n").sleepDisabled, false)
        XCTAssertEqual(PmsetParser.parse("").values.count, 0)
    }

    // MARK: ioreg AppleSmartBattery

    func testBatterySample() throws {
        let b = IORegBatteryParser.parse(try fixture("ioreg-applesmartbattery.txt"))
        XCTAssertEqual(b.rawTemperature, 3060)
        XCTAssertEqual(b.temperature!, 30.60, accuracy: 0.001)
        XCTAssertEqual(b.rawVirtualTemperature, 3279)
        XCTAssertEqual(b.currentCapacity, 58)
        XCTAssertEqual(b.maxCapacity, 100)
        XCTAssertEqual(b.isCharging, false)
        XCTAssertEqual(b.externalConnected, false)
    }

    func testBatteryIgnoresNestedTemperatures() {
        // MaximumTemperature and the like sit inside inline dictionaries.
        let text = "      \"LifetimeData\" = {\"MaximumTemperature\"=49,\"Temperature\"=1}\n      \"Temperature\" = 2999\n"
        XCTAssertEqual(IORegBatteryParser.parse(text).rawTemperature, 2999)
    }

    func testBatteryMissing() {
        XCTAssertNil(IORegBatteryParser.parse("").temperature)
    }

    // MARK: HID sensors

    func testHIDListParses() throws {
        let sensors = HIDSensorParser.parse(try fixture("hid-sensors-m2max.txt"))
        XCTAssertGreaterThan(sensors.count, 50)
        XCTAssertTrue(sensors.contains { $0.name == "gas gauge battery" })
    }

    func testHIDClassificationOnM2Max() throws {
        let c = HIDSensorParser.classify(HIDSensorParser.parse(try fixture("hid-sensors-m2max.txt")))
        XCTAssertFalse(c.cpu.isEmpty)
        XCTAssertTrue(c.cpu.allSatisfy { $0.name.hasPrefix("PMU tdie") })
        let cpu = try XCTUnwrap(c.cpuTemperature)
        XCTAssertTrue((20...110).contains(cpu))
        // This chip has no GPU named sensor in HID; the SMC Tg keys cover it.
        XCTAssertNil(c.gpuTemperature)
        XCTAssertTrue(c.battery.allSatisfy { $0.name == "gas gauge battery" })
        XCTAssertFalse(c.other.isEmpty)
        XCTAssertTrue(c.invalid.isEmpty)
    }

    func testHIDClassificationSynthetic() {
        let list = [HIDSensor(name: "PMU tdie1", celsius: 60), HIDSensor(name: "PMU tdie2", celsius: 72),
                    HIDSensor(name: "GPU MTR Temp Sensor1", celsius: 55), HIDSensor(name: "gas gauge battery", celsius: 31),
                    HIDSensor(name: "PMU tdie3", celsius: 0), HIDSensor(name: "NAND CH0 temp", celsius: 40)]
        let c = HIDSensorParser.classify(list)
        XCTAssertEqual(c.cpuTemperature, 72)
        XCTAssertEqual(c.gpuTemperature, 55)
        XCTAssertEqual(c.batteryTemperature, 31)
        XCTAssertEqual(c.invalid.map(\.name), ["PMU tdie3"])
        XCTAssertEqual(c.other.map(\.name), ["NAND CH0 temp"])
    }

    func testHIDParserSkipsJunk() {
        XCTAssertEqual(HIDSensorParser.parse("(unnamed) = no event\nfoo\nA b = 12.5\n"), [HIDSensor(name: "A b", celsius: 12.5)])
    }
}
