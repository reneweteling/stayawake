import XCTest
@testable import StayAwakeCore

final class LeaseTests: XCTestCase {
    let t0 = iso("2026-11-09T09:00:00Z")
    let boot = "BOOT-A"

    func testGrantIsValidForTheRequestedTime() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        XCTAssertEqual(lease.verdict(now: t0, bootSession: boot), .valid(remaining: 60))
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(59), bootSession: boot), .valid(remaining: 1))
    }

    func testExpiryReleases() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(60), bootSession: boot), .expired)
        XCTAssertFalse(Lease.shouldHold(lease, now: t0.addingTimeInterval(61), bootSession: boot))
    }

    func testHeartbeatExtendsTheLease() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        lease = lease.heartbeat(now: t0.addingTimeInterval(50), bootSession: boot, seconds: 60)!
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(100), bootSession: boot), .valid(remaining: 10))
    }

    func testHeartbeatAfterExpiryIsRefused() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        XCTAssertNil(lease.heartbeat(now: t0.addingTimeInterval(61), bootSession: boot, seconds: 60))
    }

    func testHeartbeatLengthIsCappedAt120Seconds() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 10_000)
        XCTAssertEqual(lease.verdict(now: t0, bootSession: boot), .valid(remaining: 120))
        lease = lease.heartbeat(now: t0.addingTimeInterval(10), bootSession: boot, seconds: 99_999)!
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(10), bootSession: boot), .valid(remaining: 120))
    }

    func testZeroOrNegativeSecondsStillGiveAtLeastOne() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: -5)
        XCTAssertEqual(lease.verdict(now: t0, bootSession: boot), .valid(remaining: 1))
    }

    func testBootSessionMismatchVoidsTheLease() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(1), bootSession: "BOOT-B"), .bootSessionMismatch)
        XCTAssertNil(lease.heartbeat(now: t0.addingTimeInterval(1), bootSession: "BOOT-B", seconds: 60))
    }

    func testTwelveHourCeilingHoldsNoMatterHowOftenHeartbeatsArrive() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        var now = t0
        var ended: LeaseVerdict?
        for _ in 0..<(13 * 360) {
            now = now.addingTimeInterval(10)
            if let next = lease.heartbeat(now: now, bootSession: boot, seconds: 60) { lease = next }
            else { ended = lease.verdict(now: now, bootSession: boot); break }
        }
        XCTAssertEqual(ended, .ceilingReached)
        XCTAssertLessThanOrEqual(now.timeIntervalSince(t0), 12 * 3600 + 10)
    }

    func testHeartbeatNeverExtendsPastTheCeiling() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        let near = t0.addingTimeInterval(12 * 3600 - 30)
        lease.expiresAt = near.addingTimeInterval(30)
        lease.lastSeen = near
        let extended = lease.heartbeat(now: near, bootSession: boot, seconds: 120)!
        XCTAssertEqual(extended.expiresAt, t0.addingTimeInterval(12 * 3600))
    }

    func testCeilingVerdictAtExactlyTwelveHours() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 120)
        lease.expiresAt = t0.addingTimeInterval(13 * 3600)
        XCTAssertEqual(lease.verdict(now: t0.addingTimeInterval(12 * 3600), bootSession: boot), .ceilingReached)
    }

    func testClockJumpingBackwardsVoidsTheLease() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        lease = lease.heartbeat(now: t0.addingTimeInterval(30), bootSession: boot, seconds: 60)!
        let jumped = t0.addingTimeInterval(30 - 3600)
        XCTAssertEqual(lease.verdict(now: jumped, bootSession: boot), .clockWentBackwards)
        XCTAssertNil(lease.heartbeat(now: jumped, bootSession: boot, seconds: 60))
    }

    func testSmallBackwardsDriftIsTolerated() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        lease = lease.heartbeat(now: t0.addingTimeInterval(30), bootSession: boot, seconds: 60)!
        XCTAssertTrue(lease.verdict(now: t0.addingTimeInterval(29), bootSession: boot).isValid)
    }

    func testNoLeaseMeansNoHold() {
        XCTAssertFalse(Lease.shouldHold(nil, now: t0, bootSession: boot))
    }

    func testLeaseSurvivesEncodingForTheStateFile() throws {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        let data = try JSONEncoder().encode(lease)
        XCTAssertEqual(try JSONDecoder().decode(Lease.self, from: data), lease)
    }
}
