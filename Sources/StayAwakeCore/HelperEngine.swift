import Foundation

/// Everything the helper does to the outside world. The helper executable
/// implements it with posix_spawn, the state file and os_log; tests use a fake.
public protocol HelperEffects: AnyObject {
    /// Runs the fixed argv of `command`. Returns the exit status, nil when it could not start.
    func run(_ command: PmsetCommand) -> Int32?
    /// SleepDisabled as the system reports it. Nil when it cannot be read.
    func readSleepDisabled() -> Bool?
    func loadState() -> Data?
    func saveState(_ data: Data) throws
    func log(_ message: String, isError: Bool)
}

/// The helper's lease logic. Not thread safe: the helper calls it from one
/// serial queue only.
public final class HelperEngine {
    /// After the 12 hour ceiling ends a hold, new holds are refused this long,
    /// so the Mac really gets to sleep before the app can ask again.
    public static let ceilingCooldown: TimeInterval = 15 * 60

    private let effects: HelperEffects
    private let now: () -> Date
    private let bootSession: () -> String?
    public let version: String
    public let codeHash: String?

    public private(set) var state = HelperState()
    public private(set) var lastError: String?
    /// A release failed; `tick` retries until it works.
    public private(set) var releasePending = false

    public init(effects: HelperEffects, version: String, codeHash: String?,
                now: @escaping () -> Date = Date.init, bootSession: @escaping () -> String?) {
        self.effects = effects
        self.version = version
        self.codeHash = codeHash
        self.now = now
        self.bootSession = bootSession
    }

    // MARK: - Lifecycle

    /// On start (boot, crash, update): keep a valid lease, release anything else.
    public func start() {
        switch HelperStartup.decide(stored: effects.loadState(), now: now(), bootSession: bootSession()) {
        case .resume(let resumed):
            state = resumed
            let left = resumed.lease.map { Int($0.expiresAt.timeIntervalSince(now())) } ?? 0
            effects.log("start: valid lease resumed, \(left) s left", isError: false)
        case .release(let reason, let keep):
            state = keep
            _ = release(reason: reason)
        }
    }

    /// Runs every few seconds: ends a lease that is no longer valid and
    /// retries a failed release.
    public func tick() {
        if let lease = state.lease {
            guard let boot = bootSession() else {
                _ = release(reason: "lease-no-boot-session")
                return
            }
            let verdict = lease.verdict(now: now(), bootSession: boot)
            if !verdict.isValid { end(verdict) }
        } else if releasePending {
            _ = release(reason: "release-retry")
        }
        if let until = state.holdsBlockedUntil, now() >= until {
            state.holdsBlockedUntil = nil
            state.blockedBootSession = nil
            persist()
        }
    }

    /// SIGTERM (unregister, shutdown, `kill`): never leave sleep disabled behind.
    public func shutdown() {
        if state.lease != nil || releasePending { _ = release(reason: "helper-stopping") }
    }

    // MARK: - Calls (already validated by HelperRequest)

    public func hold(leaseSeconds: Int, reason: String) -> String? {
        guard let boot = bootSession() else { return fail("no boot session id, hold refused") }
        let t = now()
        if let until = state.holdsBlockedUntil, state.blockedBootSession == boot, t < until {
            return fail("12 hour ceiling reached, holds refused until \(ISO8601DateFormatter().string(from: until))")
        }
        let seconds = TimeInterval(leaseSeconds)
        var next: Lease
        if let current = state.lease {
            let verdict = current.verdict(now: t, bootSession: boot)
            if verdict == .ceilingReached {
                end(verdict)
                return fail("12 hour ceiling reached, hold refused")
            }
            // A hold during a valid lease extends it and keeps its start, so
            // calling hold again never resets the 12 hour ceiling.
            next = current.heartbeat(now: t, bootSession: boot, seconds: seconds)
                ?? Lease.grant(now: t, bootSession: boot, seconds: seconds)
        } else {
            next = Lease.grant(now: t, bootSession: boot, seconds: seconds)
        }
        let hadValidLease = state.lease?.verdict(now: t, bootSession: boot).isValid ?? false
        guard runLogged(.disableSleepOn, reason: reason) == 0 else {
            // Unknown what the system state is now. With no valid lease to
            // expire later, set it back to normal sleep right away.
            if !hadValidLease { _ = release(reason: "hold-failed") }
            return fail("pmset -a disablesleep 1 failed")
        }
        state.lease = next
        state.leaseSeconds = leaseSeconds
        releasePending = false
        lastError = nil
        persist()
        return nil
    }

