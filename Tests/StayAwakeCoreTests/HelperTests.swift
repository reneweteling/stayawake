import Security
import XCTest
@testable import StayAwakeCore

// MARK: - Fakes

final class FakeEffects: HelperEffects {
    var runs: [PmsetCommand] = []
    var exitCodes: [PmsetCommand: Int32?] = [:]
    var stored: Data?
    var saveFails = false
    var sleepDisabled: Bool? = false
    var logs: [String] = []

    func run(_ command: PmsetCommand) -> Int32? {
        runs.append(command)
        let code = exitCodes[command] ?? 0
        if code == 0 { sleepDisabled = command == .disableSleepOn }
        return code
    }
    func readSleepDisabled() -> Bool? { sleepDisabled }
    func loadState() -> Data? { stored }
    func saveState(_ data: Data) throws {
        if saveFails { throw NSError(domain: "test", code: 1) }
        stored = data
    }
    func log(_ message: String, isError: Bool) { logs.append(message) }
}

final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

private let t0 = iso("2026-11-09T09:00:00Z")

private func makeEngine(_ fx: FakeEffects = FakeEffects(), clock: Clock = Clock(t0), boot: String? = "BOOT-A") -> HelperEngine {
    HelperEngine(effects: fx, version: "1.4.0", codeHash: "abc", now: { clock.now }, bootSession: { boot })
}

// MARK: - Request validation

final class HelperRequestTests: XCTestCase {
    func testLeaseInRangeIsAccepted() {
        for s in [1, 30, 60, 120] {
            XCTAssertEqual(try HelperRequest.validateHold(leaseSeconds: s, reason: "arm").get(), .hold(leaseSeconds: s, reason: "arm"))
        }
    }

    func testLeaseOutOfRangeIsRejected() {
        for s in [0, -1, 121, 3600, Int.max, Int.min] {
            XCTAssertEqual(HelperRequest.validateHold(leaseSeconds: s, reason: "arm"), .failure(.leaseOutOfRange(s)))
        }
    }

    func testReasonMustBeAShortTag() {
        XCTAssertTrue(HelperRequest.isValidReason("reassert"))
        XCTAssertTrue(HelperRequest.isValidReason("helper-change_2"))
        for bad in ["", "Arm", "arm now", "; rm -rf /", "-a", "a/b", "ärm", String(repeating: "a", count: 33), "arm\n"] {
            XCTAssertFalse(HelperRequest.isValidReason(bad), bad)
            XCTAssertEqual(HelperRequest.validateHold(leaseSeconds: 60, reason: bad), .failure(.invalidReason), bad)
        }
    }

    func testReleaseIsNeverRefusedButABadReasonIsReplaced() {
        XCTAssertEqual(HelperRequest.validateRelease(reason: "quit"), .release(reason: "quit"))
        XCTAssertEqual(HelperRequest.validateRelease(reason: "$(reboot)"), .release(reason: HelperRequest.fallbackReason))
    }

    func testOnlyReleaseSkipsTheRateLimit() {
        XCTAssertTrue(HelperRequest.hold(leaseSeconds: 60, reason: "arm").isRateLimited)
        XCTAssertTrue(HelperRequest.heartbeat.isRateLimited)
        XCTAssertTrue(HelperRequest.status.isRateLimited)
        XCTAssertFalse(HelperRequest.release(reason: "quit").isRateLimited)
    }
}

// MARK: - Rate limiter

final class RateLimiterTests: XCTestCase {
    func testTenCallsPerMinute() {
        var limiter = RateLimiter.helperDefault
        for i in 0..<10 { XCTAssertTrue(limiter.allow(now: 100 + Double(i)), "call \(i)") }
        XCTAssertFalse(limiter.allow(now: 110))
        XCTAssertFalse(limiter.allow(now: 159))
        // The first call (at 100) leaves the window at 160.
        XCTAssertTrue(limiter.allow(now: 160))
        XCTAssertFalse(limiter.allow(now: 160.5))
    }

    func testHeartbeatEveryTenSecondsPlusAHoldFits() {
        var limiter = RateLimiter.helperDefault
        XCTAssertTrue(limiter.allow(now: 0))
        for t in stride(from: 0.0, through: 600, by: 10) { XCTAssertTrue(limiter.allow(now: t + 0.5), "t \(t)") }
    }

