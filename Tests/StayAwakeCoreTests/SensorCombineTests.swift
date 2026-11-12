import XCTest
@testable import StayAwakeCore

final class SensorCombineTests: XCTestCase {
    func testTheHotterFamilyWins() {
        // The M2 Max case: HID tdie 49 while the curated SMC keys read 66.
        XCTAssertEqual(SensorCombine.cpu(hid: 49, smc: 66), 66)
        XCTAssertEqual(SensorCombine.cpu(hid: 75, smc: 58), 75)
    }

    func testOneFamilyAloneIsUsed() {
        XCTAssertEqual(SensorCombine.cpu(hid: 49, smc: nil), 49)
        XCTAssertEqual(SensorCombine.cpu(hid: nil, smc: 61.5), 61.5)
        XCTAssertEqual(SensorCombine.gpu(hid: nil, smc: 52), 52)
    }

    func testNothingReadableGivesNil() {
        XCTAssertNil(SensorCombine.cpu(hid: nil, smc: nil))
        XCTAssertNil(SensorCombine.gpu(hid: nil, smc: nil))
    }

    func testImplausibleValuesAreDroppedNotPreferred() {
        // A glitching sensor must not win just because it is "hottest".
        XCTAssertEqual(SensorCombine.cpu(hid: 400, smc: 60), 60)
        XCTAssertEqual(SensorCombine.cpu(hid: -5, smc: 60), 60)
        XCTAssertEqual(SensorCombine.cpu(hid: 0, smc: 60), 60)
        XCTAssertNil(SensorCombine.cpu(hid: 400, smc: -1))
    }

    func testTheEdgesOfTheRangeCount() {
        XCTAssertEqual(SensorCombine.cpu(hid: 130, smc: 20), 130)
        XCTAssertEqual(SensorCombine.cpu(hid: 1, smc: nil), 1)
    }

    func testCombinedValueDrivesTheCPURule() {
        // HID alone (49) would sit far below the 90 limit; the combined value trips it.
        var rig = Rig { $0.cpuSustainSeconds = 0 }
        rig.snap.cpuTemperature = SensorCombine.cpu(hid: 49, smc: 92)
        let result = rig.arm()
        guard case .refused(let trips) = result.outcome else { return XCTFail("expected the arm to be refused") }
        XCTAssertEqual(trips.first?.rule, .cpuTemperature)
    }
}
