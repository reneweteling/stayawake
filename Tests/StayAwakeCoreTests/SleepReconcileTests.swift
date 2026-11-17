import XCTest
@testable import StayAwakeCore

final class SleepReconcileTests: XCTestCase {
    private func need(_ phase: Phase, _ disabled: Bool?, leaseLost: Bool = false,
                      owed: Bool = false, clearLeftover: Bool = false) -> SleepReconcile.Need {
        SleepReconcile.need(phase: phase, sleepDisabled: disabled, leaseLost: leaseLost,
                            releaseOwed: owed, clearLeftover: clearLeftover)
    }

    func testHoldingWithSleepBlockedNeedsNothing() {
        XCTAssertEqual(need(.holding, true), .nothing)
    }

    func testHoldingButSleepAllowedHoldsAgain() {
        XCTAssertEqual(need(.holding, false), .hold)
    }

    func testLostLeaseHoldsAgainEvenWhileStillBlocked() {
        XCTAssertEqual(need(.holding, true, leaseLost: true), .hold)
    }

    func testUnreadablePmsetWhileHoldingDoesNotSpamHolds() {
        XCTAssertEqual(need(.holding, nil), .nothing)
    }

    func testOffWithOurSleepDisabledStillOnReleases() {
        for phase in [Phase.off, .tripped, .waiting] {
            XCTAssertEqual(need(phase, true, owed: true), .release, "\(phase)")
        }
    }

    func testLeftoverIsClearedOnlyWhenTheUserAllowsIt() {
        XCTAssertEqual(need(.off, true, clearLeftover: true), .release)
        XCTAssertEqual(need(.off, true), .nothing, "someone else's setting, left alone")
    }

    func testOffAndSleepingNormallyNeedsNothing() {
        XCTAssertEqual(need(.off, false, owed: true, clearLeftover: true), .nothing)
        XCTAssertEqual(need(.off, nil, owed: true), .nothing)
    }
}

final class HelperRetryTests: XCTestCase {
    func testBackoffIsOneTwoFiveThenSteady() {
        XCTAssertEqual((1...7).map { HelperRetry.delay(afterFailures: $0) }, [1, 2, 5, 15, 15, 15, 15])
        XCTAssertEqual(HelperRetry.delay(afterFailures: 0), 0)
    }

    func testRetriesWaitForTheBackoff() {
        var r = HelperRetry()
        XCTAssertTrue(r.mayAttempt(now: 0))
        r.failed("connection failed", now: 100)
        XCTAssertFalse(r.mayAttempt(now: 100.5))
        XCTAssertTrue(r.mayAttempt(now: 101))
        r.failed("connection failed", now: 101)
        XCTAssertEqual(r.wait(now: 101), 2)
        r.failed("connection failed", now: 103)
        XCTAssertEqual(r.wait(now: 103), 5)
    }

    func testNeverStopsRetrying() {
        var r = HelperRetry()
        var t: TimeInterval = 0
        for _ in 0..<10_000 {
            r.failed("down", now: t)
            t += r.wait(now: t)!
            XCTAssertTrue(r.mayAttempt(now: t))
        }
        XCTAssertEqual(r.failures, 10_000)
    }

    func testSuccessClearsTheTrouble() {
        var r = HelperRetry()
        r.failed("down", now: 0)
        r.failed("down", now: 1)
        XCTAssertTrue(r.inTrouble)
        r.succeeded()
        XCTAssertFalse(r.inTrouble)
        XCTAssertNil(r.lastError)
        XCTAssertNil(r.wait(now: 2))
        XCTAssertTrue(r.mayAttempt(now: 2))
    }

    func testReregistersAfterFourFailuresAndThenAtMostEveryTenMinutes() {
        var r = HelperRetry()
        for i in 0..<3 { r.failed("down", now: Double(i)) }
        XCTAssertFalse(r.shouldReregister(now: 3))
        r.failed("down", now: 3)
        XCTAssertTrue(r.shouldReregister(now: 4))
        r.didReregister(now: 4)
        r.failed("down", now: 5)
        XCTAssertFalse(r.shouldReregister(now: 5))
        XCTAssertFalse(r.shouldReregister(now: 4 + HelperRetry.reregisterCooldown - 1))
        XCTAssertTrue(r.shouldReregister(now: 4 + HelperRetry.reregisterCooldown))
    }

    func testReregisterCooldownSurvivesARecovery() {
        var r = HelperRetry()
        for i in 0..<4 { r.failed("down", now: Double(i)) }
        r.didReregister(now: 4)
        r.succeeded()
        for i in 0..<4 { r.failed("down", now: 10 + Double(i)) }
        XCTAssertFalse(r.shouldReregister(now: 20), "no unregister loop")
    }

    func testGivesUpHoldingOnlyAfterALongOutage() {
        var r = HelperRetry()
        XCTAssertFalse(r.shouldGiveUpHolding(now: 1_000))
        r.failed("down", now: 100)
        r.failed("down", now: 101)
        XCTAssertFalse(r.shouldGiveUpHolding(now: 100 + HelperRetry.giveUpHoldingAfter - 1))
        XCTAssertTrue(r.shouldGiveUpHolding(now: 100 + HelperRetry.giveUpHoldingAfter))
        r.succeeded()
        XCTAssertFalse(r.shouldGiveUpHolding(now: 10_000))
    }
}