    func testRefusedCallsDoNotCount() {
        var limiter = RateLimiter(limit: 2, window: 60)
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 1))
        for t in 2..<50 { XCTAssertFalse(limiter.allow(now: Double(t))) }
        XCTAssertTrue(limiter.allow(now: 60))
    }

    func testClockGoingBackDoesNotLockOut() {
        var limiter = RateLimiter(limit: 2, window: 60)
        XCTAssertTrue(limiter.allow(now: 1000))
        XCTAssertTrue(limiter.allow(now: 1001))
        XCTAssertTrue(limiter.allow(now: 10))
    }
}

// MARK: - Startup decisions

final class HelperStartupTests: XCTestCase {
    let boot = "BOOT-A"

    func stored(_ lease: Lease?, leaseSeconds: Int = 60) -> Data {
        HelperState(lease: lease, leaseSeconds: leaseSeconds).encoded()
    }

    func testNoStateReleases() {
        XCTAssertEqual(HelperStartup.decide(stored: nil, now: t0, bootSession: boot), .release(reason: "start-no-state", keep: HelperState()))
    }

    func testUnreadableStateReleases() {
        for junk in ["", "{", "[]", "{\"lease\": 5}", "null"] {
            guard case .release(let reason, _) = HelperStartup.decide(stored: Data(junk.utf8), now: t0, bootSession: boot) else {
                return XCTFail(junk)
            }
            XCTAssertEqual(reason, "start-bad-state")
        }
    }

    func testValidLeaseResumes() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        XCTAssertEqual(HelperStartup.decide(stored: stored(lease), now: t0.addingTimeInterval(30), bootSession: boot),
                       .resume(HelperState(lease: lease, leaseSeconds: 60)))
    }

    func testOtherBootReleases() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        guard case .release(let reason, let keep) = HelperStartup.decide(stored: stored(lease), now: t0.addingTimeInterval(5), bootSession: "BOOT-B") else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "start-new-boot")
        XCTAssertNil(keep.lease)
    }

    func testExpiredLeaseReleases() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        guard case .release(let reason, _) = HelperStartup.decide(stored: stored(lease), now: t0.addingTimeInterval(61), bootSession: boot) else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "start-lease-expired")
    }

    func testClockBackwardsReleases() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        guard case .release(let reason, _) = HelperStartup.decide(stored: stored(lease), now: t0.addingTimeInterval(-600), bootSession: boot) else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "start-clock-backwards")
    }

    func testUnknownBootSessionReleases() {
        let lease = Lease.grant(now: t0, bootSession: boot, seconds: 60)
        guard case .release(let reason, _) = HelperStartup.decide(stored: stored(lease), now: t0, bootSession: nil) else {
            return XCTFail()
        }
        XCTAssertEqual(reason, "start-no-boot-session")
    }

    func testCeilingBlockSurvivesARestartButNotAReboot() {
        let until = t0.addingTimeInterval(600)
        let data = HelperState(lease: nil, leaseSeconds: 60, holdsBlockedUntil: until, blockedBootSession: boot).encoded()
        guard case .release(_, let same) = HelperStartup.decide(stored: data, now: t0, bootSession: boot),
              case .release(_, let other) = HelperStartup.decide(stored: data, now: t0, bootSession: "BOOT-B") else {
            return XCTFail()
        }
        XCTAssertEqual(same.holdsBlockedUntil, until)
        XCTAssertNil(other.holdsBlockedUntil)
    }
}

// MARK: - Engine

final class HelperEngineTests: XCTestCase {
    func testStartWithoutStateRunsRelease() {
        let fx = FakeEffects()
        makeEngine(fx).start()
        XCTAssertEqual(fx.runs, [.disableSleepOff])
    }

    func testStartAfterRebootReleasesAndClearsTheLease() {
        let fx = FakeEffects()
        fx.stored = HelperState(lease: Lease.grant(now: t0, bootSession: "OLD", seconds: 60)).encoded()
        let engine = makeEngine(fx)
        engine.start()
        XCTAssertEqual(fx.runs, [.disableSleepOff])
        XCTAssertNil(HelperState.decode(fx.stored!)?.lease)
        XCTAssertFalse(engine.status().held)
    }

    func testStartWithValidLeaseKeepsHoldingWithoutRunningPmset() {
        let fx = FakeEffects()
        let clock = Clock(t0)
        fx.stored = HelperState(lease: Lease.grant(now: t0, bootSession: "BOOT-A", seconds: 60)).encoded()
        clock.advance(20)
        let engine = makeEngine(fx, clock: clock)
        engine.start()
        XCTAssertEqual(fx.runs, [])
        XCTAssertEqual(engine.status().leaseRemaining, 40)
    }

