import Foundation
import Security
import ServiceManagement
import StayAwakeCore

/// Install, check and remove the helper. Only `HelperBackend` has this.
protocol HelperManaging: AnyObject, Sendable {
    /// SMAppService register. Fine when it ends in "needs approval".
    /// Never unregisters, so an existing approval stays.
    func register() throws
    /// Unregister, then register again. Costs the user's approval: macOS asks
    /// for it again. Only for a registration macOS cannot find, or on request.
    func reinstall() throws
    /// Ask the running helper to exit; launchd starts the one in this bundle.
    /// Returns once the new helper answers with this app's version.
    func restartForUpdate() throws
    func registration() -> HelperRegistration
    /// Unregister only. The caller releases first.
    func remove() throws
    func openApprovalSettings()
    func helperStatus() -> HelperStatus?
    /// Compares the running helper with this app and its bundled helper.
    func versionVerdict() -> HelperVersionCheck.Verdict
}

/// Release backend: the root launchd daemon (StayAwakeHelper) over XPC.
/// The daemon owns the lease and the boot reset; this side
/// only registers it and sends hold, heartbeat, release and status.
final class HelperBackend: PmsetBackend, HelperManaging, @unchecked Sendable {
    let name = "helper"

    #if DEBUG
    private static let relaxed = true
    #else
    private static let relaxed = false
    #endif

    static let callTimeout: TimeInterval = 5
    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    // MARK: - Availability

    private static let approvalTitle = "Sleep control needs a one-time approval"

