import XCTest
@testable import StayAwakeCore

/// SMC fixtures captured on a MacBook Pro (Mac14,5, Apple M2 Max, macOS 26).
final class SMCKeysTests: XCTestCase {
    private func fixture(_ name: String) throws -> [SMCKey] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
        return SMCTemperatureKeys.parse(try String(contentsOf: url, encoding: .utf8))
    }

    private func key(_ all: [SMCKey], _ name: String) -> Double? { all.first { $0.key == name }?.celsius }

    // MARK: Chip family

    func testFamilyFromBrandString() {
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M1"), .m1)
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M2 Max"), .m2)
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M3 Pro"), .m3)
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M4"), .m4)
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M5 Max"), .m5)
        XCTAssertEqual(ChipFamily.detect(brand: "Apple M9 Ultra"), .unknown)
        XCTAssertEqual(ChipFamily.detect(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz"), .unknown)
        XCTAssertEqual(ChipFamily.detect(brand: "unknown"), .unknown)
    }

    func testEveryKnownFamilyHasCPUAndGPUKeys() {
        for f in ChipFamily.allCases where f != .unknown {
            XCTAssertFalse(SMCTemperatureKeys.cpu(f).isEmpty, f.rawValue)
            XCTAssertFalse(SMCTemperatureKeys.gpu(f).isEmpty, f.rawValue)
            XCTAssertTrue(Set(SMCTemperatureKeys.cpu(f)).isDisjoint(with: SMCTemperatureKeys.gpu(f)), f.rawValue)
        }
        XCTAssertTrue(SMCTemperatureKeys.cpu(.unknown).isEmpty)
    }

    // MARK: Fixtures

    func testFixturesParse() throws {
        let idle = try fixture("smc-m2max-idle.txt")
        XCTAssertGreaterThan(idle.count, 100)
        XCTAssertEqual(key(idle, "Tp01"), 58.29)
        XCTAssertEqual(key(idle, "Tf06"), 112.42)
        XCTAssertEqual(try fixture("smc-m2max-load.txt").count, 128)
    }

    func testIdleM2MaxReadsThePerCoreKeysNotTheHotspotEstimates() throws {
        let all = try fixture("smc-m2max-idle.txt")
        // The old rule: max over every Tp key. It lands on an estimate key.
        let oldMax = all.filter { $0.key.hasPrefix("Tp") }.map(\.celsius).max()
        XCTAssertEqual(oldMax, 64.36)

        let c = SensorCombine.choose(.cpu, hid: 45.74, smc: all, family: .m2)
        XCTAssertEqual(c.smc, 58.29)
        XCTAssertEqual(c.value, 58.29)
        // The E cluster was power gated: its keys read the bare offsets and are skipped.
        XCTAssertEqual(c.used.map(\.key), ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"])
        XCTAssertTrue(c.source.hasPrefix("max(hid 45.7, smc 58.3 Tp01"))
        XCTAssertFalse(c.source.contains("disagree"))

        // Tf06 reads 112 on an M2; it is not a CPU key here and must never count.
        XCTAssertFalse(c.used.contains { $0.key.hasPrefix("Tf") })

        let g = SensorCombine.choose(.gpu, hid: nil, smc: all, family: .m2)
        XCTAssertEqual(g.used.map(\.key), ["Tg0f", "Tg0j"])
        XCTAssertEqual(g.value, 56.38)
    }

    func testLoadM2MaxStillPicksTheCuratedMax() throws {
        let all = try fixture("smc-m2max-load.txt")
        let c = SensorCombine.choose(.cpu, hid: 49.56, smc: all, family: .m2)
        XCTAssertEqual(c.value, 71.10)
        XCTAssertEqual(c.used.count, 12)
        // HID tdie lags far behind under load; the gap is named, the hotter wins.
        XCTAssertTrue(c.source.contains("disagree by 21.5 C"))
        XCTAssertEqual(SensorCombine.choose(.gpu, hid: nil, smc: all, family: .m2).value, 66.44)
    }

    func testFullyGatedSampleFallsBackToHID() throws {
        let all = try fixture("smc-m2max-gated.txt")
        XCTAssertEqual(key(all, "Tp01"), 6.70)
        let c = SensorCombine.choose(.cpu, hid: 45.74, smc: all, family: .m2)
        XCTAssertNil(c.smc)
        XCTAssertTrue(c.used.isEmpty)
        XCTAssertEqual(c.value, 45.74)
        XCTAssertEqual(c.source, "hid 45.7")
    }

    // MARK: Fail toward hot

    func testHIDWinsWhenItIsHotter() throws {
        let all = try fixture("smc-m2max-idle.txt")
        XCTAssertEqual(SensorCombine.choose(.cpu, hid: 95, smc: all, family: .m2).value, 95)
    }

    func testUnknownChipUsesHIDOnly() throws {
        let all = try fixture("smc-m2max-load.txt")
        let c = SensorCombine.choose(.cpu, hid: 49.56, smc: all, family: .unknown)
        XCTAssertEqual(c.value, 49.56)
        XCTAssertTrue(c.used.isEmpty)
    }

    func testUnknownChipWithoutHIDTakesEveryPlausibleKey() throws {
        let all = try fixture("smc-m2max-load.txt")
        let c = SensorCombine.choose(.cpu, hid: nil, smc: all, family: .unknown)
        // Max over every Tp/Te key: reads high, but that is the safe side.
        XCTAssertEqual(c.value, 76.83)
        XCTAssertTrue(c.used.allSatisfy { $0.key.hasPrefix("Tp") || $0.key.hasPrefix("Te") })
        XCTAssertTrue(c.used.allSatisfy { SMCTemperatureKeys.plausible.contains($0.celsius) })
        XCTAssertTrue(c.source.contains("unknown chip"))
    }

    func testKnownChipWithMissingKeysAndNoHIDFallsBackToo() {
        let other = [SMCKey(key: "Tp0Z", celsius: 70), SMCKey(key: "Tp01", celsius: 5)]
        let c = SensorCombine.choose(.cpu, hid: nil, smc: other, family: .m2)
        XCTAssertEqual(c.value, 70)
        XCTAssertTrue(c.source.contains("no m2 key readable"))
    }

    func testSensorModes() throws {
        let all = try fixture("smc-m2max-idle.txt")
        XCTAssertEqual(SensorCombine.choose(.cpu, hid: 45.74, smc: all, family: .m2, useSMC: false).value, 45.74)
        XCTAssertEqual(SensorCombine.choose(.cpu, hid: 99, smc: all, family: .m2, useHID: false).value, 58.29)
        XCTAssertEqual(SensorCombine.choose(.cpu, hid: nil, smc: [], family: .m2), .none)
    }

    func testImplausibleHIDIsDropped() throws {
        let all = try fixture("smc-m2max-idle.txt")
        XCTAssertEqual(SensorCombine.choose(.cpu, hid: 400, smc: all, family: .m2).value, 58.29)
    }

    // MARK: Report table

    func testTableMarksSelectedAndGatedKeys() throws {
        let rows = SensorCombine.table(try fixture("smc-m2max-idle.txt"), family: .m2)
        XCTAssertTrue(rows.contains("Tp01 =   58.29  <- CPU"))
        XCTAssertTrue(rows.contains("Tp1h =    6.70  <- CPU (gated, ignored)"))
        XCTAssertTrue(rows.contains("Tg0j =   56.38  <- GPU"))
        XCTAssertTrue(rows.contains("Tp02 =   64.36"))
        // The table parses back.
        XCTAssertEqual(SMCTemperatureKeys.parse(rows.joined(separator: "\n")).count, rows.count)
    }
}
