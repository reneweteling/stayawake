import Foundation

/// Names and code signing requirements shared by the app and the helper.
public enum HelperIdentity {
    public static let teamID = "ND82KXRD2Q"
    public static let appIdentifier = "com.weteling.stayawake"
    public static let helperIdentifier = "com.weteling.stayawake.helper"
    public static let machServiceName = "com.weteling.stayawake.helper"
    public static let plistName = "com.weteling.stayawake.helper.plist"
    public static let stateDirectory = "/var/db/stayawake"
    public static let statePath = "/var/db/stayawake/state.json"

    /// What the helper demands from a connecting client. `relaxed` drops the
    /// team check so ad-hoc debug builds can talk to each other; only debug
    /// builds pass true.
    public static func clientRequirement(relaxed: Bool) -> String {
        requirement(identifier: appIdentifier, relaxed: relaxed)
    }

    /// What the app demands from the helper it connects to.
    public static func helperRequirement(relaxed: Bool) -> String {
        requirement(identifier: helperIdentifier, relaxed: relaxed)
    }

    public static func requirement(identifier: String, relaxed: Bool) -> String {
        if relaxed { return "identifier \"\(identifier)\"" }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}

/// The XPC interface. Arguments are plain integers and short strings; the
/// helper validates every one of them (`HelperRequest`). A reply string of
/// nil means success, anything else is the reason it was refused or failed.
@objc(StayAwakeHelperXPC)
public protocol HelperXPC {
    /// Disable sleep and start (or extend) the lease.
    func hold(leaseSeconds: Int, reason: String, reply: @escaping (String?) -> Void)
    /// Extend the lease by its length. Fails when there is no valid lease.
    func heartbeat(reply: @escaping (String?) -> Void)
    /// Enable sleep and clear the lease. Never rate limited.
    func release(reason: String, reply: @escaping (String?) -> Void)
    /// JSON encoded `HelperStatus`.
    func status(reply: @escaping (Data) -> Void)
}

public extension NSXPCInterface {
    static func stayAwakeHelper() -> NSXPCInterface { NSXPCInterface(with: HelperXPC.self) }
}

/// What `status()` returns.
public struct HelperStatus: Codable, Equatable, Sendable {
    /// The helper has a valid lease.
    public var held: Bool
    public var leaseRemaining: TimeInterval?
    /// Read from the system (`pmset -g`), not from the helper's memory.
    public var sleepDisabled: Bool?
    /// The app version of the bundle the helper was started from.
    public var version: String
    /// The helper's own code directory hash, read at startup.
    public var codeHash: String?
    public var lastError: String?
    /// Set while holds are refused after the 12 hour ceiling.
    public var holdsBlockedUntil: Date?

    public init(held: Bool, leaseRemaining: TimeInterval?, sleepDisabled: Bool?, version: String,
                codeHash: String?, lastError: String?, holdsBlockedUntil: Date? = nil) {
        self.held = held
        self.leaseRemaining = leaseRemaining
        self.sleepDisabled = sleepDisabled
        self.version = version
        self.codeHash = codeHash
        self.lastError = lastError
        self.holdsBlockedUntil = holdsBlockedUntil
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Nil for anything that is not a status this version understands.
    public static func decode(_ data: Data) -> HelperStatus? {
        guard data.count <= 16_384 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HelperStatus.self, from: data)
    }
}
