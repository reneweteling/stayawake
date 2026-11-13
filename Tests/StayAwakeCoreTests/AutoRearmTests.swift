import XCTest
@testable import StayAwakeCore

final class AutoRearmTests: XCTestCase {
    private func decide(enabled: Bool = true, trip: RuleID? = .batteryFloor, source: PowerSource = .ac,
                        percent: Int? = 45, floorEnabled: Bool = true, floor: Int = 40,
                        clear: Bool = true) -> Bool {
        AutoRearm.shouldRearm(enabled: enabled, lastTrip: trip, powerSource: source, batteryPercent: percent,
                              floorEnabled: floorEnabled, floorPercent: floor, otherRulesClear: clear)
    }

    func testRearmsOnAcAboveFloorAfterBatteryFloorStop() { XCTAssertTrue(decide()) }
    func testRearmsExactlyAtFloor() { XCTAssertTrue(decide(percent: 40)) }
    func testNotOnBattery() { XCTAssertFalse(decide(source: .battery)) }
    func testNotBelowFloorEvenOnAc() { XCTAssertFalse(decide(percent: 39)) }
    func testNotWithUnreadableLevel() { XCTAssertFalse(decide(percent: nil)) }
    func testNotWhenSettingOff() { XCTAssertFalse(decide(enabled: false)) }
    func testNotWhenAnotherRuleBlocks() { XCTAssertFalse(decide(clear: false)) }
    func testNotAfterOtherTripReasons() {
        for rule in [RuleID.cpuTemperature, .gpuTemperature, .batteryTemperature, .batteryHeating, .thermalPressure,
                     .sensorFailure, .hardCap, .schedule, .lidOnBattery, .noNetwork, .idle, .watchedProcess] {
            XCTAssertFalse(decide(trip: rule), "\(rule)")
        }
        XCTAssertFalse(decide(trip: nil))
    }
}
