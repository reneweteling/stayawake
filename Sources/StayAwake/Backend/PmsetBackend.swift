import Foundation
import StayAwakeCore

enum BackendAvailability: Equatable {
    case ready
    /// Nothing can be held until the user does something. The text says what.
    case setupRequired(String)
}

struct BackendError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// The thing that really changes `disablesleep`. M5 adds the privileged
/// helper behind this same protocol; until then release builds use
/// `NullBackend` and debug builds can use `SudoersPmsetBackend`.
///
/// Calls block (they run a process), so the app calls them off the main thread.
protocol PmsetBackend: AnyObject, Sendable {
    var name: String { get }
    func availability() -> BackendAvailability
    /// `pmset -a disablesleep 1` and start whatever fail-safe the backend has.
    func hold(leaseSeconds: Int) throws
    /// Called every 10 s while holding. Cheap, never throws.
    func heartbeat(leaseSeconds: Int)
    /// `pmset -a disablesleep 0` and stop the fail-safe.
    func release() throws
}

/// Release builds until the helper exists (M5). Cannot hold, so the icon says SETUP.
final class NullBackend: PmsetBackend {
    let name = "none"
    private static let message = "Sleep control is not installed yet. The helper arrives in a later release."
    func availability() -> BackendAvailability { .setupRequired(Self.message) }
    func hold(leaseSeconds: Int) throws { throw BackendError(Self.message) }
    func heartbeat(leaseSeconds: Int) {}
    func release() throws { throw BackendError(Self.message) }
}

enum BackendFactory {
    static func make() -> PmsetBackend {
        #if DEBUG
        if ProcessInfo.processInfo.environment["STAYAWAKE_BACKEND"] == "sudoers" { return SudoersPmsetBackend() }
        #endif
        return NullBackend()
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