    func availability() -> BackendAvailability {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            return .setupRequired(SetupNeed(title: "Move StayAwake to Applications",
                                            detail: "macOS runs this copy from a temporary place, so it cannot install its helper. Drag StayAwake to Applications and open it from there.",
                                            action: .none))
        }
        guard Bundle.main.bundleIdentifier == HelperIdentity.appIdentifier else {
            return .setupRequired(SetupNeed(title: "Sleep control needs the app bundle",
                                            detail: "Build with scripts/build.sh and open build/StayAwake.app.", action: .none))
        }
        switch service.status {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .setupRequired(SetupNeed(title: Self.approvalTitle,
                                            detail: "Open Login Items in System Settings and switch on StayAwake under Allow in the Background.",
                                            action: .openLoginItems))
        case .notRegistered, .notFound:
            // .notFound also shows up before the very first registration.
            return .setupRequired(SetupNeed(title: Self.approvalTitle,
                                            detail: "StayAwake uses a small helper to switch Mac sleep off and back on. macOS asks you to allow it once.",
                                            action: .register))
        @unknown default:
            return .setupRequired(SetupNeed(title: Self.approvalTitle,
                                            detail: "Open Login Items in System Settings and check StayAwake.", action: .openLoginItems))
        }
    }

    // MARK: - PmsetBackend

    func hold(leaseSeconds: Int, reason: String) throws {
        try requireEnabled()
        try call { proxy, reply in proxy.hold(leaseSeconds: leaseSeconds, reason: reason, reply: reply) }
    }

    /// The helper extends by the lease length given in `hold`.
    func heartbeat(leaseSeconds: Int) -> String? {
        guard service.status == .enabled else { return "sleep control is not set up (helper not enabled)" }
        do {
            try call { proxy, reply in proxy.heartbeat(reply: reply) }
            return nil
        } catch {
            // The app treats the lease as lost and asks for a new hold.
            NSLog("StayAwake: heartbeat failed: %@", String(describing: error))
            return String(describing: error)
        }
    }

    func release(reason: String) throws {
        try requireEnabled()
        try call { proxy, reply in proxy.release(reason: reason, reply: reply) }
    }

    private func requireEnabled() throws {
        guard service.status == .enabled else { throw BackendError("sleep control is not set up (helper not enabled)") }
    }

    // MARK: - HelperManaging

    func register() throws {
        do {
            try service.register()
        } catch {
            // Registration that waits for approval reports an error too.
            if service.status == .requiresApproval || service.status == .enabled { return }
            throw BackendError("could not register the helper: \(error.localizedDescription)")
        }
    }

    func registration() -> HelperRegistration {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .requiresApproval
        }
    }

    /// launchd throttles a KeepAlive job that ran less than 10 s, so wait a bit longer.
    static let restartWait: TimeInterval = 15

    func restartForUpdate() throws {
        try requireEnabled()
        try call { proxy, reply in proxy.restartForUpdate(reply: reply) }
        dropConnection()
        let deadline = Date().addingTimeInterval(Self.restartWait)
        var last = HelperVersionCheck.Verdict.unknown
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            last = versionVerdict()
            if last == .current { return }
        }
        if case .replace(let why) = last { throw BackendError("helper restarted but still differs (\(why))") }
        throw BackendError("helper did not come back within \(Int(Self.restartWait)) s")
    }

    func reinstall() throws {
        dropConnection()
        if service.status != .notRegistered {
            try? service.unregister()
            // Give launchd a moment to take the old job down.
            for _ in 0..<20 where service.status == .enabled { Thread.sleep(forTimeInterval: 0.1) }
        }
        try register()
    }

    func remove() throws {
        dropConnection()
        do {
            try service.unregister()
        } catch {
            if service.status == .notRegistered { return }
            throw BackendError("could not remove the helper: \(error.localizedDescription)")
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func helperStatus() -> HelperStatus? {
        guard service.status == .enabled else { return nil }
        var data = Data()
        do {
            try callData { proxy, reply in proxy.status(reply: reply) } result: { data = $0 }
        } catch {
            return nil
        }
        return HelperStatus.decode(data)
    }

    func versionVerdict() -> HelperVersionCheck.Verdict {
        let status = helperStatus()
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/StayAwakeHelper")
        return HelperVersionCheck.verdict(helperVersion: status?.version, helperCodeHash: status?.codeHash,
                                          appVersion: appVersion, bundledCodeHash: Self.codeHash(of: bundled))
    }

    /// cdhash of the helper inside this bundle, to compare with the running one.
    static func codeHash(of url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - XPC

    private func proxy(errorHandler: @escaping (Error) -> Void) throws -> HelperXPC {
        lock.lock()
        defer { lock.unlock() }
        let c: NSXPCConnection
        if let existing = connection {
            c = existing
        } else {
            c = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
            c.remoteObjectInterface = .stayAwakeHelper()
            // Talk only to the real helper, signed by the same team.
            c.setCodeSigningRequirement(HelperIdentity.helperRequirement(relaxed: Self.relaxed))
            c.invalidationHandler = { [weak self, weak c] in
                guard let self, let c else { return }
                self.dropConnection(c)
            }
            // The helper restarted (update, crash, launchd): start clean
            // on the next call instead of reusing a half dead connection.
            c.interruptionHandler = { [weak self, weak c] in
                guard let self, let c else { return }
                self.dropConnection(c)
                c.invalidate()
            }
            c.resume()
            connection = c
        }
        guard let proxy = c.remoteObjectProxyWithErrorHandler(errorHandler) as? HelperXPC else {
            throw BackendError("helper interface unavailable")
        }
        return proxy
    }

    private func dropConnection(_ only: NSXPCConnection? = nil) {
        lock.lock()
        let c = connection
        if only == nil || only === c { connection = nil }
        lock.unlock()
        if only == nil { c?.invalidate() }
    }

    /// One call with a String? reply: nil is success. Waits at most `callTimeout`.
    private func call(_ send: (HelperXPC, @escaping (String?) -> Void) -> Void) throws {
        let refused: String? = try roundTrip(send)
        if let refused { throw BackendError("helper: \(refused)") }
    }

    private func callData(_ send: (HelperXPC, @escaping (Data) -> Void) -> Void, result: (Data) -> Void) throws {
        result(try roundTrip(send))
    }

    /// Sends one message. A broken connection (the helper restarted, the Mac
    /// woke, launchd swapped the binary) is dropped and the message is sent
    /// once more on a fresh connection. Every call is safe to repeat: hold
    /// extends, release is idempotent, status and heartbeat change nothing extra.
    private func roundTrip<Value>(_ send: (HelperXPC, @escaping (Value) -> Void) -> Void) throws -> Value {
        var lastError: Error = BackendError("helper connection failed")
        for attempt in 0..<2 {
            let outcome = Outcome<Value>()
            let p = try proxy { error in outcome.finish(.failure(BackendError("helper connection failed: \(error.localizedDescription)"))) }
            send(p) { value in outcome.finish(.success(value)) }
            switch outcome.wait(timeout: Self.callTimeout) {
            case nil:
                dropConnection()
                throw BackendError("helper did not answer within \(Int(Self.callTimeout)) s")
            case .failure(let error)?:
                dropConnection()
                lastError = error
                if attempt == 0 { Thread.sleep(forTimeInterval: 0.2) }
            case .success(let value)?:
                return value
            }
        }
        throw lastError
    }
}

/// First answer wins: the reply or the connection error, whichever comes first.
private final class Outcome<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var value: Result<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        value = result
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Result<Value, Error>? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
