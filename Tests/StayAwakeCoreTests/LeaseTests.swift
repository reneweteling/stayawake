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

    func testNoCeilingAfterDaysOfHeartbeats() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        var now = t0
        // Four days of heartbeats every 10 s: the lease never ends by itself.
        for _ in 0..<(96 * 360) {
            now = now.addingTimeInterval(10)
            guard let next = lease.heartbeat(now: now, bootSession: boot, seconds: 60) else {
                return XCTFail("lease ended after \(now.timeIntervalSince(t0) / 3600) h")
            }
            lease = next
        }
        XCTAssertEqual(lease.verdict(now: now, bootSession: boot), .valid(remaining: 60))
        XCTAssertEqual(lease.startedAt, t0)
    }

    func testLeaseStillExpiresAfterALongHoldWhenHeartbeatsStop() {
        var lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        let late = t0.addingTimeInterval(86 * 3600)
        lease.lastSeen = late
        lease.expiresAt = late.addingTimeInterval(60)
        XCTAssertTrue(lease.verdict(now: late.addingTimeInterval(59), bootSession: boot).isValid)
        XCTAssertEqual(lease.verdict(now: late.addingTimeInterval(60), bootSession: boot), .expired)
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