    func testHoldRunsOnAndStoresTheLease() {
        let fx = FakeEffects()
        let engine = makeEngine(fx)
        XCTAssertNil(engine.hold(leaseSeconds: 60, reason: "rules"))
        XCTAssertEqual(fx.runs, [.disableSleepOn])
        let state = HelperState.decode(fx.stored!)
        XCTAssertEqual(state?.lease?.expiresAt, t0.addingTimeInterval(60))
        XCTAssertEqual(state?.lease?.bootSession, "BOOT-A")
        XCTAssertTrue(engine.status().held)
        XCTAssertEqual(engine.status().sleepDisabled, true)
        XCTAssertTrue(fx.logs.contains("/usr/bin/pmset -a disablesleep 1 exit=0 reason=rules"))
    }

    func testHeartbeatExtendsAndMissedHeartbeatsRelease() {
        let fx = FakeEffects()
        let clock = Clock(t0)
        let engine = makeEngine(fx, clock: clock)
        _ = engine.hold(leaseSeconds: 60, reason: "rules")
        for _ in 0..<10 {
            clock.advance(10)
            XCTAssertNil(engine.heartbeat())
            engine.tick()
        }
        XCTAssertEqual(fx.runs, [.disableSleepOn])
        // The app dies: no more heartbeats.
        clock.advance(59)
        engine.tick()
        XCTAssertEqual(fx.runs, [.disableSleepOn])
        clock.advance(1)
        engine.tick()
        XCTAssertEqual(fx.runs, [.disableSleepOn, .disableSleepOff])
        XCTAssertFalse(engine.status().held)
        XCTAssertNotNil(engine.heartbeat())
    }

    func testHeartbeatWithoutHoldIsRefused() {
        let fx = FakeEffects()
        XCTAssertEqual(makeEngine(fx).heartbeat(), "no active hold")
        XCTAssertEqual(fx.runs, [])
    }

    func testHoldAgainDoesNotResetTheCeiling() {
        let fx = FakeEffects()
        let clock = Clock(t0)
        let engine = makeEngine(fx, clock: clock)
        _ = engine.hold(leaseSeconds: 120, reason: "rules")
        for _ in 0..<(12 * 60) {
            clock.advance(60)
            _ = engine.hold(leaseSeconds: 120, reason: "reassert")
        }
        // Twelve hours of holds, then one release and holds blocked.
        XCTAssertNil(engine.state.lease)
        XCTAssertEqual(fx.runs.last, .disableSleepOff)
        XCTAssertEqual(fx.runs.filter { $0 == .disableSleepOff }.count, 1)
        XCTAssertNotNil(engine.status().holdsBlockedUntil)
    }

    func testCeilingReleasesAndBlocksHoldsForTheCooldown() {
        let fx = FakeEffects()
        let clock = Clock(t0)
        let engine = makeEngine(fx, clock: clock)
        _ = engine.hold(leaseSeconds: 60, reason: "rules")
        while engine.state.lease != nil {
            clock.advance(10)
            _ = engine.heartbeat()
        }
        XCTAssertEqual(fx.runs.last, .disableSleepOff)
        XCTAssertLessThanOrEqual(clock.now.timeIntervalSince(t0), 12 * 3600 + 10)
        let runsBefore = fx.runs.count
        XCTAssertNotNil(engine.hold(leaseSeconds: 60, reason: "rules"))
        XCTAssertEqual(fx.runs.count, runsBefore, "a blocked hold runs nothing")
        clock.advance(HelperEngine.ceilingCooldown)
        engine.tick()
        XCTAssertNil(engine.hold(leaseSeconds: 60, reason: "rules"))
    }

    func testReleaseAlwaysRunsOffAndClearsTheLease() {
        let fx = FakeEffects()
        let engine = makeEngine(fx)
        XCTAssertNil(engine.release(reason: "leftover"))
        _ = engine.hold(leaseSeconds: 60, reason: "rules")
        XCTAssertNil(engine.release(reason: "disarm"))
        XCTAssertEqual(fx.runs, [.disableSleepOff, .disableSleepOn, .disableSleepOff])
        XCTAssertNil(HelperState.decode(fx.stored!)?.lease)
    }

