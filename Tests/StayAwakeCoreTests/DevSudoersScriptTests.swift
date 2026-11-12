import XCTest
@testable import StayAwakeCore

/// scripts/dev-sudoers.sh must allow exactly the two PmsetCommand argvs and nothing else.
final class DevSudoersScriptTests: XCTestCase {
    private func script() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/dev-sudoers.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheScriptInstallsExactlyTheTwoRules() throws {
        let text = try script()
        let rules = text.split(separator: "\n").filter { $0.hasPrefix("RULE_") }.map(String.init)
        XCTAssertEqual(rules.count, 2)
        for command in PmsetCommand.allCases {
            let expected = command.sudoersRule(user: "$USER_NAME")
            XCTAssertTrue(rules.contains { $0.hasSuffix("\"\(expected)\"") }, "missing rule: \(expected)")
        }
        for rule in rules {
            XCTAssertFalse(rule.contains("*"), "no wildcards in \(rule)")
            XCTAssertFalse(rule.contains("ALL=(ALL)"), rule)
        }
    }

    func testTheScriptValidatesBeforeInstalling() throws {
        let text = try script()
        let validate = try XCTUnwrap(text.range(of: "visudo -c -f \"$TMP\""))
        let install = try XCTUnwrap(text.range(of: "sudo install"))
        XCTAssertLessThan(validate.lowerBound, install.lowerBound)
    }

    func testSudoArgvIsFixed() {
        XCTAssertEqual(PmsetCommand.disableSleepOff.sudoArgv, ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
        XCTAssertEqual(PmsetCommand.disableSleepOn.sudoArgv, ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }
}
