import Foundation
import StayAwakeCore

/// What the user can do about a missing sleep control.
enum SetupAction: Equatable {
    /// Register the helper (SMAppService). Arming does this too.
    case register
    /// The helper waits for approval in System Settings, Login Items.
    case openLoginItems
    /// Nothing the app can do; the detail text says what to do.
    case none
}

struct SetupNeed: Equatable {
    /// Short, shown once in the popover and as the SETUP tooltip.
    var title: String
    var detail: String
    var action: SetupAction

    var actionTitle: String? {
        switch action {
        case .register: return "Set Up Sleep Control"
        case .openLoginItems: return "Open Login Items"
        case .none: return nil
        }
    }
}

enum BackendAvailability: Equatable {
    case ready
    /// Nothing can be held until the user does something.
    case setupRequired(SetupNeed)
}

struct BackendError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The thing that really changes `disablesleep`. Release builds use
/// `HelperBackend` (the root daemon); debug builds can pick
/// `SudoersPmsetBackend` with STAYAWAKE_BACKEND=sudoers.
///
/// Calls block (XPC or a process), so the app calls them off the main thread.
/// `reason` is a short tag (a-z, 0-9, - and _) that ends up in the helper log.
protocol PmsetBackend: AnyObject, Sendable {
    var name: String { get }
    func availability() -> BackendAvailability
    /// `pmset -a disablesleep 1` and start whatever fail-safe the backend has.
    func hold(leaseSeconds: Int, reason: String) throws
    /// Called every 10 s while holding. Cheap, never throws.
    func heartbeat(leaseSeconds: Int)
    /// `pmset -a disablesleep 0` and stop the fail-safe.
    func release(reason: String) throws
}

/// Can hold nothing, so the icon says SETUP. Debug builds only, with
/// STAYAWAKE_BACKEND=none, to look at the setup state.
final class NullBackend: PmsetBackend {
    let name = "none"
    private static let need = SetupNeed(title: "Sleep control is switched off",
                                        detail: "This debug build runs with STAYAWAKE_BACKEND=none.", action: .none)
    func availability() -> BackendAvailability { .setupRequired(Self.need) }
    func hold(leaseSeconds: Int, reason: String) throws { throw BackendError(Self.need.title) }
    func heartbeat(leaseSeconds: Int) {}
    func release(reason: String) throws { throw BackendError(Self.need.title) }
}

enum BackendFactory {
    static func make() -> PmsetBackend {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["STAYAWAKE_BACKEND"] {
        case "sudoers": return SudoersPmsetBackend()
        case "none": return NullBackend()
        default: break
        }
        #endif
        return HelperBackend()
    }

    /// The command to show people when automatic restore did not work.
    static let manualRestoreCommand = "sudo pmset -a disablesleep 0"
}

/// Runs a fixed argv with an empty environment and waits for it.
enum FixedProcess {
    struct Result { var status: Int32; var output: String }

    static func run(_ argv: [String]) -> Result? {
        guard let path = argv.first else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = Array(argv.dropFirst())
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// `pmset sleepnow` as the user, the fallback of spec section 5 when
/// releasing does not put a closed Mac to sleep. Fixed argv, no input.
enum SleepNow {
    static func run() { _ = FixedProcess.run(["/usr/bin/pmset", "sleepnow"]) }
}
