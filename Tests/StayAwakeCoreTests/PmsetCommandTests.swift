import XCTest
@testable import StayAwakeCore

final class PmsetCommandTests: XCTestCase {
    func testExactlyTwoCommandsExist() {
        XCTAssertEqual(PmsetCommand.allCases.count, 2)
    }

    func testTheTwoArgvArraysAreFixed() {
        XCTAssertEqual(PmsetCommand.disableSleepOn.argv, ["/usr/bin/pmset", "-a", "disablesleep", "1"])
        XCTAssertEqual(PmsetCommand.disableSleepOff.argv, ["/usr/bin/pmset", "-a", "disablesleep", "0"])
        XCTAssertEqual(Set(PmsetCommand.allCases.map(\.argv)).count, 2)
    }

    func testOnlyTheTwoArraysParseBack() {
        for c in PmsetCommand.allCases { XCTAssertEqual(PmsetCommand(argv: c.argv), c) }
        XCTAssertNil(PmsetCommand(argv: ["/usr/bin/pmset", "-a", "disablesleep", "2"]))
        XCTAssertNil(PmsetCommand(argv: ["/usr/bin/pmset", "-a", "disablesleep", "1", "; rm -rf /"]))
        XCTAssertNil(PmsetCommand(argv: ["/bin/sh", "-c", "pmset -a disablesleep 1"]))
        XCTAssertNil(PmsetCommand(argv: ["/usr/bin/pmset", "sleepnow"]))
        XCTAssertNil(PmsetCommand(argv: []))
    }

    func testDecodingUnknownRawValuesFails() {
        XCTAssertThrowsError(try JSONDecoder().decode(PmsetCommand.self, from: Data("\"sleepnow\"".utf8)))
    }
}
