import Foundation

/// What the app has to ask the backend for so that the system matches what
/// it wants. Pure: the app passes what it knows and carries out the answer.
public enum SleepReconcile {
    public enum Need: Equatable, Sendable {
        case nothing
        /// Armed and holding, but the system lets the Mac sleep (or the lease was lost).
        case hold
        /// Not holding, but sleep is still disabled and StayAwake owns that.
        case release
    }

    /// - Parameters:
    ///   - phase: the engine phase.
    ///   - sleepDisabled: SleepDisabled as `pmset -g` reads it; nil when unreadable.
    ///   - leaseLost: a heartbeat failed, so the helper may let the lease run out.
    ///   - releaseOwed: StayAwake asked for a hold since the last confirmed release.
    ///   - clearLeftover: the user lets StayAwake clear a SleepDisabled it did not set.
    public static func need(phase: Phase, sleepDisabled: Bool?, leaseLost: Bool,
                            releaseOwed: Bool, clearLeftover: Bool) -> Need {
        if phase == .holding {
            return sleepDisabled == false || leaseLost ? .hold : .nothing
        }
        // Safety first: never leave a Mac that should sleep with sleep off.
        if sleepDisabled == true, releaseOwed || clearLeftover { return .release }
        return .nothing
    }
}

/// Backoff and escalation while the backend (the helper) keeps failing.
/// Times are monotonic seconds. Pure value; the app owns the clock.
public struct HelperRetry: Equatable, Sendable {
    /// Waits after the 1st, 2nd and 3rd failure; then `steadyDelay` for as long as it takes.
    public static let delays: [TimeInterval] = [1, 2, 5]
    public static let steadyDelay: TimeInterval = 15
    /// After this many failures in a row, unregister and register the helper.
    public static let reregisterAfterFailures = 4
    /// At most one re-registration per this many seconds.
    public static let reregisterCooldown: TimeInterval = 10 * 60
    /// An armed Mac that could not be held for this long stops with a clear reason.
    public static let giveUpHoldingAfter: TimeInterval = 5 * 60

    public private(set) var failures = 0
    public private(set) var troubleSince: TimeInterval?
    public private(set) var lastError: String?
    public private(set) var nextAttempt: TimeInterval?
    public private(set) var lastReregister: TimeInterval?

    public init() {}

    public var inTrouble: Bool { failures > 0 }

    public static func delay(afterFailures n: Int) -> TimeInterval {
        guard n > 0 else { return 0 }
        return n <= delays.count ? delays[n - 1] : steadyDelay
    }

    public mutating func failed(_ error: String, now: TimeInterval) {
        failures += 1
        troubleSince = troubleSince ?? now
        lastError = error
        nextAttempt = now + Self.delay(afterFailures: failures)
    }

    /// A call worked, or the system already is where the app wants it.
    public mutating func succeeded() {
        failures = 0
        troubleSince = nil
        lastError = nil
        nextAttempt = nil
    }

    public func mayAttempt(now: TimeInterval) -> Bool {
        nextAttempt.map { now >= $0 } ?? true
    }

    /// Seconds until the next attempt is due, nil when nothing is pending.
    public func wait(now: TimeInterval) -> TimeInterval? {
        nextAttempt.map { max(0, $0 - now) }
    }

    public func shouldReregister(now: TimeInterval) -> Bool {
        guard failures >= Self.reregisterAfterFailures else { return false }
        return lastReregister.map { now - $0 >= Self.reregisterCooldown } ?? true
    }

    public mutating func didReregister(now: TimeInterval) {
        lastReregister = now
    }

    public func shouldGiveUpHolding(now: TimeInterval) -> Bool {
        troubleSince.map { now - $0 >= Self.giveUpHoldingAfter } ?? false
    }
}
