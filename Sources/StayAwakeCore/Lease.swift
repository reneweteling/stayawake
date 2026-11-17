import Foundation

public enum LeaseVerdict: Equatable, Sendable {
    case valid(remaining: TimeInterval)
    case expired
    case bootSessionMismatch
    case clockWentBackwards
    case noLease

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

/// The helper's promise to keep sleep disabled: it lasts a short while and
/// must be renewed by heartbeat. There is no total limit: a hold lasts as
/// long as the app keeps renewing it. How long that is, is the app's call
/// (its rules and time cap). Pure value logic; the helper stores it in its
/// state file and owns the real clock and boot session id.
public struct Lease: Codable, Equatable, Sendable {
    public static let maxSecondsPerHeartbeat: TimeInterval = 120
    public static let minSecondsPerHeartbeat: TimeInterval = 1
    /// Wall clock readings may drift this much backwards before it counts as a jump.
    public static let clockTolerance: TimeInterval = 2

    public var bootSession: String
    public var startedAt: Date
    public var expiresAt: Date
    /// The latest wall clock reading seen while the lease was valid.
    public var lastSeen: Date

    static func clampSeconds(_ s: TimeInterval) -> TimeInterval {
        min(max(s, minSecondsPerHeartbeat), maxSecondsPerHeartbeat)
    }

    /// `hold(leaseSeconds)`
    public static func grant(now: Date, bootSession: String, seconds: TimeInterval) -> Lease {
        Lease(bootSession: bootSession, startedAt: now,
              expiresAt: now.addingTimeInterval(clampSeconds(seconds)), lastSeen: now)
    }

    public func verdict(now: Date, bootSession current: String) -> LeaseVerdict {
        if bootSession != current { return .bootSessionMismatch }
        if now < lastSeen.addingTimeInterval(-Lease.clockTolerance) || now < startedAt { return .clockWentBackwards }
        if now >= expiresAt { return .expired }
        return .valid(remaining: expiresAt.timeIntervalSince(now))
    }

    /// `heartbeat()`: extends to now plus the lease length. Returns nil when
    /// the lease is no longer valid; the helper then releases instead.
    public func heartbeat(now: Date, bootSession current: String, seconds: TimeInterval) -> Lease? {
        guard verdict(now: now, bootSession: current).isValid else { return nil }
        var next = self
        next.expiresAt = now.addingTimeInterval(Lease.clampSeconds(seconds))
        next.lastSeen = max(lastSeen, now)
        return next
    }

    /// Whether the helper should still hold sleep off. `nil` lease means none stored.
    public static func shouldHold(_ lease: Lease?, now: Date, bootSession: String) -> Bool {
        lease?.verdict(now: now, bootSession: bootSession).isValid ?? false
    }
}