    func testFailedReleaseIsRetriedOnTick() {
        let fx = FakeEffects()
        let engine = makeEngine(fx)
        _ = engine.hold(leaseSeconds: 60, reason: "rules")
        fx.exitCodes[.disableSleepOff] = 1
        XCTAssertNotNil(engine.release(reason: "disarm"))
        XCTAssertTrue(engine.releasePending)
        engine.tick()
        XCTAssertEqual(fx.runs.filter { $0 == .disableSleepOff }.count, 2)
        fx.exitCodes[.disableSleepOff] = 0
        engine.tick()
        XCTAssertFalse(engine.releasePending)
        engine.tick()
        XCTAssertEqual(fx.runs.filter { $0 == .disableSleepOff }.count, 3)
    }

    func testFailedHoldStoresNoLeaseAndReleases() {
        let fx = FakeEffects()
        fx.exitCodes[.disableSleepOn] = .some(nil)
        let engine = makeEngine(fx)
        XCTAssertNotNil(engine.hold(leaseSeconds: 60, reason: "rules"))
        XCTAssertNil(engine.state.lease)
        XCTAssertEqual(fx.runs, [.disableSleepOn, .disableSleepOff])
        XCTAssertNotNil(engine.status().lastError)
    }

    func testNoBootSessionRefusesHold() {
        let fx = FakeEffects()
        let engine = makeEngine(fx, boot: nil)
        XCTAssertNotNil(engine.hold(leaseSeconds: 60, reason: "rules"))
        XCTAssertEqual(fx.runs, [])
    }

    func testShutdownReleasesOnlyWhenHolding() {
        let fx = FakeEffects()
        let engine = makeEngine(fx)
        engine.shutdown()
        XCTAssertEqual(fx.runs, [])
        _ = engine.hold(leaseSeconds: 60, reason: "rules")
        engine.shutdown()
        XCTAssertEqual(fx.runs, [.disableSleepOn, .disableSleepOff])
    }

    func testStateFileFailureStillHoldsAndReportsIt() {
        let fx = FakeEffects()
        fx.saveFails = true
        let engine = makeEngine(fx)
        XCTAssertNil(engine.hold(leaseSeconds: 60, reason: "rules"))
        XCTAssertTrue(engine.status().held)
        XCTAssertNotNil(engine.lastError)
    }

    func testStatusRoundTripsAndRejectsJunk() {
        let status = makeEngine().status()
        XCTAssertEqual(HelperStatus.decode(status.encoded()), status)
        XCTAssertNil(HelperStatus.decode(Data()))
        XCTAssertNil(HelperStatus.decode(Data("{\"held\":\"yes\"}".utf8)))
        XCTAssertNil(HelperStatus.decode(Data(repeating: 0x20, count: 20_000)))
    }
}

// MARK: - Version check and identity

final class HelperVersionCheckTests: XCTestCase {
    func testSameVersionAndBinaryIsCurrent() {
        XCTAssertEqual(HelperVersionCheck.verdict(helperVersion: "1.4.0", helperCodeHash: "AB", appVersion: "1.4.0", bundledCodeHash: "ab"), .current)
    }

    func testOtherVersionIsReplaced() {
        XCTAssertEqual(HelperVersionCheck.verdict(helperVersion: "1.3.1", helperCodeHash: nil, appVersion: "1.4.0", bundledCodeHash: nil),
                       .replace("helper 1.3.1, app 1.4.0"))
    }

    func testSameVersionOtherBinaryIsReplaced() {
        guard case .replace = HelperVersionCheck.verdict(helperVersion: "1.4.0", helperCodeHash: "aa", appVersion: "1.4.0", bundledCodeHash: "bb") else {
            return XCTFail()
        }
    }

    func testNoAnswerIsUnknownNotAReinstallLoop() {
        XCTAssertEqual(HelperVersionCheck.verdict(helperVersion: nil, helperCodeHash: nil, appVersion: "1.4.0", bundledCodeHash: "aa"), .unknown)
    }

    func testMissingHashesFallBackToTheVersion() {
        XCTAssertEqual(HelperVersionCheck.verdict(helperVersion: "1.4.0", helperCodeHash: nil, appVersion: "1.4.0", bundledCodeHash: "aa"), .current)
    }
}

final class HelperIdentityTests: XCTestCase {
    func testReleaseRequirementsPinIdentifierAppleAnchorAndTeam() {
        XCTAssertEqual(HelperIdentity.clientRequirement(relaxed: false),
                       "identifier \"com.weteling.stayawake\" and anchor apple generic and certificate leaf[subject.OU] = \"ND82KXRD2Q\"")
        XCTAssertEqual(HelperIdentity.helperRequirement(relaxed: false),
                       "identifier \"com.weteling.stayawake.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"ND82KXRD2Q\"")
    }

