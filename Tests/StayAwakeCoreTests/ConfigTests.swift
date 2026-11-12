import XCTest
@testable import StayAwakeCore

final class ConfigTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let c = Config()
        XCTAssertTrue(c.cpuEnabled); XCTAssertEqual(c.cpuLimit, 90); XCTAssertEqual(c.cpuSustainSeconds, 20); XCTAssertEqual(c.cpuClearMargin, 10)
        XCTAssertTrue(c.gpuEnabled); XCTAssertEqual(c.gpuLimit, 85); XCTAssertEqual(c.gpuSustainSeconds, 20); XCTAssertEqual(c.gpuClearMargin, 10)
        XCTAssertEqual(c.batteryTempLimit, 40); XCTAssertEqual(c.batteryTempSustainSeconds, 30); XCTAssertEqual(c.batteryTempClearMargin, 4)
        XCTAssertEqual(c.thermalLimit, .serious)
        XCTAssertEqual(c.floorPercent, 20)
        XCTAssertEqual(c.lidMinutes, 90)
        XCTAssertEqual(c.idleCpuPercent, 10); XCTAssertEqual(c.idleMinutes, 15)
        XCTAssertFalse(c.watchedEnabled); XCTAssertEqual(c.watchedNames, ["claude"]); XCTAssertEqual(c.watchedMinutes, 20)
        XCTAssertEqual(c.networkMinutes, 15)
        XCTAssertEqual(c.capHours, 8)
        XCTAssertEqual(c.sensorFailureSeconds, 60)
        XCTAssertEqual(c.afterTrip, .stayOff)
        XCTAssertEqual(c.armDefault, .untilTrip)
        XCTAssertTrue(c.notifyOnTrip); XCTAssertEqual(c.headsUpMinutes, 5); XCTAssertFalse(c.notifyOnManualArm)
        XCTAssertTrue(c.alertOnUnplug)
        XCTAssertEqual(c.logRetentionDays, 30); XCTAssertEqual(c.sampleMinutes, 5)
        XCTAssertEqual(c.holdingIntervalSeconds, 15); XCTAssertEqual(c.offIntervalSeconds, 60); XCTAssertEqual(c.leaseSeconds, 60)
        XCTAssertEqual(c.schedule, .default)
        XCTAssertEqual(c.clamped(), c, "defaults are inside their own ranges")
    }

    func testClampingLowAndHigh() {
        var c = Config()
        c.cpuLimit = 10; c.cpuSustainSeconds = -5; c.cpuClearMargin = 0
        c.gpuLimit = 500; c.gpuSustainSeconds = 9999; c.gpuClearMargin = 99
        c.batteryTempLimit = 5; c.batteryTempSustainSeconds = 1000; c.batteryTempClearMargin = 50
        c.floorPercent = 1; c.lidMinutes = 5000; c.idleCpuPercent = 90; c.idleMinutes = 1
        c.watchedMinutes = 1; c.networkMinutes = 1; c.capHours = 100; c.sensorFailureSeconds = 5
        c.headsUpMinutes = 90; c.logRetentionDays = 2; c.sampleMinutes = 500
        c.holdingIntervalSeconds = 1; c.offIntervalSeconds = 1000; c.leaseSeconds = 1000
        let k = c.clamped()
        XCTAssertEqual(k.cpuLimit, 60); XCTAssertEqual(k.cpuSustainSeconds, 0); XCTAssertEqual(k.cpuClearMargin, 2)
        XCTAssertEqual(k.gpuLimit, 100); XCTAssertEqual(k.gpuSustainSeconds, 120); XCTAssertEqual(k.gpuClearMargin, 20)
        XCTAssertEqual(k.batteryTempLimit, 30); XCTAssertEqual(k.batteryTempSustainSeconds, 120); XCTAssertEqual(k.batteryTempClearMargin, 10)
        XCTAssertEqual(k.floorPercent, 5); XCTAssertEqual(k.lidMinutes, 480); XCTAssertEqual(k.idleCpuPercent, 50); XCTAssertEqual(k.idleMinutes, 5)
        XCTAssertEqual(k.watchedMinutes, 5); XCTAssertEqual(k.networkMinutes, 2); XCTAssertEqual(k.capHours, 24); XCTAssertEqual(k.sensorFailureSeconds, 30)
        XCTAssertEqual(k.headsUpMinutes, 30); XCTAssertEqual(k.logRetentionDays, 7); XCTAssertEqual(k.sampleMinutes, 60)
        XCTAssertEqual(k.holdingIntervalSeconds, 5); XCTAssertEqual(k.offIntervalSeconds, 300); XCTAssertEqual(k.leaseSeconds, 120)
    }

    func testRangeEdgesAreKept() {
        var c = Config()
        c.cpuLimit = 60; c.gpuLimit = 100; c.floorPercent = 60; c.capHours = 1; c.lidMinutes = 10
        XCTAssertEqual(c.clamped(), c)
    }

    func testOffValuesStayOff() {
        var c = Config()
        c.headsUpMinutes = 0; c.logRetentionDays = 0; c.sampleMinutes = 0
        let k = c.clamped()
        XCTAssertEqual(k.headsUpMinutes, 0); XCTAssertEqual(k.logRetentionDays, 0); XCTAssertEqual(k.sampleMinutes, 0)
    }

    func testThermalLimitCannotBeNominal() {
        var c = Config()
        c.thermalLimit = .nominal
        XCTAssertEqual(c.clamped().thermalLimit, .fair)
    }

    func testWatchedNamesAreTrimmedAndNeverEmpty() {
        var c = Config()
        c.watchedNames = ["  node ", "", " "]
        XCTAssertEqual(c.clamped().watchedNames, ["node"])
        c.watchedNames = [" "]
        XCTAssertEqual(c.clamped().watchedNames, ["claude"])
    }

    func testEngineClampsAConfigItIsGiven() {
        var rig = Rig(tweak: { $0.cpuLimit = 5; $0.cpuSustainSeconds = 0 })
        rig.snap.cpuTemperature = 59
        rig.arm()
        XCTAssertEqual(rig.eval().phase, .holding, "limit was raised to 60")
    }

    func testMigrationFromAnOlderSettingsBlob() throws {
        // An old version knew only these keys, and one that no longer exists.
        let old = #"{"cpuLimit": 75, "capHours": 4, "removedLongAgo": true}"#
        let c = try Config.decodeLenient(from: Data(old.utf8))
        XCTAssertEqual(c.cpuLimit, 75)
        XCTAssertEqual(c.capHours, 4)
        XCTAssertEqual(c.gpuLimit, 85, "new fields take their default")
        XCTAssertTrue(c.alertOnUnplug)
        XCTAssertEqual(c.schedule, .default)
    }

    func testMigrationClampsStoredValues() throws {
        let c = try Config.decodeLenient(from: Data(#"{"floorPercent": 99, "alertOnUnplug": false}"#.utf8))
        XCTAssertEqual(c.floorPercent, 60)
        XCTAssertFalse(c.alertOnUnplug)
    }

    func testMigrationRejectsNonObjects() {
        XCTAssertThrowsError(try Config.decodeLenient(from: Data("[1,2]".utf8)))
    }

    func testRoundTrip() throws {
        var c = Config()
        c.cpuLimit = 70
        c.alertOnUnplug = false
        c.schedule = weekdays([TimeWindow(start: 60, end: 120)], on: [0, 6])
        let back = try Config.decodeLenient(from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
