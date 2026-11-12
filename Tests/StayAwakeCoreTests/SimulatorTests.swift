import XCTest
@testable import StayAwakeCore

final class SimulatorTests: XCTestCase {
    func run(_ json: String) throws -> [Simulator.StepResult] {
        try Simulator.run(try Simulator.parse(Data(json.utf8)))
    }

    func testScenarioArmsHoldsAndTrips() throws {
        let r = try run("""
        { "start": "2026-11-09T09:00:00Z", "timeZone": "Europe/Amsterdam",
          "config": { "cpuSustainSeconds": 0, "smoothingSeconds": 0, "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "steps": [
            { "at": 0, "command": "arm" },
            { "at": 15, "snapshot": { "cpuTemperature": 50.5 } },
            { "at": 30, "snapshot": { "cpuTemperature": 105 } }
          ] }
        """)
        XCTAssertEqual(r.map(\.decision.phase), [.holding, .holding, .tripped])
        XCTAssertEqual(r[0].armOutcome, .holding)
        XCTAssertEqual(r[2].decision.trip?.rule, .cpuTemperature)
        XCTAssertTrue(r[2].line.contains("TRIP HOT 105°"))
    }

    func testSnapshotPatchesCarryForwardAndMissingClearsReadings() throws {
        let r = try run("""
        { "config": { "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "steps": [
            { "at": 0, "command": "arm" },
            { "at": 15, "missing": ["cpuTemperature"] },
            { "at": 30 }, { "at": 45 }, { "at": 60 }, { "at": 75 },
            { "at": 90, "snapshot": { "batteryPercent": 79 } }
          ] }
        """)
        XCTAssertEqual(r.compactMap(\.decision.trip).first?.rule, .sensorFailure, "the missing CPU reading carried forward")
    }

    func testUnplugAlertShowsInSimulation() throws {
        let r = try run("""
        { "config": { "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "snapshot": { "powerSource": "ac" },
          "steps": [ { "at": 0, "command": "arm" }, { "at": 15, "snapshot": { "powerSource": "battery" } } ] }
        """)
        XCTAssertEqual(r[1].decision.alerts, [.unpluggedWhileHolding])
        XCTAssertTrue(r[1].line.contains("unpluggedWhileHolding"))
    }

    func testRefusedArmShowsInLine() throws {
        let r = try run("""
        { "config": { "floorPercent": 60, "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "snapshot": { "batteryPercent": 50 },
          "steps": [ { "at": 0, "command": "arm" } ] }
        """)
        XCTAssertEqual(r[0].decision.phase, .off)
        XCTAssertTrue(r[0].line.contains("refused=[LOW 50%]"))
    }

    func testDisarmAndAcknowledge() throws {
        let r = try run("""
        { "config": { "schedule": { "enabled": false, "days": [[],[],[],[],[],[],[]] } },
          "steps": [ { "at": 0, "command": "arm" }, { "at": 15, "command": "disarm" } ] }
        """)
        XCTAssertEqual(r[1].decision.action, .release)
        XCTAssertEqual(r[1].decision.phase, .off)
    }

    func testBadScenarios() {
        XCTAssertThrowsError(try run("[]"))
        XCTAssertThrowsError(try run("{}"))
        XCTAssertThrowsError(try run(#"{"steps":[{"command":"arm"}]}"#))
        XCTAssertThrowsError(try run(#"{"steps":[{"at":0,"command":"explode"}]}"#))
        XCTAssertThrowsError(try run(#"{"start":"yesterday","steps":[]}"#))
        XCTAssertThrowsError(try run(#"{"timeZone":"Mars/Base","steps":[]}"#))
    }
}
