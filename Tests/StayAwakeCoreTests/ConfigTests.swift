import XCTest
@testable import StayAwakeCore

final class ConfigTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let c = Config()
        XCTAssertEqual(c.configVersion, Config.currentVersion)
        XCTAssertTrue(c.cpuEnabled); XCTAssertEqual(c.cpuLimit, 100); XCTAssertEqual(c.cpuSustainSeconds, 120); XCTAssertEqual(c.cpuClearMargin, 10)
        XCTAssertEqual(c.smoothingSeconds, 60)
        XCTAssertTrue(c.gpuEnabled); XCTAssertEqual(c.gpuLimit, 95); XCTAssertEqual(c.gpuSustainSeconds, 120); XCTAssertEqual(c.gpuClearMargin, 10)
        XCTAssertEqual(c.batteryTempLimit, 43); XCTAssertEqual(c.batteryTempSustainSeconds, 60); XCTAssertEqual(c.batteryTempClearMargin, 3)
        XCTAssertFalse(c.batteryHeatingEnabled); XCTAssertEqual(c.batteryHeatingRise, 2)
        XCTAssertEqual(c.thermalLimit, .serious); XCTAssertEqual(c.thermalSustainSeconds, 300)
        XCTAssertEqual(c.floorPercent, 40)
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
        c.thermalSustainSeconds = 5000; c.batteryHeatingRise = 0; c.smoothingSeconds = -1
        c.floorPercent = 1; c.lidMinutes = 5000; c.idleCpuPercent = 90; c.idleMinutes = 1
        c.watchedMinutes = 1; c.networkMinutes = 1; c.capHours = 100; c.sensorFailureSeconds = 5
        c.headsUpMinutes = 90; c.logRetentionDays = 2; c.sampleMinutes = 500
        c.holdingIntervalSeconds = 1; c.offIntervalSeconds = 1000; c.leaseSeconds = 1000
        let k = c.clamped()
        XCTAssertEqual(k.cpuLimit, 60); XCTAssertEqual(k.cpuSustainSeconds, 0); XCTAssertEqual(k.cpuClearMargin, 2)
        XCTAssertEqual(k.gpuLimit, 110); XCTAssertEqual(k.gpuSustainSeconds, 300); XCTAssertEqual(k.gpuClearMargin, 20)
        XCTAssertEqual(k.batteryTempLimit, 30); XCTAssertEqual(k.batteryTempSustainSeconds, 300); XCTAssertEqual(k.batteryTempClearMargin, 10)
        XCTAssertEqual(k.thermalSustainSeconds, 600); XCTAssertEqual(k.batteryHeatingRise, 0.5); XCTAssertEqual(k.smoothingSeconds, 0)
        XCTAssertEqual(k.floorPercent, 5); XCTAssertEqual(k.lidMinutes, 480); XCTAssertEqual(k.idleCpuPercent, 50); XCTAssertEqual(k.idleMinutes, 5)
        XCTAssertEqual(k.watchedMinutes, 5); XCTAssertEqual(k.networkMinutes, 2); XCTAssertEqual(k.capHours, 12); XCTAssertEqual(k.sensorFailureSeconds, 30)
        XCTAssertEqual(k.headsUpMinutes, 30); XCTAssertEqual(k.logRetentionDays, 7); XCTAssertEqual(k.sampleMinutes, 60)
        XCTAssertEqual(k.holdingIntervalSeconds, 5); XCTAssertEqual(k.offIntervalSeconds, 300); XCTAssertEqual(k.leaseSeconds, 120)
    }

    func testRangeEdgesAreKept() {
        var c = Config()
        c.cpuLimit = 60; c.gpuLimit = 110; c.cpuSustainSeconds = 300; c.floorPercent = 60; c.capHours = 1; c.lidMinutes = 10
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
        XCTAssertEqual(c.cpuSustainSeconds, 20, "an edited rule keeps its old wait")
        XCTAssertEqual(c.capHours, 4)
        XCTAssertEqual(c.gpuLimit, 95, "missing fields take the new default")
        XCTAssertEqual(c.configVersion, Config.currentVersion)
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

    // MARK: Version 1 to 2

    /// What version 1 stored for a user who never touched the heat limits.
    private func v1Blob(_ overrides: [String: Any] = [:]) throws -> Data {
        var d: [String: Any] = ["cpuEnabled": true, "cpuLimit": 90, "cpuSustainSeconds": 20, "cpuClearMargin": 10,
                                "gpuEnabled": true, "gpuLimit": 85, "gpuSustainSeconds": 20, "gpuClearMargin": 10,
                                "batteryTempEnabled": true, "batteryTempLimit": 40, "batteryTempSustainSeconds": 30,
                                "batteryTempClearMargin": 4, "thermalEnabled": true, "thermalLimit": "serious",
                                "floorPercent": 20, "capHours": 8]
        for (k, v) in overrides { d[k] = v }
        return try JSONSerialization.data(withJSONObject: d)
    }

    func testUntouchedVersion1DefaultsMoveToBalanced() throws {
        let c = try Config.decodeLenient(from: v1Blob())
        XCTAssertEqual(c, Config(), "an untouched install ends up on the new defaults")
        XCTAssertEqual(SafetyPreset.matching(c), .balanced)
    }

    func testEditedVersion1RuleKeepsItsValues() throws {
        let c = try Config.decodeLenient(from: v1Blob(["cpuLimit": 95, "batteryTempSustainSeconds": 45]))
        XCTAssertEqual(c.cpuLimit, 95)
        XCTAssertEqual(c.cpuSustainSeconds, 20, "the CPU rule was edited, so its wait stays too")
        XCTAssertEqual(c.batteryTempLimit, 40)
        XCTAssertEqual(c.batteryTempSustainSeconds, 45)
        XCTAssertEqual(c.gpuLimit, 95, "the untouched GPU rule still moves")
        XCTAssertEqual(c.gpuSustainSeconds, 120)
        XCTAssertEqual(c.batteryTempClearMargin, 3)
    }

    func testVersion2IsNotMigratedAgain() throws {
        // A version 2 user who picked 90 C on purpose keeps it.
        var mine = Config()
        mine.cpuLimit = 90; mine.cpuSustainSeconds = 20
        let back = try Config.decodeLenient(from: JSONEncoder().encode(mine))
        XCTAssertEqual(back.cpuLimit, 90)
        XCTAssertEqual(back.cpuSustainSeconds, 20)
    }

    /// What version 2 stored: the 102 / 100 defaults, in full.
    private func v2Blob(_ overrides: [String: Any] = [:]) throws -> Data {
        var d = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        d["configVersion"] = 2
        d["cpuLimit"] = 102; d["gpuLimit"] = 100
        for (k, v) in overrides { d[k] = v }
        return try JSONSerialization.data(withJSONObject: d)
    }

    func testUntouchedVersion2DefaultsMoveToBalanced() throws {
        let c = try Config.decodeLenient(from: v2Blob())
        XCTAssertEqual(c, Config())
        XCTAssertEqual(c.cpuLimit, 100); XCTAssertEqual(c.gpuLimit, 95)
    }

    func testEditedVersion2LimitsStay() throws {
        let c = try Config.decodeLenient(from: v2Blob(["cpuLimit": 104, "gpuSustainSeconds": 90]))
        XCTAssertEqual(c.cpuLimit, 104)
        XCTAssertEqual(c.gpuLimit, 100, "the GPU rule was edited (wait), so its limit stays too")
        XCTAssertEqual(c.gpuSustainSeconds, 90)
    }

    // MARK: Version 3 to 4

    /// What version 3 stored: the whole Balanced config with the old floor of 20.
    private func v3Blob(floor: Int?) throws -> Data {
        var d = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        d["configVersion"] = 3
        d["floorPercent"] = floor
        if floor == nil { d.removeValue(forKey: "floorPercent") }
        return try JSONSerialization.data(withJSONObject: d)
    }

    func testUntouchedFloorOf20MovesTo40() throws {
        let c = try Config.decodeLenient(from: v3Blob(floor: 20))
        XCTAssertEqual(c.floorPercent, 40)
        XCTAssertEqual(c, Config())
        XCTAssertEqual(try Config.decodeLenient(from: v3Blob(floor: nil)).floorPercent, 40)
    }

    func testEditedFloorStaysAfterMigration() throws {
        XCTAssertEqual(try Config.decodeLenient(from: v3Blob(floor: 30)).floorPercent, 30)
        XCTAssertEqual(try Config.decodeLenient(from: v3Blob(floor: 10)).floorPercent, 10)
        XCTAssertEqual(try Config.decodeLenient(from: v3Blob(floor: 55)).floorPercent, 55)
    }

    func testFloorOf20OnVersion4IsNotMigratedAgain() throws {
        var mine = Config()
        mine.floorPercent = 20
        let back = try Config.decodeLenient(from: JSONEncoder().encode(mine))
        XCTAssertEqual(back.floorPercent, 20, "picked on purpose after the bump")
    }

    func testVersion4StoredConfigGainsRearmSettingOffAndKeepsFloor() throws {
        var d = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as! [String: Any]
        d["configVersion"] = 4
        d["floorPercent"] = 20
        d.removeValue(forKey: "rearmWhenPluggedIn")
        let c = try Config.decodeLenient(from: JSONSerialization.data(withJSONObject: d))
        XCTAssertFalse(c.rearmWhenPluggedIn)
        XCTAssertEqual(c.floorPercent, 20)
        XCTAssertEqual(c.configVersion, 5)
    }

    func testMigrationIsIdempotent() throws {
        let once = try Config.decodeLenient(from: v1Blob(["gpuLimit": 80]))
        let twice = try Config.decodeLenient(from: JSONEncoder().encode(once))
        XCTAssertEqual(once, twice)
    }

    func testStoredCapAboveTwelveHoursLoadsAsTwelve() throws {
        let stored = Data(#"{"capHours": 24}"#.utf8)
        let c = try Config.decodeLenient(from: stored)
        XCTAssertEqual(c.capHours, 12)
        XCTAssertEqual(ConfigRange.capHours, 1...12)
    }

    func testRangesComeFromOnePlace() {
        var c = Config()
        c.cpuLimit = ConfigRange.cpuLimit.upperBound + 5
        c.batteryTempSustainSeconds = ConfigRange.sustainSeconds.upperBound + 1
        XCTAssertEqual(c.clamped().cpuLimit, ConfigRange.cpuLimit.upperBound)
        XCTAssertEqual(c.clamped().batteryTempSustainSeconds, ConfigRange.sustainSeconds.upperBound)
    }
}
