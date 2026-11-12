import Foundation

/// Validation of everything a client sends to the helper. The helper turns
/// input into one of these values or refuses it; nothing from a client ever
/// reaches an argv.
public enum HelperRequest: Equatable, Sendable {
    case hold(leaseSeconds: Int, reason: String)
    case heartbeat
    case release(reason: String)
    case status

    public static let maxReasonLength = 32
    public static let leaseRange = Int(Lease.minSecondsPerHeartbeat)...Int(Lease.maxSecondsPerHeartbeat)
    /// Used when a release arrives with a reason that does not validate.
    public static let fallbackReason = "unspecified"

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case leaseOutOfRange(Int)
        case invalidReason

        public var description: String {
            switch self {
            case .leaseOutOfRange(let s):
                return "lease of \(s) s refused, allowed is \(leaseRange.lowerBound) to \(leaseRange.upperBound) s"
            case .invalidReason:
                return "reason refused, use a lowercase tag of at most \(maxReasonLength) characters (a-z, 0-9, - or _)"
            }
        }
    }

    /// A reason is a short tag for the log, like "arm" or "reassert": a lowercase
    /// letter, then letters, digits, - or _.
    public static func isValidReason(_ reason: String) -> Bool {
        guard (1...maxReasonLength).contains(reason.utf8.count),
              let first = reason.utf8.first, first >= 0x61, first <= 0x7A else { return false }
        return reason.utf8.allSatisfy { c in
            (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
        }
    }

    public static func validateHold(leaseSeconds: Int, reason: String) -> Result<HelperRequest, Rejection> {
        guard leaseRange.contains(leaseSeconds) else { return .failure(.leaseOutOfRange(leaseSeconds)) }
        guard isValidReason(reason) else { return .failure(.invalidReason) }
        return .success(.hold(leaseSeconds: leaseSeconds, reason: reason))
    }

    /// Release is never refused, it only makes the Mac safer. A bad reason
    /// is replaced, not rejected.
    public static func validateRelease(reason: String) -> HelperRequest {
        .release(reason: isValidReason(reason) ? reason : fallbackReason)
    }

    /// Whether the call counts against the per connection rate limit.
    public var isRateLimited: Bool {
        if case .release = self { return false }
        return true
    }
}

/// At most `limit` calls in any `window` seconds. Pure; the caller passes the clock.
public struct RateLimiter: Equatable, Sendable {
    public static let helperDefault = RateLimiter(limit: 10, window: 60)

    public let limit: Int
    public let window: TimeInterval
    private var stamps: [TimeInterval] = []

    public init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Records the call and returns true when it is allowed. Refused calls are
    /// not recorded, so a client that backs off gets through again.
    public mutating func allow(now: TimeInterval) -> Bool {
        // Stamps from the future (clock went back) are dropped too.
        stamps.removeAll { $0 <= now - window || $0 > now }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

/// What the helper keeps in /var/db/stayawake/state.json.
public struct HelperState: Codable, Equatable, Sendable {
    public var lease: Lease?
    /// Length of one lease period, set by `hold`, used by `heartbeat`.
    public var leaseSeconds: Int
    /// After the 12 hour ceiling, holds are refused until this time (same boot only).
    public var holdsBlockedUntil: Date?
    public var blockedBootSession: String?

    public init(lease: Lease? = nil, leaseSeconds: Int = 60, holdsBlockedUntil: Date? = nil, blockedBootSession: String? = nil) {
        self.lease = lease
        self.leaseSeconds = leaseSeconds
        self.holdsBlockedUntil = holdsBlockedUntil
        self.blockedBootSession = blockedBootSession
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> HelperState? {
        guard data.count <= 65_536 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HelperState.self, from: data)
    }
}

/// What the helper does when it starts (at boot, after a crash, after an update).
public enum HelperStartup: Equatable, Sendable {
    /// Keep sleep disabled with this state; the lease timer takes over.
    case resume(HelperState)
    /// Run disablesleep 0 and store this state (no lease).
    case release(reason: String, keep: HelperState)

    public static func decide(stored: Data?, now: Date, bootSession: String?) -> HelperStartup {
        guard let stored else { return .release(reason: "start-no-state", keep: HelperState()) }
        guard let state = HelperState.decode(stored) else { return .release(reason: "start-bad-state", keep: HelperState()) }
        // A block from the ceiling outlives a helper restart, not a reboot.
        var keep = HelperState(leaseSeconds: state.leaseSeconds)
        if let until = state.holdsBlockedUntil, let boot = bootSession, state.blockedBootSession == boot, until > now {
            keep.holdsBlockedUntil = until
            keep.blockedBootSession = boot
        }
        guard let boot = bootSession else { return .release(reason: "start-no-boot-session", keep: keep) }
        guard let lease = state.lease else { return .release(reason: "start-no-lease", keep: keep) }
        switch lease.verdict(now: now, bootSession: boot) {
        case .valid:
            var resumed = keep
            resumed.lease = lease
            return .resume(resumed)
        case .bootSessionMismatch: return .release(reason: "start-new-boot", keep: HelperState(leaseSeconds: state.leaseSeconds))
        case .expired: return .release(reason: "start-lease-expired", keep: keep)
        case .ceilingReached: return .release(reason: "start-ceiling", keep: keep)
        case .clockWentBackwards: return .release(reason: "start-clock-backwards", keep: keep)
        case .noLease: return .release(reason: "start-no-lease", keep: keep)
        }
    }
}

/// Whether the running helper is the one in this app bundle.
public enum HelperVersionCheck {
    public enum Verdict: Equatable, Sendable {
        case current
        case replace(String)
        /// The helper did not answer; nothing to compare.
        case unknown
    }

    public static func verdict(helperVersion: String?, helperCodeHash: String?,
                               appVersion: String?, bundledCodeHash: String?) -> Verdict {
        guard let helperVersion else { return .unknown }
        if let appVersion, helperVersion != appVersion {
            return .replace("helper \(helperVersion), app \(appVersion)")
        }
        if let a = helperCodeHash?.lowercased(), let b = bundledCodeHash?.lowercased(), !a.isEmpty, !b.isEmpty, a != b {
            return .replace("helper binary differs from the one in this app")
        }
        return .current
    }
}