    public func heartbeat() -> String? {
        guard let lease = state.lease else { return "no active hold" }
        guard let boot = bootSession() else {
            _ = release(reason: "lease-no-boot-session")
            return "no boot session id, hold ended"
        }
        let t = now()
        guard let next = lease.heartbeat(now: t, bootSession: boot, seconds: TimeInterval(state.leaseSeconds)) else {
            let verdict = lease.verdict(now: t, bootSession: boot)
            end(verdict)
            return "hold ended: \(Self.describe(verdict))"
        }
        state.lease = next
        persist()
        return nil
    }

    /// Always runs disablesleep 0, even without a lease: the app also uses
    /// it to clear a leftover setting.
    public func release(reason: String) -> String? {
        let code = runLogged(.disableSleepOff, reason: reason)
        state.lease = nil
        persist()
        guard code == 0 else {
            releasePending = true
            return fail("pmset -a disablesleep 0 failed, retrying")
        }
        releasePending = false
        return nil
    }

    public func status() -> HelperStatus {
        let t = now()
        var remaining: TimeInterval?
        var held = false
        if let lease = state.lease, let boot = bootSession(), case .valid(let left) = lease.verdict(now: t, bootSession: boot) {
            held = true
            remaining = left
        }
        let blocked = state.holdsBlockedUntil.flatMap { $0 > t ? $0 : nil }
        return HelperStatus(held: held, leaseRemaining: remaining, sleepDisabled: effects.readSleepDisabled(),
                            version: version, codeHash: codeHash, lastError: lastError, holdsBlockedUntil: blocked)
    }

    /// For refused input, so it shows up in the log as well.
    public func noteRejected(_ what: String) {
        effects.log("refused: \(what)", isError: true)
    }

    // MARK: - Internals

    private func end(_ verdict: LeaseVerdict) {
        if verdict == .ceilingReached, let boot = bootSession() {
            state.holdsBlockedUntil = now().addingTimeInterval(Self.ceilingCooldown)
            state.blockedBootSession = boot
        }
        _ = release(reason: "lease-\(Self.describe(verdict))")
    }

    private func runLogged(_ command: PmsetCommand, reason: String) -> Int32? {
        let code = effects.run(command)
        let line = "\(command.argv.joined(separator: " ")) exit=\(code.map(String.init) ?? "spawn-failed") reason=\(reason)"
        effects.log(line, isError: code != 0)
        return code
    }

    private func persist() {
        do {
            try effects.saveState(state.encoded())
        } catch {
            // Without the file a restart releases, which is the safe side.
            lastError = "could not store state: \(error)"
            effects.log(lastError!, isError: true)
        }
    }

    private func fail(_ text: String) -> String {
        lastError = text
        effects.log(text, isError: true)
        return text
    }

    static func describe(_ verdict: LeaseVerdict) -> String {
        switch verdict {
        case .valid: return "valid"
        case .expired: return "expired"
        case .bootSessionMismatch: return "new-boot"
        case .ceilingReached: return "ceiling"
        case .clockWentBackwards: return "clock-backwards"
        case .noLease: return "no-lease"
        }
    }
}

/// The object exported to one XPC connection. Owns that connection's rate
/// limiter and hands validated requests to the shared engine on its queue.
public final class HelperConnectionHandler: NSObject, HelperXPC {
    private let engine: HelperEngine
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private var limiter: RateLimiter

    public init(engine: HelperEngine, queue: DispatchQueue, limiter: RateLimiter = .helperDefault,
                clock: @escaping () -> TimeInterval) {
        self.engine = engine
        self.queue = queue
        self.limiter = limiter
        self.clock = clock
    }

    /// Nil when the call may go ahead. Runs on `queue`.
    private func admit(_ request: HelperRequest) -> String? {
        guard request.isRateLimited, !limiter.allow(now: clock()) else { return nil }
        engine.noteRejected("rate limit")
        return "rate limit reached, at most \(limiter.limit) calls per minute"
    }

    public func hold(leaseSeconds: Int, reason: String, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            if let refused = admit(.hold(leaseSeconds: leaseSeconds, reason: reason)) { return reply(refused) }
            switch HelperRequest.validateHold(leaseSeconds: leaseSeconds, reason: reason) {
            case .failure(let rejection):
                engine.noteRejected("hold: \(rejection)")
                reply(rejection.description)
            case .success:
                reply(engine.hold(leaseSeconds: leaseSeconds, reason: reason))
            }
        }
    }

    public func heartbeat(reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            if let refused = admit(.heartbeat) { return reply(refused) }
            reply(engine.heartbeat())
        }
    }

    public func release(reason: String, reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            guard case .release(let clean) = HelperRequest.validateRelease(reason: reason) else { return reply("internal error") }
            reply(engine.release(reason: clean))
        }
    }

    public func status(reply: @escaping (Data) -> Void) {
        queue.async { [self] in
            if admit(.status) != nil { return reply(Data()) }
            reply(engine.status().encoded())
        }
    }
}
