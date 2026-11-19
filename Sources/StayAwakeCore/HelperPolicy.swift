import Foundation

/// Validation of everything a client sends to the helper. The helper turns
/// input into one of these values or refuses it; nothing from a client ever
/// reaches an argv.
public enum HelperRequest: Equatable, Sendable {
    case hold(leaseSeconds: Int, reason: String)
    case heartbeat
    case release(reason: String)
    case status
    case restartForUpdate

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
    // State files written before 1.6.2 also carry holdsBlockedUntil and
    // blockedBootSession from the removed 12 hour ceiling. Decoding ignores them.

    public init(lease: Lease? = nil, leaseSeconds: Int = 60) {
        self.lease = lease
        self.leaseSeconds = leaseSeconds
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
        let keep = HelperState(leaseSeconds: state.leaseSeconds)
        guard let boot = bootSession else { return .release(reason: "start-no-boot-session", keep: keep) }
        guard let lease = state.lease else { return .release(reason: "start-no-lease", keep: keep) }
        switch lease.verdict(now: now, bootSession: boot) {
        case .valid:
            var resumed = keep
            resumed.lease = lease
            return .resume(resumed)
        case .bootSessionMismatch: return .release(reason: "start-new-boot", keep: keep)
        case .expired: return .release(reason: "start-lease-expired", keep: keep)
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

/// SMAppService status, without the ServiceManagement import.
public enum HelperRegistration: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    /// Also seen before the very first registration.
    case notFound
}

/// What the app does to get the helper from this bundle running, or working
/// again. Unregistering throws away the user's approval in Login Items (the
/// next register ends in "Operation not permitted" and requiresApproval), so
/// it is only ever the last resort for a registration macOS cannot find.
///
/// macOS on an app update: the daemon plist points at BundleProgram inside
/// the bundle, so launchd keeps running the old process (its inode is
/// still open) until it exits, and then starts whatever binary is at that
/// path. The helper keeps the same identifier and team, so it still meets
/// the launch constraint launchd recorded at registration.
public enum HelperRepair {
    public enum Step: Equatable, Sendable {
        case nothing
        /// Ask the running helper to release and exit; launchd starts the new one.
        case restartHelper
        /// An older helper that cannot restart itself. It keeps working and is
        /// replaced at the next restart of the Mac. Never unregister for this.
        case keepUntilReboot(String)
        /// register() only. Keeps an approval that already exists.
        case register
        /// Unregister, then register. Needs the approval again afterwards.
        case reinstall
        /// Waiting for the user in System Settings, Login Items.
        case awaitApproval
    }

    /// Launch check: the running helper against this bundle.
    public static func forVersion(_ verdict: HelperVersionCheck.Verdict, registration: HelperRegistration,
                                  helperCanRestart: Bool) -> Step {
        switch registration {
        case .requiresApproval: return .awaitApproval
        case .notRegistered: return .register
        case .notFound: return .reinstall
        case .enabled:
            guard case .replace(let why) = verdict else { return .nothing }
            return helperCanRestart ? .restartHelper : .keepUntilReboot(why)
        }
    }

    /// Calls to the helper keep failing (`HelperRetry.shouldReregister`).
    /// `helperStatus` is nil when the helper does not answer at all.
    public static func forFailures(registration: HelperRegistration, helperStatus: HelperStatus?) -> Step {
        switch registration {
        case .requiresApproval: return .awaitApproval
        case .notRegistered: return .register
        case .notFound: return .reinstall
        case .enabled:
            guard let status = helperStatus else {
                // Registered and approved but silent: register again without
                // unregistering, so launchd loads the job if it went missing.
                return .register
            }
            return status.canRestart == true ? .restartHelper : .nothing
        }
    }
}

/// Which calls the app may send to a helper whose code signature it cannot
/// check.
///
/// The updater swaps the app bundle in place and deletes the old one, but
/// launchd keeps the old helper process running until it exits. From then on
/// macOS cannot read that process's code from disk, so the app's code signing
/// requirement on the XPC connection fails for every call
/// (NSXPCConnectionCodeSigningRequirementFailure, "Couldn't communicate with a
/// helper application"). Only the helper can end that state, so the app has
/// to reach it.
///
/// The mach service lives in the system domain and only launchd, from our
/// registered job, can publish it. The helper still checks the app's
/// signature on its side. So the app may send calls that can only make the
/// Mac safer or swap in the new helper: release, status and restartForUpdate.
/// Hold and heartbeat, which keep sleep disabled, stay verified only.
public enum HelperTrust {
    public static func mayCallUnverified(_ request: HelperRequest) -> Bool {
        switch request {
        case .release, .status, .restartForUpdate: return true
        case .hold, .heartbeat: return false
        }
    }
}