    func testRelaxedRequirementIsIdentifierOnly() {
        XCTAssertEqual(HelperIdentity.clientRequirement(relaxed: true), "identifier \"com.weteling.stayawake\"")
    }

    func testRequirementsCompile() {
        for relaxed in [false, true] {
            for text in [HelperIdentity.clientRequirement(relaxed: relaxed), HelperIdentity.helperRequirement(relaxed: relaxed)] {
                var req: SecRequirement?
                XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &req), errSecSuccess, text)
            }
        }
    }

    func testLaunchdPlistMatchesTheIdentity() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StayAwakeHelper/Resources/\(HelperIdentity.plistName)")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperIdentity.helperIdentifier)
        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/MacOS/StayAwakeHelper")
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [HelperIdentity.appIdentifier])
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[HelperIdentity.machServiceName], true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertNil(plist["Program"], "BundleProgram only, so the path stays inside the app bundle")
        XCTAssertNil(plist["ProgramArguments"])
    }
}

// MARK: - Over real XPC (anonymous listener, same process)

final class HelperXPCTests: XCTestCase {
    final class Delegate: NSObject, NSXPCListenerDelegate {
        let engine: HelperEngine
        let queue = DispatchQueue(label: "test.helper")
        init(engine: HelperEngine) { self.engine = engine }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            c.exportedInterface = .stayAwakeHelper()
            var t: TimeInterval = 0
            c.exportedObject = HelperConnectionHandler(engine: engine, queue: queue, clock: { t += 1; return t })
            c.resume()
            return true
        }
    }

    var fx: FakeEffects!
    var listener: NSXPCListener!
    var delegate: Delegate!
    var connection: NSXPCConnection!

    override func setUp() {
        fx = FakeEffects()
        delegate = Delegate(engine: makeEngine(fx))
        listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = .stayAwakeHelper()
        connection.resume()
    }

    override func tearDown() {
        connection.invalidate()
        listener.invalidate()
    }

    private var proxy: HelperXPC {
        connection.remoteObjectProxyWithErrorHandler { XCTFail("xpc error \($0)") } as! HelperXPC
    }

    private func hold(_ seconds: Int, _ reason: String) -> String? {
        let done = expectation(description: "hold")
        var answer: String?
        proxy.hold(leaseSeconds: seconds, reason: reason) { answer = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return answer
    }

    func testInvalidInputIsRejectedAndRunsNothing() {
        XCTAssertNotNil(hold(3600, "arm"))
        XCTAssertNotNil(hold(-1, "arm"))
        XCTAssertNotNil(hold(60, "arm; reboot"))
        XCTAssertNotNil(hold(60, "-a disablesleep 1"))
        XCTAssertEqual(fx.runs, [])
    }

    func testValidHoldThenStatusThenRelease() {
        XCTAssertNil(hold(60, "arm"))
        XCTAssertEqual(fx.runs, [.disableSleepOn])

        let gotStatus = expectation(description: "status")
        var status: HelperStatus?
        proxy.status { status = HelperStatus.decode($0); gotStatus.fulfill() }
        wait(for: [gotStatus], timeout: 5)
        XCTAssertEqual(status?.held, true)
        XCTAssertEqual(status?.version, "1.4.0")

        let released = expectation(description: "release")
        proxy.release(reason: "not a valid tag!") { XCTAssertNil($0); released.fulfill() }
        wait(for: [released], timeout: 5)
        XCTAssertEqual(fx.runs, [.disableSleepOn, .disableSleepOff])
        XCTAssertTrue(fx.logs.contains { $0.hasSuffix("reason=unspecified") })
    }

    func testRateLimitPerConnectionButReleaseAlwaysWorks() {
        XCTAssertNil(hold(60, "arm"))
        var answers: [String?] = []
        for _ in 0..<10 {
            let done = expectation(description: "hb")
            proxy.heartbeat { answers.append($0); done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(answers.prefix(9).compactMap { $0 }, [])
        XCTAssertEqual(answers.last??.hasPrefix("rate limit"), true)

        let released = expectation(description: "release")
        proxy.release(reason: "disarm") { XCTAssertNil($0); released.fulfill() }
        wait(for: [released], timeout: 5)
        XCTAssertEqual(fx.runs.last, .disableSleepOff)
    }
}
